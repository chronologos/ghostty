#if os(macOS)
import AppKit
import SwiftUI
import Combine

/// The fork's single window. Subclasses `TerminalController` so the inherited `surfaceTree`,
/// `TerminalSplitTreeView`, split IBActions and focus nav work unchanged (SPEC §2.1).
/// Tab switching = swapping which tree is assigned to `surfaceTree`.
final class ForkWindowController: TerminalController {
    private let registry = SessionRegistry.shared
    private var liveTabs: [TabModel.ID: SplitTree<Ghostty.SurfaceView>] = [:]
    private var sidebarSplit: NSSplitView?
    private var cancellables: Set<AnyCancellable> = []

    /// Singleton: the fork is single-window in v1.
    private(set) static weak var instance: ForkWindowController?

    override var windowNibName: NSNib.Name? { "TerminalHiddenTitlebar" }

    // MARK: Factory (called from seam #2 via ForkBootstrap.intercept)
    //
    // Registry seeding lives here, not in windowDidLoad, because windowDidLoad fires
    // *inside* super.init (BaseTerminalController.init:142 assigns surfaceTree → didSet
    // → TerminalController.surfaceTreeDidChange reads self.window → nib loads).

    static func newWindow(_ ghostty: Ghostty.App) -> ForkWindowController {
        if let existing = instance, existing.window != nil {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        let registry = SessionRegistry.shared
        let c: ForkWindowController
        if registry.tabs.isEmpty {
            let ref = SessionRef(hostID: ForkHost.local.id, name: SessionRegistry.autoName())
            c = ForkWindowController(ghostty, withBaseConfig: ZmxAdapter.surfaceConfig(host: .local, ref: ref))
            if case let .leaf(view) = c.surfaceTree.root {
                registry.bind(surface: view.id, to: ref)
                let tab = registry.newTab(on: ForkHost.local.id, title: ref.name)
                c.liveTabs[tab.id] = c.surfaceTree
                c.activate(tab: tab.id)
            }
        } else {
            c = ForkWindowController(ghostty, withSurfaceTree: .init())
            if let active = registry.activeTabID ?? registry.tabs.first?.id {
                c.activate(tab: active)
            }
        }
        instance = c
        c.showWindow(nil)
        return c
    }

    /// Fork keeps the window open with an empty tree (= "no tabs"); upstream would `.close()` it.
    override func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        guard !to.isEmpty else { focusedSurface = nil; return }
        super.surfaceTreeDidChange(from: from, to: to)
    }

    // MARK: ⌘T / ⌘W — replace upstream's native-NSWindow-tab actions with sidebar tabs.

    @IBAction override func newTab(_ sender: Any?) {
        showNewSessionSheet()
    }

    @IBAction override func closeTab(_ sender: Any?) {
        guard let active = registry.activeTabID else { return }
        closeForkTab(active)
    }

    private var newSessionPanel: NSWindow?

