#if os(macOS)
import AppKit
import SwiftUI
import Combine
import GhosttyKit
import UserNotifications

/// The fork's single window. Subclasses `TerminalController` so the inherited `surfaceTree`,
/// `TerminalSplitTreeView`, split IBActions and focus nav work unchanged (SPEC §2.1).
/// Tab switching = swapping which tree is assigned to `surfaceTree`.
final class ForkWindowController: TerminalController {
    private let registry = SessionRegistry.shared
    private var liveTabs: [TabModel.ID: SplitTree<Ghostty.SurfaceView>] = [:]
    private var cancellables: Set<AnyCancellable> = []

    /// Singleton: the fork is single-window in v1.
    private(set) static weak var instance: ForkWindowController?

    // MARK: Factory (called from seam #2 via ForkBootstrap.intercept)
    //
    // Registry seeding lives here, not in windowDidLoad, because windowDidLoad fires
    // *inside* super.init (BaseTerminalController.init:142 assigns surfaceTree → didSet
    // → TerminalController.surfaceTreeDidChange reads self.window → nib loads).

    static func newWindow(_ ghostty: Ghostty.App, intent: NewSessionIntent? = nil) -> ForkWindowController {
        if let existing = instance, existing.window != nil {
            existing.window?.makeKeyAndOrderFront(nil)
            // Scripting paths (Shortcuts/AppleScript/Finder open) carry a payload — open
            // it as a fresh tab instead of just raising the window.
            if let intent { existing.newForkTab(intent: intent) }
            return existing
        }
        let registry = SessionRegistry.shared
        let c: ForkWindowController
        if registry.tabs.isEmpty {
            let host: ForkHost = intent.flatMap { registry.host(id: $0.hostID) } ?? .local
            let ref = SessionRef(hostID: host.id, name: intent?.name ?? registry.uniqueAutoName())
            let cfg = ZmxAdapter.surfaceConfig(host: host, ref: ref,
                                               initialCmd: intent?.cmd, cwd: intent?.cwd)
            c = ForkWindowController(ghostty, withBaseConfig: cfg)
            if case let .leaf(view) = c.surfaceTree.root {
                registry.bind(surface: view.id, to: ref)
                let tab = registry.newTab(on: host.id, title: ref.name)
                c.liveTabs[tab.id] = c.surfaceTree
                c.activate(tab: tab.id)
            }
        } else {
            c = ForkWindowController(ghostty, withSurfaceTree: .init())
            if let intent {
                c.newForkTab(intent: intent)
            } else if let active = registry.activeTabID ?? registry.tabs.first?.id {
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

    /// ⌘W on the last pane → `removeSurfaceNode` → `replaceSurfaceTree(empty)` (`:197`) →
    /// `closeTabImmediately()` (`:672`) → `closeWindowImmediately()` since the fork is single-
    /// window. Intercept at the choke point and route to sidebar tab close instead.
    override func closeTabImmediately(registerRedo: Bool = true) {
        guard let active = registry.activeTabID else { return }
        closeForkTab(active)
    }

    // MARK: Detached panes — when a bound surface's child exits, swap in a placeholder
    // that prints "press ⏎ to reattach" and execs `zmx attach` on ⏎ (SPEC §5).

    private var detachedPlaceholders: Set<UUID> = []

    private func makeDetachedPlaceholder(for dead: Ghostty.SurfaceView) -> Ghostty.SurfaceView? {
        guard dead.processExited,
              !detachedPlaceholders.contains(dead.id),
              let ref = registry.refs[dead.id],
              let host = registry.host(id: ref.hostID),
              let app = ghostty.app else { return nil }
        var cfg = Ghostty.SurfaceConfiguration()
        cfg.command = ZmxAdapter.detachedScript(host: host, ref: ref)
        let placeholder = Ghostty.SurfaceView(app, baseConfig: cfg)
        detachedPlaceholders.insert(placeholder.id)
        registry.bind(surface: placeholder.id, to: ref)
        registry.unbind(surface: dead.id)
        return placeholder
    }

    /// `BaseTerminalController.ghosttyDidCloseSurface` (`:585`) is `@objc private` and
    /// guards on `surfaceTree`, so a parked tab's pty-exit is dropped before our
    /// `closeSurface` override sees it. This second observer covers that case.
    @objc private func parkedSurfaceDidExit(_ note: Notification) {
        guard let dead = note.object as? Ghostty.SurfaceView,
              surfaceTree.root?.node(view: dead) == nil,
              let (tabID, tree) = liveTabs.first(where: {
                  $0.key != registry.activeTabID && $0.value.contains { $0.id == dead.id }
              }),
              let placeholder = makeDetachedPlaceholder(for: dead),
              let deadNode = tree.root?.node(view: dead),
              let newTree = try? tree.replacing(node: deadNode, with: .leaf(view: placeholder))
        else { return }
        liveTabs[tabID] = newTree
        registry.setPersistedTree(project(newTree.root), for: tabID)
    }

    override func closeSurface(_ node: SplitTree<Ghostty.SurfaceView>.Node, withConfirmation: Bool = true) {
        // `withConfirmation` is libghostty's `needsConfirmQuit()`, which is false for both
        // process-death AND user ⌘W on an idle shell. `processExited` is the discriminator.
        if !withConfirmation,
           case let .leaf(dead) = node,
           let placeholder = makeDetachedPlaceholder(for: dead) {
            do {
                surfaceTree = try surfaceTree.replacing(node: node, with: .leaf(view: placeholder))
                focusedSurface = placeholder
                return
            } catch {}
        }

        // ⌘W on the last pane → tab-level Detach/Kill. `TerminalController.closeSurface`
        // (`:656-669`) would route this to `closeWindow(nil)`; we route to the sidebar tab.
        if surfaceTree.root == node, let tab = registry.activeTab,
           let host = registry.host(id: tab.hostID) {
            let live = liveTabs[tab.id]?.compactMap { registry.refs[$0.id] } ?? []
            let refs = Array(Set(live.isEmpty ? tab.tree.leafRefs : live))
            confirmDetachOrKill(
                messageText: "Close tab '\(tab.title)'?",
                informativeText: refs.isEmpty
                    ? "No zmx sessions are bound to this tab."
                    : "Detach leaves \(refs.count) zmx session\(refs.count == 1 ? "" : "s") running. Reattach from ⌘T or the split picker.",
                killTitle: refs.count > 1 ? "Kill \(refs.count) Sessions" : "Kill Session",
                killEnabled: !refs.isEmpty,
                onDetach: { [weak self] in self?.closeForkTab(tab.id) },
                onKill: { [weak self] in
                    Task {
                        for ref in refs { try? await ZmxAdapter.kill(host: host, ref: ref) }
                        await MainActor.run { self?.closeForkTab(tab.id) }
                    }
                }
            )
            return
        }

        // ⌘W on one pane of several → per-pane Detach/Kill.
        if case let .leaf(surface) = node, let ref = registry.refs[surface.id],
           let host = registry.host(id: ref.hostID), let tab = registry.activeTab {
            confirmDetachOrKill(
                messageText: "Close pane '\(ref.name)'?",
                informativeText: "Detach leaves the zmx session running. Reattach from ⌘T or the split picker.",
                onDetach: { [weak self] in self?.dropPane(tab: tab, ref: ref, surface: surface) },
                onKill: { [weak self] in
                    guard let self else { return }
                    // Unbind first so the pty-death → placeholder path short-circuits.
                    self.registry.unbind(surface: surface.id)
                    Task { try? await ZmxAdapter.kill(host: host, ref: ref) }
                    self.dropPane(tab: tab, ref: ref, surface: surface)
                }
            )
            return
        }

        super.closeSurface(node, withConfirmation: false)
    }

    /// ⌘W sheet: Detach (⏎, default) / Kill (K, destructive) / Cancel (Esc).
    private func confirmDetachOrKill(
        messageText: String,
        informativeText: String,
        killTitle: String = "Kill Session",
        killEnabled: Bool = true,
        onDetach: @escaping () -> Void,
        onKill: @escaping () -> Void
    ) {
        guard let window else { onDetach(); return }
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText + "\n\n⏎ Detach · K Kill · Esc Cancel"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Detach")
        let kill = alert.addButton(withTitle: killTitle)
        kill.keyEquivalent = "k"
        kill.hasDestructiveAction = true
        kill.isEnabled = killEnabled
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { resp in
            alert.window.orderOut(nil)
            switch resp {
            case .alertFirstButtonReturn: onDetach()
            case .alertSecondButtonReturn: onKill()
            default: break
            }
        }
    }

    // MARK: ⌘[/⌘]/⌘1-9/⌘⌥1-9 — sidebar-tab navigation (SPEC §10).

    private var navMonitor: Any?

    /// `charactersIgnoringModifiers` does not strip Option (it's a character-producing
    /// modifier), so ⌥-digit must be matched by physical keyCode.
    private static let digitKeyCodes: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]

    private func installNavMonitor() {
        navMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, ev.window === self.window, self.sheetPanel == nil else { return ev }
            let mods = ev.modifierFlags.intersection([.command, .shift, .option, .control])
            if let n = Self.digitKeyCodes[ev.keyCode] {
                switch mods {
                case [.command, .option]: self.gotoHost(index: n); return nil
                case .command: self.gotoTab(index: n); return nil
                default: return ev
                }
            }
            // ⌘I (`prompt_surface_title`) dispatches straight to `SurfaceView.promptTitle()`
            // (Ghostty.App.swift:1669) which doesn't persist; intercept to drive the
            // sidebar's per-pane label instead. ⌘⇧I goes via `promptTabTitle()`.
            if mods == .command, ev.charactersIgnoringModifiers == "i" {
                self.promptPaneTitle(); return nil
            }
            // ⌘⌥A — one-shot watch on focused pane. keyCode 0 = kVK_ANSI_A;
            // `charactersIgnoringModifiers` doesn't strip Option (see digit comment above).
            if mods == [.command, .option], ev.keyCode == 0 {
                self.toggleWatch(); return nil
            }
            // ⌘[/⌘] are upstream's `goto_split:previous/next` (Config.zig:7016).
            // Sidebar tab nav uses ⌘⇧[/⌘⇧] (upstream's `previous_tab`/`next_tab`).
            guard mods == [.command, .shift] else { return ev }
            switch ev.charactersIgnoringModifiers {
            case "{", "[": self.stepTab(-1); return nil
            case "}", "]": self.stepTab(1); return nil
            case "b", "B": self.toggleSidebar(); return nil
            default: return ev
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(parkedSurfaceDidExit(_:)),
            name: Ghostty.Notification.ghosttyCloseSurface, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(bellDidRing(_:)),
            name: .ghosttyBellDidRing, object: nil)
    }

    // MARK: Watch (⌘⌥A) — one-shot alert on completion (PR24).
    //
    // Fires on the first of: BEL (`.ghosttyBellDidRing`; also posted by upstream's
    // OSC 133;D handler when `notify-on-command-finish-action` includes `bell`, and
    // by ANY raw `\a` in the pty stream — hostile/noisy input can trip it), or OSC
    // 9;4 progress non-nil→nil (`SurfaceView.$progressReport`, ConEmu-style; what
    // Claude Code emits on idle). Both reach Swift without seams; `progress-style`
    // config defaults true (Config.zig:3671). Caveat: upstream's `progressReport`
    // didSet (SurfaceView_AppKit.swift:31) auto-nils after 15s of no fresh 9;4, so
    // a process that emits progress then stalls >15s reads as "finished".

    private var watching: [UUID: AnyCancellable] = [:]

    func isWatching(_ surface: Ghostty.SurfaceView) -> Bool { watching[surface.id] != nil }

    func toggleWatch(on target: Ghostty.SurfaceView? = nil) {
        guard let surface = target ?? focusedSurface else { return }
        if watching.removeValue(forKey: surface.id) != nil {
            registry.setWatching(surface.id, false)
            return
        }
        registry.setWatching(surface.id, true)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        var sawProgress = false
        watching[surface.id] = surface.$progressReport
            .sink { [weak self, weak surface] report in
                if report != nil { sawProgress = true; return }
                guard sawProgress, let surface else { return }
                self?.watchDidFire(on: surface)
            }
    }

    @objc private func bellDidRing(_ n: Notification) {
        guard let surface = n.object as? Ghostty.SurfaceView,
              watching[surface.id] != nil else { return }
        watchDidFire(on: surface)
    }

    private func watchDidFire(on surface: Ghostty.SurfaceView) {
        guard watching.removeValue(forKey: surface.id) != nil else { return }
        registry.setWatching(surface.id, false)
        let ref = registry.refs[surface.id]
        let tab = registry.tabs.first { surfaces(for: $0.id).contains { $0 === surface } }
        let osc = (surface.title.isEmpty || surface.title == "👻") ? nil : surface.title
        let label = ref.flatMap { tab?.paneLabels[$0.key] } ?? osc ?? ref?.name ?? "Pane"
        // `shouldPresentNotification` (Ghostty.App.swift:449) requires the userInfo
        // surface to resolve via `findSurface(forUUID:)` AND have `window != nil`. A
        // watched pane in a parked tab fails both; post against an in-tree surface so
        // the banner shows while Ghostty is foreground.
        let poster = surfaceTree.contains { $0 === surface } ? surface
                   : (Array(surfaceTree).first ?? surface)
        poster.showUserNotification(title: "\(label) finished",
                                    body: tab.map { "Tab '\($0.title)'" } ?? "",
                                    requireFocus: false)
    }

    // MARK: Sidebar visibility

    private static let sidebarWidth: CGFloat = 248
    private weak var sidebarHost: NSView?
    private weak var sidebarReveal: NSButton?
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var terminalLeadingConstraint: NSLayoutConstraint?

    func toggleSidebar() {
        guard let sidebarHost, let sidebarWidthConstraint, let terminalLeadingConstraint else { return }
        let hide = sidebarWidthConstraint.constant > 0
        let w: CGFloat = hide ? 0 : Self.sidebarWidth
        if !hide { sidebarHost.isHidden = false }
        sidebarReveal?.isHidden = !hide
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            sidebarWidthConstraint.animator().constant = w
            terminalLeadingConstraint.animator().constant = w
            sidebarHost.superview?.layoutSubtreeIfNeeded()
        } completionHandler: {
            sidebarHost.isHidden = sidebarWidthConstraint.constant == 0
        }
    }

    @objc private func revealSidebar(_ sender: Any?) { toggleSidebar() }

    private func stepTab(_ delta: Int) {
        guard let active = registry.activeTabID,
              let i = registry.tabs.firstIndex(where: { $0.id == active }),
              !registry.tabs.isEmpty else { return }
        let j = ((i + delta) % registry.tabs.count + registry.tabs.count) % registry.tabs.count
        activate(tab: registry.tabs[j].id)
    }

    func gotoTab(index n: Int) {
        let host = registry.activeHost?.id ?? ForkHost.local.id
        let tabs = registry.tabs(on: host)
        guard tabs.indices.contains(n - 1) else { return }
        activate(tab: tabs[n - 1].id)
    }

    private func moveActiveTab(by amount: Int) {
        guard amount != 0, let active = registry.activeTab else { return }
        let siblings = registry.tabs(on: active.hostID)
        guard let i = siblings.firstIndex(where: { $0.id == active.id }) else { return }
        let j = max(0, min(siblings.count - 1, i + amount))
        guard j != i else { return }
        registry.moveTab(active.id, before: siblings[j].id)
    }

    /// Intercept palette tab actions — `Ghostty.App.gotoTab/moveTab` guard on
    /// `tabGroup.windows.count > 1`, which is never true with `tabbingMode = .disallowed`.
    override func performAction(_ action: String, on surfaceView: Ghostty.SurfaceView) {
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "previous_tab": stepTab(-1)
        case "next_tab": stepTab(1)
        case "last_tab":
            let host = registry.activeHost?.id ?? ForkHost.local.id
            if let last = registry.tabs(on: host).last { activate(tab: last.id) }
        case "goto_tab":
            if parts.count == 2, let n = Int(parts[1]) { gotoTab(index: n) }
        case "move_tab":
            if parts.count == 2, let d = Int(parts[1]) { moveActiveTab(by: d) }
        case "prompt_surface_title": promptPaneTitle()
        case "prompt_tab_title": promptTabTitle()
        default:
            super.performAction(action, on: surfaceView)
        }
    }

