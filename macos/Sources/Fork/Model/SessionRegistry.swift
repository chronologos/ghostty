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

/// Projection of `PaneMachine.dot` — what the sidebar/rollup/badge render.
/// `Comparable` order is "needs me most" for `rollup` max-reduce.
enum PaneState: Comparable { case working, waiting, blocked }

/// Single source of truth for hosts, tabs, and the surface→session map. Sidebar and
/// controller observe this; all mutations route through it (SPEC §3).
@MainActor
final class SessionRegistry: ObservableObject {
    static let shared = SessionRegistry()

    /// UserDefaults keys read by both `SidebarView` (`@AppStorage`) and `gotoTab` —
    /// renaming the `@AppStorage` literal alone would silently desync ⌘1-9.
    static let kFilterTagged = "forkSidebarFilterTagged"
    static let kFocusMode = "forkSidebarFocus"
    static let kFocusCutoffHours = "forkFocusCutoffHours"
    static let kFocusSortMRU = "forkFocusSortMRU"

    @Published private(set) var hosts: [ForkHost]
    @Published private(set) var tabs: [TabModel]
    @Published private(set) var activeTabID: TabModel.ID?
    /// Depth-first leaf index of the focused pane within the active tab. Controller-owned
    /// (`activate(tab:)` writes optimistically, `focusedSurfaceDidChange` confirms); not persisted.
    @Published private(set) var focusedPaneIndex: Int?
    /// Sidebar inline-rename cursor. Controller writes via `promptTabTitle()` / `promptPaneTitle()`
    /// (⌘⇧I / ⌘I); sidebar writes via double-click / context-menu; not persisted.
    @Published private(set) var renaming: RenameTarget?
    // (The tag-popover cursor is SidebarView `@State` now — its only readers/writers are
    // sidebar rows. It lived here for the hover-key monitor, which is gone; registry
    // residence also meant every popover open/close churned the debounce-save sink.)
    /// MRU of in-use tags (newest first, ≤8). `paneTags.values` is hash-order so deriving
    /// "recent" from it is arbitrary; this is the source of truth for the context-menu shortlist.
    /// Pruned to live `paneTags` on every mutation that can drop the last user of a tag.
    @Published private(set) var recentTags: [PaneTag]
    /// User-defined pane commands, hand-edited in `fork.json`; surface in the ⌘K palette
    /// targeting the focused pane. Loaded once; not `@Published`.
    let hoverCommands: [String: HoverCommand]

    /// Per-session status reducer — see `PaneMachine`. Single owner of working/waiting/
    /// blocked/watched/notified; everything else is a projection. Ephemeral.
    @Published private(set) var panes: [SessionRef: PaneMachine] = [:]
    /// Only writer. `!=` guard ⇒ steady-state probe ticks don't publish.
    @discardableResult
    func apply(_ ref: SessionRef, _ e: PaneEvent) -> Bool {
        var m = panes[ref, default: .init()]; let post = m.apply(e)
        if panes[ref] != m { panes[ref] = m }; return post
    }
    func dot(ref: SessionRef) -> PaneState? { panes[ref]?.dot }
    /// Worst-child state for a collapsed tab heading — max-reduce over `dot`. Registry-side
    /// (not controller) so cold and live tabs read the same way and a nil controller can't
    /// silently render no rollup. Host-level rollups are a `.max()` over this at the call
    /// site — the sidebar must reduce over its *filtered* tab set, not all tabs on the host.
    func rollup(tab: TabModel) -> PaneState? {
        tab.tree.leafRefs.lazy.compactMap { self.dot(ref: $0) }.max()
    }
    /// Called when a ref leaves all trees (`removeTab`/`removeHost` — NOT
    /// `setPersistedTree`, which must preserve `blockSig`/`watched` across ⌘W→⌘Z).
    func dropPane(_ ref: SessionRef) { panes.removeValue(forKey: ref) }
    private func refInAnyTree(_ r: SessionRef) -> Bool {
        tabs.contains { $0.tree.leafRefs.contains(r) }
    }

