#if os(macOS)
import Foundation
import Combine

enum RenameTarget: Hashable {
    case tab(TabModel.ID)
    case pane(TabModel.ID, name: String)
    var tabID: TabModel.ID {
        switch self { case .tab(let id), .pane(let id, _): id }
    }
}

/// Single source of truth for hosts, tabs, and the surface→session map. Sidebar and
/// controller observe this; all mutations route through it (SPEC §3).
@MainActor
final class SessionRegistry: ObservableObject {
    static let shared = SessionRegistry()

    @Published private(set) var hosts: [ForkHost]
    @Published private(set) var tabs: [TabModel]
    @Published private(set) var activeTabID: TabModel.ID?
    /// Depth-first leaf index of the focused pane within the active tab. Controller-owned
    /// (`activate(tab:)` writes optimistically, `focusedSurfaceDidChange` confirms); not persisted.
    @Published private(set) var focusedPaneIndex: Int?
    /// Sidebar inline-rename cursor. Controller writes via `promptTabTitle()` / `promptPaneTitle()`
    /// (⌘⇧I / ⌘I); sidebar writes via double-click / context-menu; not persisted.
    @Published private(set) var renaming: RenameTarget?
    /// MRU of in-use tags (newest first, ≤8). `paneTags.values` is hash-order so deriving
    /// "recent" from it is arbitrary; this is the source of truth for the context-menu shortlist.
    /// Pruned to live `paneTags` on every mutation that can drop the last user of a tag.
    @Published private(set) var recentTags: [PaneTag]
    /// Surfaces with a one-shot watch armed (⌘⌥A). Mirrors keys of the controller's
    /// private `watching` cancellable dict so SidebarView can render the eye; ephemeral.
    @Published private(set) var watchedSurfaces: Set<UUID> = []
    func setWatching(_ id: UUID, _ on: Bool) {
        if on { watchedSurfaces.insert(id) } else { watchedSurfaces.remove(id) }
    }

    /// Not @Published: pure surface→session bookkeeping the sidebar never renders
    /// directly. `isConnected()` reads it, but every flow that mutates `refs` also
    /// mutates a @Published prop, so the derived UI stays fresh.
    private(set) var refs: [UUID: SessionRef] = [:]

    private let persistence = ForkPersistence()
    private var saveDebounce: AnyCancellable?