    /// ⌘⇧I and View → Change Tab Title both land here. Upstream pops an NSAlert that
    /// writes `titleOverride` (which we already drive from `syncWindowTitle()`); redirect
    /// to the sidebar's heading inline field instead.
    override func promptTabTitle() {
        guard !ForkBootstrap.noSidebar, let tab = registry.activeTab else {
            return super.promptTabTitle()
        }
        revealRow(on: tab.hostID)
        registry.setRenaming(.tab(tab.id))
    }

    /// ⌘I — sidebar's persisted per-pane label for the focused pane. Upstream's
    /// `SurfaceView.promptTitle()` writes `surface.title`, which is per-instance and lost
    /// on restart; `paneLabels` (keyed by `ref.key`) survives via fork.json.
    func promptPaneTitle() {
        guard !ForkBootstrap.noSidebar, let tab = registry.activeTab else { return }
        let refs = tab.tree.leafRefs
        let i = registry.focusedPaneIndex ?? 0
        guard i < refs.count else { return }
        revealRow(on: tab.hostID)
        registry.setRenaming(.pane(tab.id, name: refs[i].key))
    }

    private func revealRow(on hostID: ForkHost.ID) {
        if sidebarWidthConstraint?.constant == 0 { toggleSidebar() }
        registry.setExpanded(hostID, true)
    }