    /// Live CC-session info per pane (`CCProbe`), keyed `[hostID][ref.key]`. Ephemeral; the
    /// poll only runs while the sidebar's `showCC` toggle is on.
    @Published private(set) var ccLive: [ForkHost.ID: [String: CCProbe.Info]] = [:]
    /// Heartbeat timestamps split out from `ccLive` so steady-state poll ticks can refresh
    /// them without firing `objectWillChange` (`Info.==` excludes `updatedAt` for that
    /// reason). The pane row's doze/peek-age read this *inside* the row's 60s clock, so the
    /// displayed value tracks the actual heartbeat — reading `ccLive[].updatedAt` instead
    /// would freeze at time-of-last-status-change.
    private(set) var ccUpdatedAt: [ForkHost.ID: [String: Date]] = [:]
    /// Status text the user has caught up on, keyed like `ccLive`: stamped with the pane's
    /// current `detail` when focus *leaves* it (exit-stamp / window close) or by the ⌥⌥
    /// sweep, so the sidebar reads as unread activity rather than a transcript — `ccLine`
    /// demotes text to a dim one-liner while it still equals this. Not @Published (a row
    /// only needs to flip on the next activation/probe render, both of which already
    /// publish; `markAllCCRead` sends explicitly) and not persisted (a fresh launch shows
    /// everything again).
    private(set) var ccSeenDetail: [ForkHost.ID: [String: String]] = [:]
    /// Hosts whose `zmx list` transport is currently failing (unreachable / ssh refused /
    /// zmx missing), with the time of the first failed poll — drives the sidebar's
    /// "unreachable" cue so hours-old status can't masquerade as live. Distinct from a nil
    /// probe (which also covers "no CC sessions"); only a transport failure counts. Not
    /// @Published — `noteHostReachability` publishes on the rare transition instead.
    private(set) var hostUnreachableSince: [ForkHost.ID: Date] = [:]
    private var ccPoll: Task<Void, Never>?

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
        self.hoverCommands = state.hoverCommands
        pruneRecentTags()
        saveDebounce = objectWillChange
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.persistence.save(self?.snapshot()) }
        // After autosave is wired so the one-time migration of nil-slot hosts persists.
        resolveAutoSlots()
    }

    var takenSlots: Set<Int> { Set(hosts.compactMap(\.accentSlot)) }
    /// Assign every nil-slot host an `autoSlot`. Stored so deleting host A can't shift B's.
    private func resolveAutoSlots() {
        var taken = takenSlots
        for i in hosts.indices where hosts[i].accentSlot == nil {
            let s = ForkHost.autoSlot(for: hosts[i].id, avoiding: taken)
            taken.insert(s); hosts[i].accentSlot = s
        }
    }

    // MARK: Queries

    func host(id: ForkHost.ID) -> ForkHost? { hosts.first { $0.id == id } }
    func tabs(on hostID: ForkHost.ID) -> [TabModel] { tabs.filter { $0.hostID == hostID } }
    var activeTab: TabModel? { activeTabID.flatMap { id in tabs.first { $0.id == id } } }
    var activeHost: ForkHost? { activeTab.flatMap { host(id: $0.hostID) } }

    /// Tabs the sidebar renders for a host in normal (non-focus) mode — and exactly what
    /// ⌘1-9 indexes there. One implementation shared by `SidebarView.hostSection` and
    /// `gotoTab` so the visible order and the keyboard order can't drift (focus mode
    /// already shares `focusTabs` the same way).
    func hostTabs(on hostID: ForkHost.ID, taggedOnly: Bool) -> [TabModel] {
        let all = tabs(on: hostID)
        return taggedOnly ? all.filter(\.hasTag) : all
    }

    /// Effective focus-cutoff in seconds. `> 0` covers unset (UserDefaults returns 0; the
    /// slider only writes 1–64). Shared by `focusTabs` and the sidebar's doze so "asleep"
    /// and "hidden from focus" can't drift to different thresholds.
    static func focusCutoffSeconds(hours: Double) -> TimeInterval { (hours > 0 ? hours : 16) * 3600 }

    /// Focus-mode row order: pinned first, then by MRU (or registry order when the
    /// `kFocusSortMRU` toggle is off), filtered to recent (or tagged-only).
    /// Shared by `SidebarView.focusSection` and `gotoTab` so ⌘1-9 addresses what's visible.
    /// Active tab is forced to `.distantFuture` so a freshly-created tab (whose `lastActive`
    /// is still empty until async focus settlement runs `touchPane`) passes the cutoff and
    /// sorts to the top instead of flashing at the bottom.
    /// `.blocked` is *intentionally* not in filter/sort here (PR35) — the red dot is
    /// visual-only; PR33's "blocked surfaces past the 16h cutoff and sorts above MRU"
    /// was removed at the user's request. Don't re-add.
    func focusTabs(taggedOnly: Bool) -> [TabModel] {
        // The slider's `@AppStorage` write triggers a SidebarView re-render that re-calls
        // this — no registry plumbing needed for cutoff changes.
        let h = UserDefaults.standard.double(forKey: Self.kFocusCutoffHours)
        let cutoff = Date().addingTimeInterval(-Self.focusCutoffSeconds(hours: h))
        let active = activeTabID
        func mru(_ t: TabModel) -> Date {
            t.id == active ? .distantFuture : (t.lastActive.values.max() ?? .distantPast)
        }
        let kept = tabs.filter {
            guard $0.id != active else { return true }
            guard mru($0) >= ($0.dismissedAt ?? .distantPast) else { return false }
            return $0.pinned || (taggedOnly ? $0.hasTag : mru($0) > cutoff)
        }
        // Filter and sort are decoupled: with MRU sort off, group by host (sidebar host
        // order) then per-host registry order — the flat `tabs` array interleaves hosts by
        // creation time, which reads as random next to the host-badge column. Rows never
        // jump as you switch tabs. Pinned-first survives either way — it's an explicit
        // gesture, not an implicit reordering. The two-pass filters are deliberate:
        // `sorted` isn't documented stable. `nil` default = true (current behavior);
        // `bool(forKey:)` would read unset as false.
        guard (UserDefaults.standard.object(forKey: Self.kFocusSortMRU) as? Bool) ?? true else {
            let grouped = hosts.flatMap { h in kept.filter { $0.hostID == h.id } }
            return grouped.filter(\.pinned) + grouped.filter { !$0.pinned }
        }
        return kept.sorted { $0.pinned != $1.pinned ? $0.pinned : mru($0) > mru($1) }
    }

    /// "Inbox-zero" hide: stamp `dismissedAt` so `focusTabs` filters the tab until next
    /// activate (`touchPane` clears it). Unpins too — pin would otherwise override the dismiss.
    func dismissFromFocus(_ id: TabModel.ID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[i].dismissedAt = Date()
        tabs[i].pinned = false
    }

    /// `connected` iff ≥1 surface bound to a session on this host (SPEC §3: status is computed).
    func isConnected(_ hostID: ForkHost.ID) -> Bool {
        refs.values.contains { $0.hostID == hostID }
    }

    private func tab(containing sessionName: String, external: Bool, on hostID: ForkHost.ID) -> TabModel? {
        tabs.first {
            $0.hostID == hostID && $0.tree.leafRefs.contains {
                $0.name == sessionName && $0.external == external
            }
        }
    }

    /// Title of the tab containing `sessionName`, iff that title differs from the name
    /// (i.e. the user renamed it). Lets pickers annotate raw zmx names with the label
    /// the user actually recognizes.
    func tabTitle(for sessionName: String, external: Bool, on hostID: ForkHost.ID) -> String? {
        tab(containing: sessionName, external: external, on: hostID)
            .flatMap { $0.title == sessionName ? nil : $0.title }
    }

    /// The session is already open as a pane somewhere in the sidebar — including a
    /// cold-restored placeholder, which holds no zmx client and would otherwise read as
    /// orphaned in the session lists.
    func isInSidebar(_ sessionName: String, external: Bool, on hostID: ForkHost.ID) -> Bool {
        tab(containing: sessionName, external: external, on: hostID) != nil
    }

    /// Last-known CC info for a *listed* session (open as a pane or not — `mergeCC` stores
    /// the whole probe result per host, so detached sessions with an agent inside are
    /// covered). Nil unless the host is currently polled (CC toggle on *and* the host has
    /// at least one sidebar tab): an unpolled host's slice stays frozen at whatever the
    /// last poll saw — possibly hours old — and a stale "working" glyph is worse than an
    /// honest unknown. Within a polled host the data lags by up to a poll tick and
    /// survives probe failures (keep-last-known).
    func ccInfo(for entry: ZmxAdapter.ListEntry, on hostID: ForkHost.ID) -> CCProbe.Info? {
        guard tabs.contains(where: { $0.hostID == hostID }) else { return nil }
        return ccLive[hostID]?[SessionRef(hostID: hostID, name: entry.name, external: entry.external).key]
    }

    // MARK: Mutations

    func addHost(_ h: ForkHost) {
        guard host(id: h.id) == nil else { return }
        hosts.append(h); resolveAutoSlots()
    }

    func removeHost(_ id: ForkHost.ID) {
        guard id != ForkHost.local.id else { return }
        hosts.removeAll { $0.id == id }
        tabs.removeAll { $0.hostID == id }
        if ccLive[id] != nil { ccLive[id] = nil }
        ccUpdatedAt[id] = nil
        ccSeenDetail[id] = nil
        hostUnreachableSince[id] = nil
        panes = panes.filter { $0.key.hostID != id }
        if let active = activeTabID, !tabs.contains(where: { $0.id == active }) { activeTabID = nil }
        pruneRecentTags()
    }

    private func updateHost(_ id: ForkHost.ID, _ f: (inout ForkHost) -> Void) {
        guard let i = hosts.firstIndex(where: { $0.id == id }) else { return }
        f(&hosts[i])
    }

    func renameHost(_ id: ForkHost.ID, to label: String) { updateHost(id) { $0.label = label } }
    func setAccentSlot(_ id: ForkHost.ID, _ slot: Int?) { updateHost(id) { $0.accentSlot = slot } }
    func setExpanded(_ id: ForkHost.ID, _ v: Bool)       { updateHost(id) { $0.expanded = v } }

    func moveHost(_ id: ForkHost.ID, before target: ForkHost.ID) {
        guard id != target,
              let from = hosts.firstIndex(where: { $0.id == id }),
              let to = hosts.firstIndex(where: { $0.id == target }) else { return }
        hosts.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
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
        let removed = tabs.first { $0.id == id }
        let dropped = removed?.tree.leafRefs ?? []
        tabs.removeAll { $0.id == id }
        if activeTabID == id { activeTabID = nil }
        if renaming?.tabID == id { renaming = nil }
        for r in dropped where !refInAnyTree(r) { dropPane(r) }
        pruneRecentTags()
        // Last tab on a host → the host leaves the poll's `due` set, so nothing left
        // running can ever clear its unreachable badge; a frozen "Unreachable since…"
        // would outlive the host coming back.
        if let hostID = removed?.hostID, !tabs.contains(where: { $0.hostID == hostID }),
           hostUnreachableSince[hostID] != nil {
            objectWillChange.send()
            hostUnreachableSince[hostID] = nil
        }
    }

    func moveTab(_ id: TabModel.ID, before target: TabModel.ID) {
        guard id != target,
              let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == target }),
              tabs[from].hostID == tabs[to].hostID else { return }
        tabs.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
    }

    func setActive(tab id: TabModel.ID) {
        activeTabID = id
        // Record the visit (browser semantics, two refinements):
        // 1. Skip when the cursor already points at `id` — that's how `historyStep`
        //    navigations come back through here without truncating their own forward
        //    stack, and how a re-click on the already-active tab stays a no-op.
        if tabHistory.indices.contains(tabHistoryCursor), tabHistory[tabHistoryCursor] == id { return }
        // 2. Visiting the tab that is already the *next forward entry* = stepping forward
        //    (a sidebar click on it, or a tab-close auto-activation landing there): advance
        //    the cursor instead of truncating — the forward timeline is unchanged, so
        //    destroying it would lose history the user can still legitimately walk.
        if tabHistory.indices.contains(tabHistoryCursor + 1), tabHistory[tabHistoryCursor + 1] == id {
            tabHistoryCursor += 1
            return
        }
        // Fresh visit: truncate the forward entries, append.
        tabHistory.removeSubrange((tabHistoryCursor + 1)..<tabHistory.count)
        tabHistory.append(id)
        // Bound the walk — 64 visits of history outlasts any back-button mash, and the
        // array holds only UUIDs.
        if tabHistory.count > 64 { tabHistory.removeFirst(tabHistory.count - 64) }
        tabHistoryCursor = tabHistory.count - 1
    }

    // MARK: Tab visit history (mouse back/forward)

    /// Visit history for back/forward navigation: `setActive` appends, `historyStep` moves
    /// the cursor without re-recording, and a fresh visit while the cursor is mid-history
    /// truncates the forward entries — i.e. browser semantics. Ephemeral by design: tab IDs
    /// persist across relaunch, but replaying last week's click trail as "history" would be
    /// noise, the same policy as `lastTouched`.
    private(set) var tabHistory: [TabModel.ID] = []
    private(set) var tabHistoryCursor = -1

    /// First walkable index in `delta`'s direction: skips tabs that have since been closed
    /// (not pruned — pruning would need cursor arithmetic in `removeTab`; skipping is
    /// equivalent and local) AND the currently active tab ("navigating" to where you
    /// already are would be a silent no-op that burns the rest of the walk — the
    /// [A, closed-B, A] pattern a tab close leaves behind).
    private func historyScan(_ delta: Int) -> Int? {
        var i = tabHistoryCursor + delta
        while tabHistory.indices.contains(i) {
            if tabHistory[i] != activeTabID, tabs.contains(where: { $0.id == tabHistory[i] }) {
                return i
            }
            i += delta
        }
        return nil
    }

    /// Whether a back (-1) / forward (+1) step has somewhere real to go. The ⌘K palette
    /// uses this to decide whether to offer the entries — raw cursor-bounds checks would
    /// offer steps that land nowhere (dead or already-active entries).
    func canHistoryStep(_ delta: Int) -> Bool { historyScan(delta) != nil }

    /// Move the visit cursor by `delta` (-1 = back, +1 = forward) and return the tab to
    /// activate. nil = nothing real in that direction; the cursor doesn't move.
    func historyStep(_ delta: Int) -> TabModel.ID? {
        guard let i = historyScan(delta) else { return nil }
        tabHistoryCursor = i
        return tabHistory[i]
    }

    func setCollapsed(_ id: TabModel.ID, _ v: Bool) {
        guard let i = tabs.firstIndex(where: { $0.id == id }), tabs[i].collapsed != v else { return }
        tabs[i].collapsed = v
    }
    func setPinned(_ id: TabModel.ID, _ v: Bool) {
        guard let i = tabs.firstIndex(where: { $0.id == id }), tabs[i].pinned != v else { return }
        tabs[i].pinned = v
        // Pin trumps dismiss — `focusTabs` checks `dismissedAt` before `pinned`, so a
        // re-pin without this clear would leave the tab hidden until next `touchPane`.
        if v { tabs[i].dismissedAt = nil }
    }
    func setFocusedPane(index: Int?) { if focusedPaneIndex != index { focusedPaneIndex = index } }
    func setRenaming(_ t: RenameTarget?) { if renaming != t { renaming = t } }

    /// Last (tab, pane) that `touchPane` stamped — i.e. the pane focus is leaving when the
    /// next touch arrives. Not persisted: a stale exit-stamp across relaunch is meaningless.
    private var lastTouched: (TabModel.ID, String)?

    /// Stamp a departed pane's `lastActive` at "now", and its current CC `detail` as seen
    /// (`ccSeenDetail`) — whatever was on the status line when you walked away is read; only
    /// text CC writes after that re-expands the row.
    private func exitStamp(_ prev: (TabModel.ID, String)) {
        guard let p = tabs.firstIndex(where: { $0.id == prev.0 }) else { return }
        // Read-state stamps regardless of the recency guards below — what was in front of
        // you when you left is read even if the same gesture Hid the tab. Keep the previous
        // stamp through a transient nil (probe gap, CC restart): wiping it would re-flag
        // the same old text as unread on the next poll.
        if let d = ccLive[tabs[p].hostID]?[prev.1]?.detail {
            ccSeenDetail[tabs[p].hostID, default: [:]][prev.1] = d
        }
        // The MRU stamp keeps its guards: skip if the entry was pruned (don't resurrect a
        // removed pane) or the tab was dismissed while focused (the exit-stamp must not
        // undo Hide — only a touch *of that tab* clears `dismissedAt`).
        guard tabs[p].dismissedAt == nil, tabs[p].lastActive[prev.1] != nil else { return }
        tabs[p].lastActive[prev.1] = Date()
    }

    /// ⌥⌥ "quiet sweep": mark every pane's current status text read in one gesture — the
    /// fleet-wide counterpart of leaving a pane, for the return-from-away wall where nothing
    /// has actually been visited yet. Demotes, never deletes — rows keep their dim one-line
    /// trace, and anything CC says *after* the sweep is unread again. Explicit publish:
    /// nothing this writes is @Published, and the sweep should repaint now, not on the next
    /// probe tick.
    func markAllCCRead() {
        // Delta-guarded: a second ⌥⌥ (or one with nothing unread) must not publish — the
        // send re-evaluates the whole sidebar and tickles the debounce-save sink for
        // nothing (`ccSeenDetail` isn't persisted). Scoped to sessions attached in some
        // tab: `ccLive` also carries never-attached sessions on the host, and "read" must
        // only ever mean "was on a row you could have seen".
        var pending: [(ForkHost.ID, String, String)] = []
        for (host, infos) in ccLive {
            let attached = Set(tabs.filter { $0.hostID == host }.flatMap { $0.tree.leafRefs.map(\.key) })
            for (key, info) in infos where attached.contains(key) {
                if let d = info.detail, ccSeenDetail[host]?[key] != d { pending.append((host, key, d)) }
            }
        }
        guard !pending.isEmpty else { return }
        objectWillChange.send()
        for (host, key, d) in pending { ccSeenDetail[host, default: [:]][key] = d }
    }

    /// Focus is leaving the fork window entirely (window close, not a pane switch): record
    /// the departure now and forget it, so the next touch — possibly hours later, on reopen —
    /// can't back-date the departure to "just now".
    func flushPaneExit() {
        if let prev = lastTouched { exitStamp(prev) }
        lastTouched = nil
    }

    func touchPane(tab id: TabModel.ID, name: String) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        // Exit-stamp the pane being left: `lastActive` means "last time this pane was the
        // focused one", and arrival-only stamping would leave a pane you sat in for an hour
        // reading as an hour old the moment you switch away (kills the sidebar afterglow
        // trail, and under-ranks the tab in focus-mode MRU). The stamp is written at the
        // *next* touch, so an absence (⌘-tab away, sleep) inflates the departed pane's
        // recency by the gap — accepted: it was still the current pane that whole time.
        if let prev = lastTouched, prev != (id, name) { exitStamp(prev) }
        lastTouched = (id, name)
        tabs[i].lastActive[name] = Date()
        // Watermark check (`mru >= dismissedAt`) regresses if `setPersistedTree` later
        // prunes `lastActive` to empty, so clear explicitly — same as `setPinned(true)`.
        tabs[i].dismissedAt = nil
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

    // MARK: CC probe (PR30)

    func setCCProbeEnabled(_ on: Bool) {
        if on, ccPoll == nil {
            ccPoll = Task { [weak self] in await self?.ccPollLoop() }
        } else if !on {
            ccPoll?.cancel(); ccPoll = nil
            if !ccLive.isEmpty { ccLive = [:] }
            ccUpdatedAt = [:]
            hostUnreachableSince = [:]
            // `blocked`/`blockSig` survive toggle (the machine holds the edge-detect latch),
            // but `ccBusy` must not — nothing else clears it once the poll stops, and `dot`
            // would wedge at `.working` forever.
            for ref in Array(panes.keys) { apply(ref, .probeStopped) }
        }
    }

    private func ccPollLoop() async {
        var tick = 0
        while !Task.isCancelled {
            let due = hosts.filter { h in
                tabs.contains { $0.hostID == h.id } && (h.transport.isLocal || tick % 5 == 0)
            }
            // Fan-out so one unreachable ssh host (5s timeout) doesn't head-of-line-block
            // the local 3s cadence; merge each result as it arrives. The third tuple slot is
            // "the transport itself failed" — `mergeCC` can't tell that apart from "no CC
            // sessions" (both arrive as nil), and only the former should mark the host
            // unreachable.
            let tickStart = ContinuousClock.now
            await withTaskGroup(of: (ForkHost.ID, [String: CCProbe.Info]?, Bool).self) { group in
                for h in due {
                    group.addTask {
                        guard let list = await ZmxAdapter.list(host: h) else { return (h.id, nil, true) }
                        return (h.id, await CCProbe.probe(host: h, entries: list.managed + list.external), false)
                    }
                }
                for await (id, result, listFailed) in group {
                    mergeCC(hostID: id, result: result)
                    noteHostReachability(id, unreachable: listFailed)
                }
            }
            tick &+= 1
            // Nobody can see the sidebar (window occluded / minimized / screen locked):
            // stretch the cadence ~10×. Slow rather than stop — `.probeStopped` semantics
            // (the ccBusy wedge) only apply to a stopped poll, and a slow tick still
            // refreshes within 30s of the user coming back. Agents running overnight with
            // the screen locked are otherwise the fork's single biggest CPU/traffic source.
            //
            // Deadline cadence, not a flat post-drain sleep: a down ssh host costs its full
            // 5s connect timeout inside the drain above, and sleeping another 3s after that
            // pushed the *local* host's next probe to ~8s. The drain time counts against
            // the interval, so tick cadence = max(interval, slowest host).
            let visible = ForkWindowController.anyVisibleForkWindow
            let interval: Duration = .seconds(visible ? 3 : 30)
            let elapsed = ContinuousClock.now - tickStart
            if elapsed < interval { try? await Task.sleep(for: interval - elapsed) }
        }
    }

    /// Flip the per-host unreachable marker, publishing only on the transition (appearing or
    /// clearing) — never per tick.
    private func noteHostReachability(_ id: ForkHost.ID, unreachable: Bool) {
        // Same drain races `mergeCC` guards against: probe toggled off mid-tick (the
        // cancelled list() reports a spurious failure after the clear, and with the poll
        // off nothing would ever clear the badge again) or host removed mid-tick.
        guard ccPoll != nil, host(id: id) != nil else { return }
        if unreachable, hostUnreachableSince[id] == nil {
            objectWillChange.send()
            hostUnreachableSince[id] = Date()
        } else if !unreachable, hostUnreachableSince[id] != nil {
            objectWillChange.send()
            hostUnreachableSince[id] = nil
        }
    }

    /// `nil` = probe failed → keep last-known. Otherwise replace this host's slice and write
    /// names through to `ccNames` so they outlive CC exit. All writes guarded with `!=` so a
    /// steady-state tick doesn't fire `objectWillChange` (which would churn fork.json via the
    /// debounce-save and re-render the whole sidebar every 3s).
    private func mergeCC(hostID: ForkHost.ID, result: [String: CCProbe.Info]?) {
        // `ccPoll == nil` ⇒ toggled off mid-tick — the in-flight task group can still drain
        // a result here after `setCCProbeEnabled(false)` cleared everything.
        guard ccPoll != nil else { return }
        applyProbeResult(hostID: hostID, result: result)
    }

    /// `mergeCC` minus the poll-liveness guard — internal so tests can drive it with
    /// synthetic probe results without starting a real poll loop (the highest-fix-density
    /// code in the fork had zero direct tests). The host-removed-mid-tick guard stays
    /// here: that one is data integrity, not poll lifecycle.
    func applyProbeResult(hostID: ForkHost.ID, result: [String: CCProbe.Info]?) {
        guard host(id: hostID) != nil else { return }
        // Probe failed (unreachable host / timeout / zero sessions) → keep last-known for
        // `ccLive`/`blocked`, but `ccBusy` is a liveness signal with no other clear path —
        // left set it wedges the rail at a permanent `.working` (same hazard as toggle-off).
        guard let result else {
            for ref in Set(tabs.lazy.filter({ $0.hostID == hostID }).flatMap(\.tree.leafRefs)) {
                apply(ref, .probeStopped)
            }
            return
        }
        // Emit `.probe` per *in-tree* ref on this host — `result` may include never-attached
        // sessions (would leak `panes`), and iterating `prev∪result` can't deliver a second
        // `.probeAbsent` because `prev = ccLive` already dropped the key after the first miss.
        // In-tree-but-absent → `.probeAbsent` (machine's 2-strike tells gap from CC-exit).
        // `Set` — dup-attached refs (PR26) would otherwise double-emit and burn both strikes.
        for ref in Set(tabs.lazy.filter({ $0.hostID == hostID }).flatMap(\.tree.leafRefs)) {
            if let info = result[ref.key] {
                apply(ref, .probe(blocked: info.isBlocked, busy: info.status == "busy",
                                  sig: .init(tempo: info.tempo, needs: info.needs)))
            } else { apply(ref, .probeAbsent) }
        }
        if ccLive[hostID] != result { ccLive[hostID] = result }
        ccUpdatedAt[hostID] = result.compactMapValues(\.updatedAt)
        for i in tabs.indices where tabs[i].hostID == hostID {
            let live = Set(tabs[i].tree.leafRefs.map(\.key))
            for (key, info) in result {
                guard let name = info.name, live.contains(key),
                      tabs[i].ccNames[key] != name else { continue }
                tabs[i].ccNames[key] = name
            }
        }
    }

    func setPersistedTree(_ tree: PersistedTree, for tabID: TabModel.ID) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        // No `panes` GC here — ⌘W→⌘Z must preserve `blockSig`/`watched` (same leak-until-
        // tab-close policy as `refs`/`progressSubs`); `removeTab` is the drop point.
        tabs[i].tree = tree
        let live = Set(tree.leafRefs.map(\.key))
        tabs[i].lastActive = tabs[i].lastActive.filter { live.contains($0.key) }
        tabs[i].paneLabels = tabs[i].paneLabels.filter { live.contains($0.key) }
        tabs[i].paneTags = tabs[i].paneTags.filter { live.contains($0.key) }
        tabs[i].ccNames = tabs[i].ccNames.filter { live.contains($0.key) }
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
        let cc = tabs[si].ccNames[key]
        if let label { tabs[di].paneLabels[key] = label }
        if let tag { tabs[di].paneTags[key] = tag }
        if let last { tabs[di].lastActive[key] = last }
        if let cc { tabs[di].ccNames[key] = cc }
        // The pending exit-stamp follows a moved focused pane: src's entry is pruned below,
        // so without the retarget the eventual departure stamp dies on the entry-nil guard
        // and the moved pane reads as old as its arrival time in its new tab.
        if lastTouched.map({ $0 == (src, key) }) ?? false { lastTouched = (dst, key) }
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
        .init(hosts: hosts, tabs: tabs, activeTabID: activeTabID, recentTags: recentTags,
              hoverCommands: hoverCommands)
    }

    static func autoName(base: String = "shell", suffixLen: Int = 3) -> String {
        let alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
        let suffix = String((0..<suffixLen).map { _ in alphabet.randomElement()! })
        return "\(base)-\(suffix)"
    }

    // MARK: Test support

    /// Full state reset for the test suite — the shared singleton leaks state across test
    /// cases otherwise: `refs` and the pending exit-stamp have no public clearing path, and
    /// `ccLive`/`ccSeenDetail` for the local host survive `removeHost`'s local-host guard.
    /// Never called from production code (live surfaces bound in `refs` would be orphaned).
    func resetForTesting() {
        for h in hosts where h.id != ForkHost.local.id { removeHost(h.id) }
        for t in tabs { removeTab(t.id) }
        if let i = hosts.firstIndex(where: { $0.id == ForkHost.local.id }) {
            hosts[i].label = ForkHost.local.label
            hosts[i].expanded = true
        }
        ccPoll?.cancel(); ccPoll = nil
        activeTabID = nil
        focusedPaneIndex = nil
        renaming = nil
        recentTags = []
        panes = [:]
        ccLive = [:]
        ccUpdatedAt = [:]
        ccSeenDetail = [:]
        hostUnreachableSince = [:]
        refs = [:]
        lastTouched = nil
        tabHistory = []
        tabHistoryCursor = -1
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