    private init() {
        let state = persistence.load()
        self.hosts = state.hosts.isEmpty ? [.local] : state.hosts
        self.tabs = state.tabs
        self.activeTabID = state.activeTabID
        self.recentTags = state.recentTags
        pruneRecentTags()
        saveDebounce = objectWillChange
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.persistence.save(self?.snapshot()) }
    }

    // MARK: Queries

    func host(id: ForkHost.ID) -> ForkHost? { hosts.first { $0.id == id } }
    func tabs(on hostID: ForkHost.ID) -> [TabModel] { tabs.filter { $0.hostID == hostID } }
    var activeTab: TabModel? { activeTabID.flatMap { id in tabs.first { $0.id == id } } }
    var activeHost: ForkHost? { activeTab.flatMap { host(id: $0.hostID) } }

    /// `connected` iff ≥1 surface bound to a session on this host (SPEC §3: status is computed).
    func isConnected(_ hostID: ForkHost.ID) -> Bool {
        refs.values.contains { $0.hostID == hostID }
    }

    /// Title of the tab containing `sessionName`, iff that title differs from the name
    /// (i.e. the user renamed it). Lets pickers annotate raw zmx names with the label
    /// the user actually recognizes.
    func tabTitle(for sessionName: String, external: Bool, on hostID: ForkHost.ID) -> String? {
        tabs.first {
            $0.hostID == hostID && $0.tree.leafRefs.contains {
                $0.name == sessionName && $0.external == external
            }
        }.flatMap { $0.title == sessionName ? nil : $0.title }
    }

    // MARK: Mutations

    func addHost(_ h: ForkHost) {
        guard host(id: h.id) == nil else { return }
        hosts.append(h)
    }

    func removeHost(_ id: ForkHost.ID) {
        guard id != ForkHost.local.id else { return }
        hosts.removeAll { $0.id == id }
        tabs.removeAll { $0.hostID == id }
        if let active = activeTabID, !tabs.contains(where: { $0.id == active }) { activeTabID = nil }
        pruneRecentTags()
    }

    func renameHost(_ id: ForkHost.ID, to label: String) {
        guard let i = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[i].label = label
    }

    func setAccentHue(_ id: ForkHost.ID, _ hue: Double?) {
        guard let i = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[i].accentHue = hue
    }

    func setExpanded(_ hostID: ForkHost.ID, _ v: Bool) {
        guard let i = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        hosts[i].expanded = v
    }

    @discardableResult
    func newTab(on hostID: ForkHost.ID, title: String) -> TabModel {
        let t = TabModel(hostID: hostID, title: title)
        tabs.append(t)
        return t
    }

    func renameTab(_ id: TabModel.ID, to title: String) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[i].title = title
    }

    func removeTab(_ id: TabModel.ID) {
        tabs.removeAll { $0.id == id }
        if activeTabID == id { activeTabID = nil }
        if renaming?.tabID == id { renaming = nil }
        pruneRecentTags()
    }

    func moveTab(_ id: TabModel.ID, before target: TabModel.ID) {
        guard id != target,
              let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == target }),
              tabs[from].hostID == tabs[to].hostID else { return }
        tabs.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
    }

    func setActive(tab id: TabModel.ID) { activeTabID = id }

    func setCollapsed(_ id: TabModel.ID, _ v: Bool) {
        guard let i = tabs.firstIndex(where: { $0.id == id }), tabs[i].collapsed != v else { return }
        tabs[i].collapsed = v
    }
    func setFocusedPane(index: Int?) { if focusedPaneIndex != index { focusedPaneIndex = index } }
    func setRenaming(_ t: RenameTarget?) { if renaming != t { renaming = t } }

    func touchPane(tab id: TabModel.ID, name: String) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[i].lastActive[name] = Date()
    }

    func setPaneLabel(tab id: TabModel.ID, name: String, to label: String?) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let label { tabs[i].paneLabels[name] = label } else { tabs[i].paneLabels.removeValue(forKey: name) }
    }

    func setPaneTag(tab id: TabModel.ID, name: String, to tag: PaneTag?) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let tag {
            tabs[i].paneTags[name] = tag
            recentTags.removeAll { $0 == tag }
            recentTags.insert(tag, at: 0)
            if recentTags.count > 8 { recentTags.removeLast() }
        } else {
            tabs[i].paneTags.removeValue(forKey: name)
        }
        pruneRecentTags()
    }

    private func pruneRecentTags() {
        let live = Set(tabs.flatMap(\.paneTags.values))
        let kept = recentTags.filter(live.contains)
        if kept.count != recentTags.count { recentTags = kept }
    }

    func bind(surface: UUID, to ref: SessionRef) { refs[surface] = ref }
    func unbind(surface: UUID) { refs.removeValue(forKey: surface) }
    func saveNow() { persistence.save(snapshot()) }

    func setPersistedTree(_ tree: PersistedTree, for tabID: TabModel.ID) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[i].tree = tree
        let live = Set(tree.leafRefs.map(\.key))
        tabs[i].lastActive = tabs[i].lastActive.filter { live.contains($0.key) }
        tabs[i].paneLabels = tabs[i].paneLabels.filter { live.contains($0.key) }
        tabs[i].paneTags = tabs[i].paneTags.filter { live.contains($0.key) }
        pruneRecentTags()
    }

    // MARK: Pane move / tab merge (PR21)
    //
    // Persisted-side surgery only — live `SurfaceView` reparenting stays in the
    // controller per the "one architectural rule" in Fork/CLAUDE.md. These methods
    // keep the zmx session alive: they don't touch `refs` (surface→session map) so
    // whatever `SurfaceView` owns the pty continues running; the controller is
    // expected to reparent that view in the live `SplitTree` after calling these.

    /// Move a leaf from `src` to `dst` (same host only). Migrates per-pane state
    /// (labels/tags/lastActive) BEFORE `setPersistedTree` since that prunes non-live
    /// keys. `dst`'s tree gets `ref` appended on the right; `src`'s tree may become
    /// `.empty` — the controller is responsible for detecting that and closing src.
    /// Returns true on success, false if refused (cross-host, missing tab, ref not
    /// in src, src == dst).
    @discardableResult
    func movePanePersisted(from src: TabModel.ID, ref: SessionRef, to dst: TabModel.ID) -> Bool {
        guard src != dst,
              let si = tabs.firstIndex(where: { $0.id == src }),
              let di = tabs.firstIndex(where: { $0.id == dst }),
              tabs[si].hostID == tabs[di].hostID,
              tabs[si].tree.leafRefs.contains(ref) else { return false }
        let key = ref.key
        let label = tabs[si].paneLabels[key]
        let tag = tabs[si].paneTags[key]
        let last = tabs[si].lastActive[key]
        if let label { tabs[di].paneLabels[key] = label }
        if let tag { tabs[di].paneTags[key] = tag }
        if let last { tabs[di].lastActive[key] = last }
        setPersistedTree(tabs[di].tree.appending(leaf: ref), for: dst)
        setPersistedTree(tabs[si].tree.removing(ref), for: src)
        return true
    }

    // `moveToNewTabPersisted` and `mergeTabPersisted` are intentionally absent —
    // the controller doesn't use them (it creates new tabs via `newTab` and folds
    // merges through `movePane`), and keeping "tests-only" variants diverges from
    // the controller's live-tree shape, which the tests couldn't catch.

    // MARK: Persistence

    func snapshot() -> ForkPersistence.State {
        .init(hosts: hosts, tabs: tabs, activeTabID: activeTabID, recentTags: recentTags)
    }

    static func autoName(base: String = "shell", suffixLen: Int = 3) -> String {
        let alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
        let suffix = String((0..<suffixLen).map { _ in alphabet.randomElement()! })
        return "\(base)-\(suffix)"
    }

    /// `autoName()` retried until disjoint from live refs and dormant persisted-tree leaves.
    /// `derivedFrom` seeds the name from an existing session (split picker passes the
    /// focused pane's name); nil → default `shell-xxx`.
    func uniqueAutoName(derivedFrom base: String? = nil) -> String {
        let used = Set(refs.values.map(\.name))
            .union(tabs.flatMap(\.tree.leafRefs).map(\.name))
        // Strip a prior derived suffix so chained splits don't grow `foo-abcd-efgh-ijkl`.
        // Only strip when the stem is itself a live session — otherwise `-xxxx` is part
        // of a user-chosen name (`api-prod`), not an auto-suffix.
        let stem: String? = base.map {
            let s = $0.replacingOccurrences(of: #"-[a-z0-9]{4}$"#, with: "",
                                            options: .regularExpression)
            return s != $0 && used.contains(s) ? s : $0
        }
        while true {
            let n = stem.map { Self.autoName(base: $0, suffixLen: 4) } ?? Self.autoName()
            if !used.contains(n) { return n }
        }
    }
}
#endif