    func showNewSessionSheet() {
        guard let window, newSessionPanel == nil else { return }
        let panel = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 320),
                             styleMask: [.titled, .docModalWindow], backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView:
            NewSessionView(defaultHostID: registry.activeHost?.id ?? ForkHost.local.id,
                           onSubmit: { [weak self] intent in
                               self?.newForkTab(intent: intent)
                               self?.endNewSessionSheet()
                           },
                           onCancel: { [weak self] in self?.endNewSessionSheet() })
            .environmentObject(registry))
        newSessionPanel = panel
        window.beginSheet(panel)
    }

    private func endNewSessionSheet() {
        guard let panel = newSessionPanel else { return }
        window?.endSheet(panel)
        newSessionPanel = nil
    }

    // MARK: Window setup — wrap upstream's contentView in a sidebar split.

    override func windowDidLoad() {
        super.windowDidLoad()
        guard let window, let terminalContent = window.contentView else { return }

        window.tabbingMode = .disallowed
        window.isRestorable = false

        let sidebar = NSHostingView(rootView: SidebarView(controller: self).environmentObject(registry))
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "fork.sidebar"
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(terminalContent)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        window.contentView = split
        split.setPosition(248, ofDividerAt: 0)
        sidebarSplit = split

        $surfaceTree
            .sink { [weak self] tree in self?.persistActive(tree) }
            .store(in: &cancellables)
    }

    // MARK: Tab management

    func activate(tab id: TabModel.ID) {
        if let current = registry.activeTabID, current != id {
            liveTabs[current] = surfaceTree
        }
        registry.setActive(tab: id)
        if let tree = liveTabs[id] {
            surfaceTree = tree
        } else {
            rebuildTree(for: id)
        }
    }

    func newForkTab(intent: NewSessionIntent) {
        guard let host = registry.host(id: intent.hostID), let app = ghostty.app else { return }
        let ref = SessionRef(hostID: host.id, name: intent.name ?? SessionRegistry.autoName())
        let cfg = ZmxAdapter.surfaceConfig(host: host, ref: ref, initialCmd: intent.cmd, cwd: intent.cwd)
        let surface = Ghostty.SurfaceView(app, baseConfig: cfg)
        registry.bind(surface: surface.id, to: ref)
        let tab = registry.newTab(on: host.id, title: ref.name)
        liveTabs[tab.id] = .init(view: surface)
        activate(tab: tab.id)
    }

    func closeForkTab(_ id: TabModel.ID) {
        if let tree = liveTabs[id] {
            for surface in tree { registry.unbind(surface: surface.id) }
        }
        liveTabs.removeValue(forKey: id)
        let wasActive = registry.activeTabID == id
        registry.removeTab(id)
        guard wasActive else { return }
        if let next = registry.tabs.first?.id {
            activate(tab: next)
        } else {
            surfaceTree = .init()
        }
    }

    // MARK: Split — inject zmx command into upstream's flow (SPEC §5).

    @discardableResult
    override func newSplit(
        at oldView: Ghostty.SurfaceView,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
        baseConfig config: Ghostty.SurfaceConfiguration? = nil
    ) -> Ghostty.SurfaceView? {
        guard let host = registry.activeHost else {
            return super.newSplit(at: oldView, direction: direction, baseConfig: config)
        }
        let ref = SessionRef(hostID: host.id, name: SessionRegistry.autoName())
        let cfg = ZmxAdapter.surfaceConfig(host: host, ref: ref)
        guard let view = super.newSplit(at: oldView, direction: direction, baseConfig: cfg) else { return nil }
        registry.bind(surface: view.id, to: ref)
        return view
    }

    // MARK: Persistence projection

    private func persistActive(_ tree: SplitTree<Ghostty.SurfaceView>) {
        guard let active = registry.activeTabID else { return }
        liveTabs[active] = tree
        registry.setPersistedTree(project(tree.root), for: active)
    }

    private func project(_ node: SplitTree<Ghostty.SurfaceView>.Node?) -> PersistedTree {
        guard let node else { return .empty }
        switch node {
        case .leaf(let v):
            return .leaf(registry.refs[v.id])
        case .split(let s):
            return .split(
                horizontal: s.direction == .horizontal,
                ratio: s.ratio,
                a: project(s.left),
                b: project(s.right))
        }
    }

    /// Lazy reattach (SPEC §7): rebuild a live tree from a persisted one.
    private func rebuildTree(for tabID: TabModel.ID) {
        guard let tab = registry.tabs.first(where: { $0.id == tabID }),
              let host = registry.host(id: tab.hostID),
              let app = ghostty.app else { return }
        func revive(_ p: PersistedTree) -> SplitTree<Ghostty.SurfaceView>.Node? {
            switch p {
            case .empty: return nil
            case .leaf(let ref):
                let r = ref ?? SessionRef(hostID: host.id, name: SessionRegistry.autoName())
                let cfg = ZmxAdapter.surfaceConfig(host: host, ref: r)
                let v = Ghostty.SurfaceView(app, baseConfig: cfg)
                registry.bind(surface: v.id, to: r)
                return .leaf(view: v)
            case .split(let h, let ratio, let a, let b):
                guard let na = revive(a), let nb = revive(b) else { return revive(a) ?? revive(b) }
                return .split(.init(direction: h ? .horizontal : .vertical, ratio: ratio, left: na, right: nb))
            }
        }
        let root = revive(tab.tree) ?? revive(.leaf(nil))
        let tree = SplitTree<Ghostty.SurfaceView>(root: root, zoomed: nil)
        liveTabs[tabID] = tree
        surfaceTree = tree
    }
}
#endif