    @IBAction override func changeTabTitle(_ sender: Any) { promptTabTitle() }

    /// Live surfaces for a tab in depth-first-leaf order (matches `PersistedTree.leafRefs`).
    /// Empty for tabs never activated this session — those rebuild lazily on first `activate()`.
    func surfaces(for tabID: TabModel.ID) -> [Ghostty.SurfaceView] {
        Array(tabID == registry.activeTabID ? surfaceTree : (liveTabs[tabID] ?? .init()))
    }

    func gotoHost(index n: Int) {
        guard registry.hosts.indices.contains(n - 1) else { return }
        let host = registry.hosts[n - 1]
        registry.setExpanded(host.id, true)
        if let first = registry.tabs(on: host.id).first {
            activate(tab: first.id)
        }
    }

    func removeHost(_ id: ForkHost.ID) {
        for tab in registry.tabs(on: id) { liveTabs.removeValue(forKey: tab.id) }
        registry.removeHost(id)
        guard registry.activeTabID == nil else { return }
        if let next = registry.tabs.first?.id {
            activate(tab: next)
        } else {
            surfaceTree = .init()
        }
    }

    func confirmKillPane(tab: TabModel, ref: SessionRef, surface: Ghostty.SurfaceView?) {
        guard let window, let host = registry.host(id: tab.hostID) else { return }
        let alert = NSAlert()
        alert.messageText = "Kill zmx session '\(ref.name)'?"
        alert.informativeText = tab.tree.paneCount > 1
            ? "Other panes in '\(tab.title)' stay attached."
            : "This is the only pane; the tab will close."
        alert.addButton(withTitle: "Kill")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let self else { return }
            // Unbind first so the pty-death → placeholder path short-circuits.
            if let surface { registry.unbind(surface: surface.id) }
            Task { try? await ZmxAdapter.kill(host: host, ref: ref) }
            dropPane(tab: tab, ref: ref, surface: surface)
        }
    }

    private func dropPane(tab: TabModel, ref: SessionRef, surface: Ghostty.SurfaceView?) {
        guard tab.tree.paneCount > 1 else { closeForkTab(tab.id); return }
        if let live = liveTabs[tab.id], let surface,
           let node = live.root?.node(view: surface) {
            if tab.id == registry.activeTabID {
                super.closeSurface(node, withConfirmation: false)
            } else {
                let pruned = live.removing(node)
                liveTabs[tab.id] = pruned
                registry.setPersistedTree(project(pruned.root), for: tab.id)
            }
        } else {
            registry.setPersistedTree(tab.tree.removing(ref), for: tab.id)
        }
    }

    func confirmKill(_ tab: TabModel) {
        guard let window, let host = registry.host(id: tab.hostID) else { return }
        let live = liveTabs[tab.id]?.compactMap { registry.refs[$0.id] } ?? []
        let refs = Array(Set(live.isEmpty ? tab.tree.leafRefs : live))
        guard !refs.isEmpty else { closeForkTab(tab.id); return }
        let alert = NSAlert()
        alert.messageText = "Kill \(refs.count) zmx session\(refs.count == 1 ? "" : "s")?"
        alert.informativeText = refs.map(\.name).joined(separator: ", ")
        alert.addButton(withTitle: "Kill")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            Task {
                for ref in refs { try? await ZmxAdapter.kill(host: host, ref: ref) }
                await MainActor.run { self?.closeForkTab(tab.id) }
            }
        }
    }

    // MARK: Move pane / merge tab (PR21b)

    /// Move a pane from one tab into another (same host). `to == nil` creates a
    /// new destination tab. The live `SurfaceView` is reparented — its pty (zmx
    /// attach) keeps running since `registry.refs` isn't touched.
    ///
    /// Sequencing nuances: write `liveTabs[src]` / `liveTabs[dst]` BEFORE any
    /// `surfaceTree =` so `closeForkTab` (if src empties) reads the post-move
    /// state and doesn't unbind the moved surface. Skip `surfaceTree =` for the
    /// active-and-empty case — the sibling `activate(tab:)` inside closeForkTab
    /// will replace surfaceTree wholesale, avoiding an in-flight debounced
    /// `persistActive(empty)` landing under the newly-active sibling's id.
    func movePane(from src: TabModel.ID, ref: SessionRef, to dstOrNil: TabModel.ID?) {
        guard let srcTab = registry.tabs.first(where: { $0.id == src }),
              srcTab.tree.leafRefs.contains(ref) else { return }

        // Resolve destination.
        let dst: TabModel.ID
        if let existing = dstOrNil {
            guard let dstTab = registry.tabs.first(where: { $0.id == existing }),
                  dstTab.hostID == srcTab.hostID, existing != src else { return }
            dst = existing
        } else {
            dst = registry.newTab(on: srcTab.hostID, title: ref.name).id
            // Fresh tab has tree == .empty and no liveTabs entry. Without this seed,
            // `liveTree(for: dst)` below falls into rebuildTree → `revive(.empty) ??
            // revive(.leaf(nil))` and spawns a stray auto-named zmx session that the
            // moved pane gets inserted *alongside* (2 live leaves, 1 persisted).
            liveTabs[dst] = .init()
        }

        let srcLive = liveTree(for: src)
        // Live surface is required. Operating off persisted alone would let the
        // closeForkTab(src) check below unbind live panes that weren't moved — the
        // persisted ↔ live divergence window before the 80ms debounce settles.
        guard let surface = srcLive.first(where: { registry.refs[$0.id] == ref }),
              let srcNode = srcLive.root?.node(view: surface) else { return }

        let prunedSrc = srcLive.removing(srcNode)
        let dstLive = liveTree(for: dst)
        let extendedDst: SplitTree<Ghostty.SurfaceView>
        // Rightmost leaf + `.right` makes the depth-first-left traversal yield
        // `[...existing, moved]` — matches PersistedTree.appending(leaf:) so live
        // and persisted shapes agree even when dst is inactive (no debounced
        // persistActive.project() to paper over a mismatch).
        if let anchor = Array(dstLive).last {
            extendedDst = (try? dstLive.inserting(view: surface, at: anchor, direction: .right)) ?? dstLive
        } else {
            extendedDst = .init(view: surface)
        }
        liveTabs[src] = prunedSrc
        liveTabs[dst] = extendedDst
        if src == registry.activeTabID && !prunedSrc.isEmpty {
            surfaceTree = prunedSrc
        } else if dst == registry.activeTabID {
            surfaceTree = extendedDst
        }

        registry.movePanePersisted(from: src, ref: ref, to: dst)
        undoManager?.removeAllActions(withTarget: self)
        // Close src off LIVE state (prunedSrc), not the persisted tree. Persisted
        // can lag by up to 80ms after a recent split; reading it would auto-close
        // a tab whose live state still has panes.
        if prunedSrc.isEmpty {
            // Land on dst BEFORE closing src so closeForkTab's positional-neighbour
            // pick never runs — it would `rebuildTree` a dormant sibling and spawn its
            // zmx/ssh sessions for one frame. `nil` (not the empty tree) so
            // `activate(dst)`'s outgoing-snapshot guard and `closeForkTab`'s unbind
            // loop both skip src; the moved surface lives in dst now.
            liveTabs[src] = nil
            activate(tab: dst)
            closeForkTab(src)
        }
    }

    /// Fold every pane from `src` into `dst` (same host). Src auto-closes after.
    /// Iterates the LIVE tree (matches `movePane`'s surface requirement) and skips
    /// external (`@`-keyed) refs — moving an external reattaches someone else's
    /// session under a different tab, which is the split/merge-externals rabbit
    /// hole we're deliberately deferring per Fork/CLAUDE.md §Gotchas.
    func mergeTab(from src: TabModel.ID, into dst: TabModel.ID) {
        guard src != dst,
              let srcTab = registry.tabs.first(where: { $0.id == src }),
              let dstTab = registry.tabs.first(where: { $0.id == dst }),
              srcTab.hostID == dstTab.hostID else { return }
        let refs = Array(liveTree(for: src)).compactMap { registry.refs[$0.id] }.filter { !$0.external }
        for ref in refs {
            movePane(from: src, ref: ref, to: dst)
        }
    }

    // MARK: ⌘T / ⌘W — replace upstream's native-NSWindow-tab actions with sidebar tabs.

    @IBAction override func newTab(_ sender: Any?) {
        showSessionPicker(on: registry.activeHost ?? .local)
    }

    @IBAction override func closeTab(_ sender: Any?) {
        guard let active = registry.activeTabID else { return }
        closeForkTab(active)
    }

    private var sheetPanel: NSWindow?

    func showNewSessionSheet() {
        presentSheet(size: .init(width: 640, height: 320)) { [weak self] in
            NewSessionView(defaultHostID: self?.registry.activeHost?.id ?? ForkHost.local.id,
                           onSubmit: { intent in self?.newForkTab(intent: intent); self?.endSheet() },
                           onCancel: { self?.endSheet() })
        }
    }

    /// Compact picker (same as ⌘D split) for the host context-menu — name or attach,
    /// no cwd/cmd fields. Use `showNewSessionSheet` for the full form.
    func showSessionPicker(on host: ForkHost) {
        let placeholder = registry.uniqueAutoName()
        presentSheet(size: .init(width: 280, height: 260)) { [weak self] in
            SplitPickerView(
                title: "New session on \(host.label)",
                host: host, placeholder: placeholder,
                onSubmit: { ref in
                    self?.newForkTab(intent: .init(hostID: ref.hostID, name: ref.name,
                                                   external: ref.external))
                    self?.endSheet()
                },
                onCancel: { self?.endSheet() })
        }
    }

    func showNewHostSheet() {
        presentSheet(size: .init(width: 360, height: 210)) { [weak self] in
            NewHostView(onDone: { self?.endSheet() })
        }
    }

    func showHostDetail(_ host: ForkHost) {
        presentSheet(size: .init(width: 420, height: 360)) { [weak self] in
            HostDetailView(host: host, onDone: { self?.endSheet() })
        }
    }

    private func presentSheet<V: View>(size: CGSize, @ViewBuilder _ content: () -> V) {
        guard let window, sheetPanel == nil else { return }
        let host = NSHostingController(rootView: content().environmentObject(registry))
        host.view.frame = .init(origin: .zero, size: size)
        let panel = ForkSheetPanel(contentViewController: host)
        sheetPanel = panel
        window.beginSheet(panel)
    }

    private func endSheet() {
        guard let panel = sheetPanel else { return }
        window?.endSheet(panel)
        sheetPanel = nil
    }

    // MARK: Window setup — wrap upstream's contentView in a sidebar split.

    override func windowDidLoad() {
        super.windowDidLoad()
        guard let window, let terminalContent = window.contentView else { return }

        window.tabbingMode = .disallowed
        window.isRestorable = false

        if ForkBootstrap.noSidebar {
            $surfaceTree
                .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
                .sink { [weak self] tree in self?.persistActive(tree) }
                .store(in: &cancellables)
            installNavMonitor()
            return
        }

        // Upstream's `BaseTerminalController.terminalViewContainer` is
        // `window?.contentView as? TerminalViewContainer`, and `SurfaceRepresentable`
        // re-creates its `SurfaceScrollView` wrapper whenever the split-tree's
        // `.id(structuralIdentity)` changes — both assume the container is
        // contentView. Reparenting it into an NSSplitView broke split rendering.
        // Instead: keep `terminalContent` as `window.contentView`, add the sidebar
        // as a sibling subview of the container, and re-pin the container's inner
        // hosting view to start after the sidebar.
        let sidebar = NSHostingView(rootView: SidebarView(controller: self).environmentObject(registry))
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        terminalContent.addSubview(sidebar)
        sidebarHost = sidebar
        sidebarWidthConstraint = sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: terminalContent.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: terminalContent.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: terminalContent.bottomAnchor),
            sidebarWidthConstraint!,
        ])
        // Shift the existing terminal hosting view (first subview, pinned to all
        // edges by TerminalViewContainer.setup()) to the right of the sidebar.
        // Pin to a constant offset, NOT `sidebar.trailingAnchor`, so SwiftUI re-renders
        // inside the sidebar's NSHostingView can't cascade into terminal autolayout
        // and re-set surface frames mid-SIGWINCH.
        if let hosting = terminalContent.subviews.first(where: { $0 !== sidebar }) {
            terminalContent.constraints
                .filter { ($0.firstItem === hosting && $0.firstAttribute == .leading)
                       || ($0.secondItem === hosting && $0.secondAttribute == .leading) }
                .forEach { $0.isActive = false }
            terminalLeadingConstraint = hosting.leadingAnchor.constraint(
                equalTo: terminalContent.leadingAnchor, constant: Self.sidebarWidth)
            terminalLeadingConstraint!.isActive = true
        }

        let reveal = NSButton(image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Show sidebar")!,
                              target: self, action: #selector(revealSidebar(_:)))
        reveal.isBordered = false
        reveal.isHidden = true
        reveal.translatesAutoresizingMaskIntoConstraints = false
        terminalContent.addSubview(reveal)
        NSLayoutConstraint.activate([
            reveal.leadingAnchor.constraint(equalTo: terminalContent.leadingAnchor, constant: 8),
            reveal.topAnchor.constraint(equalTo: terminalContent.topAnchor, constant: 8),
        ])
        sidebarReveal = reveal

        $surfaceTree
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] tree in self?.persistActive(tree) }
            .store(in: &cancellables)
        registry.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.syncWindowTitle() }
            .store(in: &cancellables)
        syncWindowTitle()
        installNavMonitor()
    }

    /// `BaseTerminalController.titleOverride` (`:94`) wins over `focusedSurface.title`.
    /// zmx is OSC-transparent, so shell title *does* reach `SurfaceView.title`; we just
    /// prefer the registry-derived "{tab} — {host}" for the window chrome.
    private func syncWindowTitle() {
        guard let tab = registry.activeTab else { titleOverride = nil; return }
        let host = registry.host(id: tab.hostID)?.label ?? tab.hostID
        titleOverride = "\(tab.title) — \(host)"
    }

    // MARK: Tab management

    func activate(tab id: TabModel.ID, paneIndex: Int? = nil) {
        let current = registry.activeTabID
        if current != id {
            // Snapshot the outgoing tab ONLY if it's been hydrated this session. On
            // cold start `current` is the disk-loaded id but `surfaceTree` is the
            // placeholder `.init()` — snapshotting that would set `current`'s persisted
            // tree to `.empty` and prune its labels/tags/lastActive.
            if let current, liveTabs[current] != nil {
                liveTabs[current] = surfaceTree
                registry.setPersistedTree(project(surfaceTree.root), for: current)
            }
            // Upstream's undo closures capture a *tree*, not a tab. Clear on every real
            // switch — including `current == nil`, which closeForkTab/removeHost produce.
            undoManager?.removeAllActions(withTarget: self)
            registry.setActive(tab: id)
        }
        // Relaunch arrives with `current == id` (registry loads activeTabID from disk) but
        // no `liveTabs` entry — must still rebuild AND assign, or `persistActive(.init())`
        // wipes it. `cold` discriminates that from a warm re-click on the active tab.
        let cold = liveTabs[id] == nil
        if cold { rebuildTree(for: id) }
        if current != id || cold, let tree = liveTabs[id] { surfaceTree = tree }
        // `surfaceTree.leaves()` and `PersistedTree.leafRefs` are both depth-first-left,
        // so the sidebar's pane-row offset addresses the matching live SurfaceView.
        // Write the highlight index in the same tick as `setActive` above; the async
        // focus roundtrip lands a frame later and would briefly show the prior tab's index.
        registry.setFocusedPane(index: paneIndex)
        guard let paneIndex else { return }
        let leaves = Array(surfaceTree)
        guard leaves.indices.contains(paneIndex) else { return }
        let target = leaves[paneIndex]
        // The sidebar click already stole firstResponder; writing `focusedSurface` (even
        // to the same value) fires its `didSet → syncFocusToSurfaceTree()`, which checks
        // `isFirstResponder` and would mark every pane unfocused mid-transition.
        if focusedSurface !== target { focusedSurface = target }
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(target)
        }
    }

    override func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {
        super.focusedSurfaceDidChange(to: to)
        // nil = focus left the split tree (sidebar click, sheet, etc.) — keep last-known
        // index so the highlight doesn't snap to head and back. `activate()` writes nil
        // explicitly when it actually wants the head fallback.
        guard let to else { return }
        registry.setFocusedPane(index: Array(surfaceTree).firstIndex { $0 === to })
        if let tab = registry.activeTabID, let key = registry.refs[to.id]?.key {
            registry.touchPane(tab: tab, name: key)
        }
    }

    func newForkTab(intent: NewSessionIntent) {
        guard let host = registry.host(id: intent.hostID), let app = ghostty.app else { return }
        let ref = SessionRef(hostID: host.id, name: intent.name ?? registry.uniqueAutoName(),
                             external: intent.external)
        let cfg = ZmxAdapter.surfaceConfig(host: host, ref: ref, initialCmd: intent.cmd, cwd: intent.cwd)
        let surface = Ghostty.SurfaceView(app, baseConfig: cfg)
        registry.bind(surface: surface.id, to: ref)
        let tab = registry.newTab(on: host.id, title: ref.name)
        liveTabs[tab.id] = .init(view: surface)
        // Match `gotoHost`/`revealRow`: force-expand so the new row is visible. Without this,
        // ⌘T onto a collapsed host swaps the terminal in but the sidebar shows nothing new.
        registry.setExpanded(host.id, true)
        activate(tab: tab.id)
    }

    func closeForkTab(_ id: TabModel.ID) {
        if let tree = liveTabs[id] {
            for surface in tree {
                registry.unbind(surface: surface.id)
                if watching.removeValue(forKey: surface.id) != nil {
                    registry.setWatching(surface.id, false)
                }
            }
        }
        liveTabs.removeValue(forKey: id)
        let wasActive = registry.activeTabID == id
        let host = registry.tabs.first { $0.id == id }?.hostID
        let i = host.flatMap { h in registry.tabs(on: h).firstIndex { $0.id == id } }
        registry.removeTab(id)
        guard wasActive else { return }
        let siblings = host.map(registry.tabs(on:)) ?? []
        let next = i.flatMap { siblings.indices.contains($0) ? siblings[$0].id : siblings.last?.id }
            ?? registry.tabs.first?.id
        if let next {
            activate(tab: next)
        } else {
            surfaceTree = .init()
        }
    }

    // MARK: Split — picker first (new vs attach-existing), then split (SPEC §5).

    private var pendingSplit: (at: Ghostty.SurfaceView, dir: SplitTree<Ghostty.SurfaceView>.NewDirection)?

    @discardableResult
    override func newSplit(
        at oldView: Ghostty.SurfaceView,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
        baseConfig config: Ghostty.SurfaceConfiguration? = nil
    ) -> Ghostty.SurfaceView? {
        guard sheetPanel == nil, let host = registry.activeHost else {
            // ⌘D leaks past an open sheet via the responder chain (same path as the ⌘V
            // gotcha). super.newSplit would spawn a non-zmx, unbound pane; swallow instead.
            return nil
        }
        let placeholder = registry.uniqueAutoName(derivedFrom: registry.refs[oldView.id]?.name)
        if ForkBootstrap.noPicker {
            return completeSplit(at: oldView, direction: direction, host: host,
                                 ref: .init(hostID: host.id, name: placeholder))
        }
        pendingSplit = (oldView, direction)
        presentSheet(size: .init(width: 280, height: 260)) { [weak self] in
            SplitPickerView(
                title: "Split on \(host.label)",
                host: host, placeholder: placeholder,
                onSubmit: { ref in
                    guard let self, let p = self.pendingSplit else { return }
                    self.pendingSplit = nil
                    _ = self.completeSplit(at: p.at, direction: p.dir, host: host, ref: ref)
                    self.endSheet()
                },
                onCancel: { self?.pendingSplit = nil; self?.endSheet() })
        }
        return nil
    }

    /// `super.` won't resolve inside the SwiftUI button-action closure above.
    private func completeSplit(
        at oldView: Ghostty.SurfaceView,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
        host: ForkHost, ref: SessionRef
    ) -> Ghostty.SurfaceView? {
        let cfg = ZmxAdapter.surfaceConfig(host: host, ref: ref)
        guard let view = super.newSplit(at: oldView, direction: direction, baseConfig: cfg) else { return nil }
        registry.bind(surface: view.id, to: ref)
        return view
    }

    // MARK: Persistence projection

    private func persistActive(_ tree: SplitTree<Ghostty.SurfaceView>) {
        guard let active = registry.activeTabID else { return }
        liveTabs[active] = tree
        // Intentionally no `pruneRefs` here: upstream's undo (`replaceSurfaceTree`
        // registers Close-Terminal undo) holds a strong ref to the closed SurfaceView;
        // pruning then ⌘Z → `project()` reads `refs[id] == nil` → persists `.leaf(nil)`.
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
                let r = ref ?? SessionRef(hostID: host.id, name: registry.uniqueAutoName())
                let cfg = ZmxAdapter.surfaceConfig(host: host, ref: r)
                let v = Ghostty.SurfaceView(app, baseConfig: cfg)
                registry.bind(surface: v.id, to: r)
                return .leaf(view: v)
            case .split(let h, let ratio, let a, let b):
                let na = revive(a), nb = revive(b)
                guard let na, let nb else { return na ?? nb }
                return .split(.init(direction: h ? .horizontal : .vertical, ratio: ratio, left: na, right: nb))
            }
        }
        let root = revive(tab.tree) ?? revive(.leaf(nil))
        liveTabs[tabID] = SplitTree<Ghostty.SurfaceView>(root: root, zoomed: nil)
    }

    /// Live tree for a tab, hydrating from persisted if it's never been activated this
    /// session. Distinguishes the three states: active → `surfaceTree`, parked-inactive
    /// → cached `liveTabs[id]`, never-activated → `rebuildTree` then return the cache.
    /// Never returns the `?? .init()` lie that lets a single-leaf write later poison
    /// `persistActive` — see PR21 review (movePane into dormant dst dropped panes).
    private func liveTree(for id: TabModel.ID) -> SplitTree<Ghostty.SurfaceView> {
        if id == registry.activeTabID { return surfaceTree }
        if liveTabs[id] == nil { rebuildTree(for: id) }
        return liveTabs[id] ?? .init()
    }
}
#endif
