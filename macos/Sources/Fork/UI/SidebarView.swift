#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import GhosttyKit

/// Left sidebar: hosts as collapsible sections, tabs as rows (SPEC §9).
struct SidebarView: View {
    weak var controller: ForkWindowController?
    @EnvironmentObject private var registry: SessionRegistry
    @State private var renameText: String = ""
    @State private var draggingTab: TabModel.ID?
    @State private var draggingHost: ForkHost.ID?
    @FocusState private var renameFieldFocused: Bool
    @AppStorage(SessionRegistry.kFilterTagged) private var filterTagged = false
    @AppStorage(SessionRegistry.kFocusMode) private var focusMode = false
    @AppStorage(SessionRegistry.kFocusCutoffHours) private var cutoffHours = 16.0
    @AppStorage(SessionRegistry.kFocusSortMRU) private var sortMRU = true
    @State private var showCutoffPopover = false
    @AppStorage("forkSidebarShowCC") private var showCC = false
    /// One density now (the old compact/details toggle is gone — read/unread status text
    /// self-regulates row height instead): solo ⌥-hold ≥0.5s arms `revealAll` (re-expand
    /// every read status line, fleet-wide glance); ⌥⌥ — two clean taps, committed on the
    /// second release — sweeps everything read.
    /// Own monitor (not `navMonitor`) so this stays @State and doesn't churn the registry's
    /// `objectWillChange` → debounce-save on every modifier tap.
    @State private var optionHeld = false
    @State private var lastOptionPress: Date?
    @State private var flagsMonitor: Any?
    /// Armed only by a *solo* hold — the 0.5s delay plus the key/mouse disqualifier keep
    /// readline Meta chords (⌥b/⌥f) and ⌥-clicks from flashing the sidebar open mid-typing.
    @State private var revealAll = false
    @State private var revealArm: Timer?
    /// Second ⌥ tap landed inside the 0.4s window — the sweep fires when it's released
    /// cleanly (no hold, no chord), so "tap, then hold to peek" never reads as ⌥⌥.
    @State private var sweepOnRelease = false

    private var fontFamily: String? { controller?.ghostty.config.forkFontFamily }
    private func mono(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { forkMono(s, w, fontFamily) }

    private var recentTags: ArraySlice<PaneTag> { registry.recentTags.prefix(5) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 8)
            ScrollView {
                // Eager VStack: lazy materialisation made the overlay scroller jump
                // because each `hostSection` is variable-height and the content-size
                // estimate corrected on every scroll. Sidebar row counts are small
                // enough that rendering all of them is cheaper than the instability.
                VStack(alignment: .leading, spacing: 4) {
                    if focusMode {
                        focusSection
                    } else {
                        ForEach(registry.hosts) { host in
                            hostSection(host)
                        }
                    }
                }
                .padding(.vertical, 8)
                .background(OverlayScroller())
            }
        }
        .background(.ultraThinMaterial)
        .task { registry.setCCProbeEnabled(showCC) }
        .onChange(of: showCC) { registry.setCCProbeEnabled($0) }
        .onAppear {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
            ) { ev in
                handleOptionEvent(ev)
            }
        }
        .onDisappear {
            flagsMonitor.map(NSEvent.removeMonitor); flagsMonitor = nil
            disarmOptionGesture(); optionHeld = false; lastOptionPress = nil
            // Stop the singleton's 3s ccPoll loop — `setCCProbeEnabled` cancels the
            // detached `Task`, which `.task`'s own auto-cancel can't (one-shot body
            // returns immediately). Otherwise leaks past last-window close
            // (`shouldQuitAfterLastWindowClosed` defaults false, AppDelegate.swift:1035).
            // Last-window only: the registry is shared, and a sibling window's sidebar has
            // no re-enable path short of the user toggling showCC off and on.
            if !ForkWindowController.anyOtherForkWindow(besides: controller?.window) {
                registry.setCCProbeEnabled(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification)) { _ in
                optionHeld = false
                disarmOptionGesture()
            }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didResignKeyNotification)) { note in
                // An ⌥ release delivered to a sheet / QuickTerminal / another window never
                // reaches `handleOptionEvent` (window guard) — losing key is the disarm.
                guard (note.object as? NSWindow) === controller?.window else { return }
                optionHeld = false
                disarmOptionGesture()
            }
    }

    /// ⌥ recognizer: a solo ⌥ held 0.5s → `revealAll`; ⌥⌥ (two clean taps within 0.4s) →
    /// quiet sweep (`markAllCCRead`), committed on the second *release* so a tap followed
    /// by a hold reads as a retry of the peek, not a sweep. Any key or mouse event while
    /// ⌥ is down is a chord (readline ⌥b/⌥f, accented input, ⌘⌥N, ⌥-click/⌥-drag in the
    /// terminal), not a tap or a peek — it disqualifies the in-flight press for both.
    private func handleOptionEvent(_ ev: NSEvent) -> NSEvent? {
        // Local monitors are app-wide; QuickTerminal bypasses the fork seam, so ⌥⌥ in its
        // window would otherwise sweep our read-state.
        guard ev.window === controller?.window else { return ev }
        if ev.type != .flagsChanged {
            if ev.modifierFlags.contains(.option) {
                lastOptionPress = nil
                disarmOptionGesture()
            }
            return ev
        }
        let flags = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let held = flags.contains(.option)
        // "Solo" = no chord modifiers — ⌘⌥1-9 host jumps and other ⌘/⇧/⌃ chords must
        // neither count as taps nor flash the reveal. Caps Lock / fn are not chords and
        // must not kill the gesture.
        let solo = held && flags.isDisjoint(with: [.command, .shift, .control])
        if solo, !optionHeld {
            let now = Date()
            // A second press inside the 0.4s window is a *candidate* sweep — committed on
            // release, so it can still turn into a hold (peek) or be disqualified.
            sweepOnRelease = lastOptionPress.map { now.timeIntervalSince($0) < 0.4 } ?? false
            lastOptionPress = now
            // Solo-hold reveal arms after a beat (the cheatsheet's ⌘-hold idiom); instant
            // would still flash open in the gap before a chord's keyDown lands. Re-check
            // the hardware state at fire time — a release swallowed by a tracking loop or
            // delivered to another window must not latch it on.
            revealArm = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                if NSEvent.modifierFlags.contains(.option) { revealAll = true }
            }
        }
        if held, !solo, optionHeld {
            // A chord modifier joined an already-held ⌥ (⌥ first, then ⌘ for ⌘⌥N): that's a
            // chord in progress, not a peek — disarm the pending/active reveal and abandon
            // the half-completed tap so a slow chord can't flash the sidebar open.
            lastOptionPress = nil
            disarmOptionGesture()
        }
        if !held {
            // Tap-tap commits here — unless the press became a hold (the peek fired: you
            // were retrying the glance, not asking to sweep) or was disqualified above.
            let commitSweep = sweepOnRelease && !revealAll
            disarmOptionGesture()
            if commitSweep {
                registry.markAllCCRead()
                lastOptionPress = nil   // a third tap shouldn't chain into another sweep
            }
        }
        if held != optionHeld { optionHeld = held }
        return ev
    }

    /// Cancel a pending solo-hold reveal, drop an active one, and abandon a half-completed ⌥⌥.
    private func disarmOptionGesture() {
        revealArm?.invalidate(); revealArm = nil
        sweepOnRelease = false
        if revealAll { revealAll = false }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            iconButton("plus", help: "New tab") { controller?.showNewSessionSheet() }
            iconButton("server.rack", help: "Hosts") { controller?.showHostsSheet() }
            iconButton("sidebar.left", help: "Hide sidebar") { controller?.toggleSidebar() }
            iconButton(filterTagged ? "tag.fill" : "tag",
                       help: filterTagged ? "Show all" : "Tagged only",
                       tint: filterTagged ? Theme.clay : nil) {
                withAnimation(.snappy(duration: 0.12)) { filterTagged.toggle() }
            }
            // Not `iconButton` — macOS `Button` swallows mouseDown so `.onLongPressGesture`
            // on it never fires. Plain Image + tap/long-press composes exclusively.
            Image(systemName: "scope").font(.system(size: 13))
                .foregroundStyle(focusMode ? Theme.clay : .secondary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.snappy(duration: 0.12)) { focusMode.toggle() }
                }
                .onLongPressGesture(minimumDuration: 0.4) { showCutoffPopover = true }
                .popover(isPresented: $showCutoffPopover, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Show tabs from last \(Int(cutoffHours))h — older panes dim").font(.caption)
                        Slider(value: $cutoffHours, in: 1...64, step: 1).frame(width: 180)
                        Toggle("Sort by most recent", isOn: $sortMRU)
                            .font(.caption).toggleStyle(.checkbox)
                    }.padding(12)
                }
                .help(focusMode ? "All hosts"
                                : "Focus (last \(Int(cutoffHours))h) — long-press to adjust")
                .modifier(HoverHighlight())
            iconButton("sparkle",
                       help: showCC ? "Hide Claude session names" : "Show Claude session names",
                       tint: showCC ? Theme.clay : nil) {
                withAnimation(.snappy(duration: 0.12)) { showCC.toggle() }
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func iconButton(_ icon: String, help: String, tint: Color? = nil,
                            perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: icon).font(.system(size: 13))
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverHighlight())
        .help(help)
    }

    // MARK: Focus section — flat MRU-first list across all hosts.
    // `filterTagged` composes: off → last-16h; on → tagged-only, no time cutoff.

    private var focusTabs: [TabModel] { registry.focusTabs(taggedOnly: filterTagged) }

    private var focusSection: some View {
        let tabs = focusTabs
        // Own VStack so `.animation(value:)` sees the row positions it lays out;
        // attaching to the outer body VStack would also animate host-mode reflow.
        return VStack(alignment: .leading, spacing: 4) {
            if tabs.isEmpty {
                Label(filterTagged ? "No tagged panes" : "Nothing in the last \(Int(cutoffHours))h",
                      systemImage: filterTagged ? "tag.slash" : "moon.zzz")
                    .font(mono(12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.top, 12)
            } else {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { i, tab in
                    VStack(alignment: .leading, spacing: 3) {
                        // ⌘N + host on its own row above the tab — frees the ~56pt leading
                        // column that was truncating pane titles. This caption is also the
                        // tab-level right-click target — a default-titled single-pane tab
                        // has no `tabHeading` to carry the menu.
                        let host = registry.host(id: tab.hostID)
                        // ⌘N left, dot+host right — caption recedes behind the heading.
                        HStack(spacing: 6) {
                            // No empty pill on rows 10+ — the Spacer handles alignment.
                            if i < 9 { keyHint("⌘\(i + 1)") }
                            if tab.pinned { pinBadge(size: 8) }
                            Spacer()
                            HostDot(host: host, size: 7)
                            Text(host?.label ?? "—")
                                .font(mono(10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                        .contextMenu { tabContextMenu(tab) }
                        tabRow(tab)
                    }
                    .modifier(ForkCard())
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: tabs.map(\.id))
    }

    private func tagButton(_ t: PaneTag, tab: TabModel.ID, ref: String,
                           prefix: String = "") -> some View {
        Button { registry.setPaneTag(tab: tab, name: ref, to: t) } label: {
            Label(prefix + t.text, systemImage: "circle.fill").foregroundStyle(Theme.tag(t.hue))
        }
    }

    /// Worst-child rollup for collapsed headers — compact dot/spinner; the per-row indicator
    /// is `StatusRail` (right-edge anchored, doesn't fit inline here).
    @ViewBuilder
    private func stateDot(_ s: PaneState?, accent: Color) -> some View {
        switch s {
        case .blocked: Circle().fill(Theme.blocked).frame(width: 6, height: 6).help(PaneState.blocked.help)
        case .waiting: Circle().fill(accent).frame(width: 6, height: 6).help(PaneState.waiting.help)
        case .working: ProgressView().controlSize(.mini).scaleEffect(0.6)
        case nil: EmptyView()
        }
    }

    private func keyHint(_ chord: String) -> some View {
        Text(chord)
            .font(mono(9, .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Theme.chipBg, in: RoundedRectangle(cornerRadius: 3))
    }

    // MARK: Host section

    @ViewBuilder
    private func hostSection(_ host: ForkHost) -> some View {
        let allTabs = registry.tabs(on: host.id)
        let tabs = filterTagged ? allTabs.filter(\.hasTag) : allTabs
        // Filter-on + no tagged tabs on this host → hide the whole section so the
        // sidebar isn't cluttered with empty host cards.
        if !(filterTagged && tabs.isEmpty) {
            hostHeader(host, tabs: tabs)
            if host.expanded && !tabs.isEmpty {
                hostBody(tabs: tabs)
            }
        }
    }

    private func hostHeader(_ host: ForkHost, tabs: [TabModel]) -> some View {
        let connected = registry.isConnected(host.id)
        return Button {
            withAnimation(.snappy(duration: 0.15)) { registry.setExpanded(host.id, !host.expanded) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(host.expanded ? 90 : 0))
                    .frame(width: 10)
                HostDot(host: host, size: 10)
                    .opacity(connected ? 1 : 0.3)
                    .frame(width: 14)
                Text(host.label)
                    .font(mono(13, .medium))
                    .foregroundStyle(connected ? .primary : .secondary)
                if let since = registry.hostUnreachableSince[host.id] {
                    // Transport-level cue (zmx list failing), distinct from the dot's
                    // "no live surface" dimming — without it, hours-old CC status on a
                    // dead ssh host reads as live.
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .help("Unreachable since \(since.formatted(date: .omitted, time: .shortened)) — CC status may be stale")
                }
                Spacer()
                if !host.expanded {
                    stateDot(controller?.rollup(hostID: host.id), accent: host.accent)
                        .padding(.trailing, 6)
                }
                if let i = registry.hosts.firstIndex(where: { $0.id == host.id }), i < 9 {
                    keyHint("⌘⌥\(i + 1)")
                }
                Text("\(tabs.count)").font(mono(11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverHighlight())
        .padding(.horizontal, 8)
        .onDrag {
            draggingTab = nil; draggingHost = host.id
            return NSItemProvider(object: host.id as NSString)
        }
        .onDrop(of: [.text], delegate: ReorderDelegate(
            target: host.id, dragging: $draggingHost, move: registry.moveHost))
        .contextMenu {
            Button("New Session on \(host.label)…") {
                controller?.showSessionPicker(on: host)
            }
            Button("Manage Host…") { controller?.showHostsSheet(select: host.id) }
            if host.id != ForkHost.local.id {
                Divider()
                Button("Remove Host", role: .destructive) {
                    controller?.removeHost(host.id)
                }
            }
        }
    }

    private func hostBody(tabs: [TabModel]) -> some View {
        // Normal mode is positional — the row's visual index *is* the ⌘N index — so per-tab
        // digit hints are dropped here; ⌘⌥N on the host header is the non-obvious one.
        VStack(alignment: .leading, spacing: 2) {
            ForEach(tabs) { tab in tabRow(tab) }
        }
        .modifier(ForkCard(fill: Theme.hostCardBg, hPad: 8))
        .transition(.opacity)
    }

    // MARK: Tab → pane rows
    // Each row's label is `paneLabels[ref.key]` (persisted, ⌘I) › `surface.title` (OSC, live)
    // › `ref.name`, with `ref.name` as subtitle when the label differs. `tab.title` is a heading
    // above the group, shown only when it diverges from the first session name (⌘⇧I edits it).
    // Cold-restored tabs have no live surfaces until first activated.

    private func tabRow(_ tab: TabModel) -> some View {
        let active = tab.id == registry.activeTabID
        let allRefs = tab.tree.leafRefs
        let surfaces = controller?.surfaces(for: tab.id) ?? []
        let renaming = registry.renaming == .tab(tab.id)
        let heading = renaming || tab.collapsed || tab.title != allRefs.first?.name
        return VStack(alignment: .leading, spacing: 0) {
            if heading {
                tabHeading(tab, renaming: renaming, active: active, paneCount: allRefs.count)
            }
            if !tab.collapsed {
                ForEach(Array(allRefs.enumerated()), id: \.0) { i, ref in
                    // Index-match: `surfaces` may be one ahead of `allRefs` for ≤80ms after a
                    // split (debounced persistActive) — accepted; matching by ref instead
                    // would mis-pair duplicate-ref tabs (PR26) permanently.
                    paneRow(tab, index: i, ref: ref,
                            surface: i < surfaces.count ? surfaces[i] : nil,
                            spine: allRefs.count > 1 ? (i == 0, i == allRefs.count - 1) : nil,
                            active: active)
                }
            }
        }
        .onDrag {
            draggingHost = nil; draggingTab = tab.id
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: ReorderDelegate(
            target: tab.id, dragging: $draggingTab, move: registry.moveTab))
    }

    private func tabHeading(_ tab: TabModel, renaming: Bool, active: Bool,
                            paneCount: Int) -> some View {
        let accent = Theme.hostAccent(registry.host(id: tab.hostID))
        let toggle = {
            withAnimation(.snappy(duration: 0.15)) {
                registry.setCollapsed(tab.id, !tab.collapsed)
            }
        }
        return HStack(spacing: 0) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(tab.collapsed ? 0 : 90))
                    .frame(width: 14, height: 20, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if renaming {
                renameField(seed: tab.title, font: mono(11, .semibold))
            } else {
                Text(tab.title.uppercased())
                    .font(mono(10, .semibold)).kerning(0.6).lineLimit(1)
                    .foregroundStyle(accent.opacity(active ? 1 : 0.6))
            }
            Spacer()
            if tab.collapsed {
                stateDot(controller?.rollup(tab: tab), accent: accent)
                    .padding(.trailing, 6)
                Text("\(paneCount)").font(mono(10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4).padding(.trailing, 12).frame(height: 20)
        .contentShape(Rectangle())
        .onTapGesture {
            if tab.collapsed { toggle() }
            controller?.activate(tab: tab.id)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename(tab) })
        .contextMenu { tabContextMenu(tab) }
    }

    /// Tab-scoped actions. Attached to `tabHeading` AND the focus-mode caption row — most
    /// single-pane tabs have no heading (`title == first ref name`), so without the caption
    /// attachment they'd have no tab-level right-click target at all.
    @ViewBuilder
    private func tabContextMenu(_ tab: TabModel) -> some View {
        Button("Rename Tab…") { beginRename(tab) }
        Button((tab.pinned ? "Unpin Tab" : "Pin Tab") + " (⌘⌥P)") {
            registry.setPinned(tab.id, !tab.pinned)
        }
        if focusMode {
            Button("Hide from Focus") { registry.dismissFromFocus(tab.id) }
        }
        mergeIntoMenu(tab)
        Divider()
        Button("Close Tab") { controller?.closeForkTab(tab.id) }
        Button("Kill All & Close Tab…", role: .destructive) { controller?.confirmKill(tab) }
    }

    /// "Move Pane to ▸" — move a single pane to a new tab or another same-host tab.
    /// Hidden for external (`@`-keyed) refs per v1 scope (see Fork/CLAUDE.md §Gotchas).
    @ViewBuilder
    private func movePaneMenu(_ tab: TabModel, ref: SessionRef) -> some View {
        if !ref.external {
            let targets = registry.tabs(on: tab.hostID).filter { $0.id != tab.id }
            Menu("Move Pane to…") {
                Button("New Tab") { controller?.movePane(from: tab.id, ref: ref, to: nil) }
                if !targets.isEmpty {
                    Divider()
                    ForEach(targets) { dst in
                        Button(dst.title.isEmpty ? "(untitled)" : dst.title) {
                            controller?.movePane(from: tab.id, ref: ref, to: dst.id)
                        }
                    }
                }
            }
        }
    }

    /// "Merge Into ▸" — fold all of `tab`'s panes into another tab on the same host.
    /// Hidden when no valid destination exists.
    @ViewBuilder
    private func mergeIntoMenu(_ tab: TabModel) -> some View {
        let targets = registry.tabs(on: tab.hostID).filter { $0.id != tab.id }
        // mergeTab skips externals; an external-only src would be a dead menu item.
        if !targets.isEmpty, tab.tree.leafRefs.contains(where: { !$0.external }) {
            Menu("Merge Into…") {
                ForEach(targets) { dst in
                    Button(dst.title.isEmpty ? "(untitled)" : dst.title) {
                        controller?.mergeTab(from: tab.id, into: dst.id)
                    }
                }
            }
        }
    }

    private func paneRow(_ tab: TabModel, index: Int, ref: SessionRef,
                         surface: Ghostty.SurfaceView?,
                         spine: (first: Bool, last: Bool)?, active: Bool) -> some View {
        let focused = active && (registry.focusedPaneIndex.map { $0 == index } ?? (index == 0))
        let userLabel = tab.paneLabels[ref.key]
        let tag = tab.paneTags[ref.key]
        let renaming = registry.renaming == .pane(tab.id, name: ref.key)
        let live = showCC ? registry.ccLive[tab.hostID]?[ref.key] : nil
        let accent = Theme.hostAccent(registry.host(id: tab.hostID))
        let dot = registry.dot(ref: ref)
        // Rail-tooltip + red-subtitle text: "what is it waiting for" is the triage answer
        // for a blocked pane. Scoped to .blocked — a stale `needs` on a working pane reads
        // as a false alarm. Shared with `ccLine` so the two can't derive differently.
        let blockedDetail = dot == .blocked ? live?.attention : nil
        // Recency lives in three carriers, not a column: afterglow on the row background
        // (the short-term "where was I just now" trail — user focus only, or every agent
        // turn fleet-wide would keep half the sidebar lit), doze opacity (the long tail —
        // also counts CC activity while the probe is on, so a pane an agent grinds on
        // overnight doesn't render dusty), and an exact-age line in the hover peek that
        // names its source ("CC turned" vs "you were here" — they can differ by hours on
        // the same row). `ccStamp`/`lastSeen` stay closures: `ccUpdatedAt` is a
        // non-@Published mirror (`Info.==` excludes `updatedAt`, so heartbeat-only ticks
        // don't publish) and must be re-read inside the row's clock.
        let ccStamp = { showCC ? registry.ccUpdatedAt[tab.hostID]?[ref.key] : nil }
        let lastSeen = { [tab.lastActive[ref.key], ccStamp()].compactMap { $0 }.max() }
        // Read/unread for the activity text: the focused pane's status is in front of you,
        // and text unchanged since you last left a pane is already read — both demote to a
        // dim one-liner (never fully hidden: a vanished line is indistinguishable from "CC
        // has nothing to say", and the last summary often carries paths/PR numbers you still
        // need). New text after you've moved away renders bright and multi-line, so the
        // sidebar reads as unread activity, not a transcript. ⌥-hold (`revealAll`) and the
        // row hover peek recover the full text; the blocked question is not gated here —
        // it has its own ack (`.viewed` in PaneMachine).
        let detail = live?.detail
        let caughtUp = focused
            || (detail != nil && detail == registry.ccSeenDetail[tab.hostID]?[ref.key])
        let unread = detail != nil && !caughtUp
        let read = detail != nil && caughtUp
        // tick: glow decay, doze, and the peek age all derive from wall-clock age — without
        // a clock, a row nothing else re-renders (showCC off, no focus changes) would hold
        // a stale glow indefinitely.
        return Hovering(tick: 60) { hovered in
            HStack(spacing: 0) {
                Group {
                    if let spine {
                        // Hovering's 60s tick is the clock here too (spineHeat buckets at
                        // 5m/1h, so minute granularity is plenty).
                        Spine(first: spine.first, last: spine.last)
                            .stroke(active ? Theme.spineHeat(tab.lastActive.values.max())
                                           : Theme.spineHeat(nil), lineWidth: 1)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    if renaming {
                        renameField(seed: userLabel ?? ref.name, font: mono(13))
                    } else if let surface {
                        PaneLabel(surface: surface, userLabel: userLabel, fallback: ref.name,
                                  active: active, suppressSubtitle: showCC, fontFamily: fontFamily)
                    } else {
                        Text(userLabel ?? ref.name).font(mono(13)).lineLimit(1)
                            .foregroundStyle(active ? .primary : .secondary)
                    }
                    if showCC {
                        // Replaces PaneLabel's zmx-name subtitle (suppressed via `showCC`
                        // above). Min-height (not fixed) slot: empty `ccLine`s still reserve
                        // a line so focus-mode reorder doesn't gap rows, but a row with
                        // unread CC status text may grow to 3 subtitle lines (4 total — the
                        // wrap cap lives in `ccLine`).
                        // `cached` only for placeholder rows (no surface yet) — on a hydrated
                        // pane where CC has exited it'd show the dead session's name as stale.
                        ccLine(live: live,
                               cached: surface == nil ? tab.ccNames[ref.key] : nil,
                               fallback: ref.name,
                               attention: blockedDetail,
                               read: read)
                            .frame(minHeight: 13, alignment: .topLeading)
                    }
                }
                Spacer()
                if registry.panes[ref]?.watched == true {
                    Image(systemName: "eye")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                        .help("Watching — ⌘⌥A to disarm")
                }
                if let tag {
                    let c = Theme.tag(tag.hue)
                    let pebble = Pebble(tagHue: tag.hue)
                    HStack(spacing: 4) {
                        pebble.strokeBorder(c, lineWidth: 1.5)
                            .background(pebble.fill(hovered ? c : .clear))
                            .frame(width: 8, height: 8)
                        if hovered {
                            Text(tag.text).font(mono(9, .medium))
                                .foregroundStyle(c).fixedSize()
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                    }
                    .padding(.horizontal, hovered ? 5 : 0).padding(.vertical, hovered ? 2 : 0)
                    .background(hovered ? c.opacity(0.12) : .clear, in: Capsule())
                    .rotationEffect(.degrees(hovered ? -2.5 : 0)) // sticker tilt
                    .animation(.snappy(duration: 0.15), value: hovered)
                    .help(tag.text)
                    .padding(.trailing, 6)
                }
            }
            // Long-tail recency: untouched-for-an-hour rests, past the focus cutoff sleeps.
            // Content only — selection/glow backgrounds and the StatusRail overlay keep full
            // strength. Never dozed: the active tab (literally on screen), hovered rows
            // (hover means you're trying to read it), blocked rows (a pane asking for you
            // must not be the faintest row in the sidebar), and rows with unread status text
            // (doze keys on *your* visits, so it would dim hardest exactly the catch-up
            // content the unread model exists to surface). The ⌥ reveal deliberately does
            // NOT lift doze or brighten read text — it only un-clamps the line count, so
            // holding ⌥ reads as "more of the same sidebar", not a different one.
            .opacity(active || hovered || dot == .blocked || unread
                     ? 1
                     : Theme.doze(lastSeen(),
                                  cutoff: SessionRegistry.focusCutoffSeconds(hours: cutoffHours)))
            .padding(.trailing, 12).frame(minHeight: 28)
            .background(
                focused ? Theme.selectedRow : hovered ? Theme.hover : .clear,
                in: RoundedRectangle(cornerRadius: 5))
            // Separate layer so hover/selection ADD to a fresh row's glow instead of
            // swapping it for a weaker gray wash.
            .background(Theme.afterglow(tab.lastActive[ref.key]),
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .trailing) {
                // Anchored to the row (not the content flow) so it reads as a right border,
                // not a pill competing with the tag circle for the same slot.
                StatusRail(state: dot, accent: accent, blockedDetail: blockedDetail)
            }
            .contentShape(Rectangle())
            // Hover peek — the untruncated version of everything the one-line subtitle
            // elides (state, the full detail/question, cwd) as a multi-line tooltip on the
            // whole row. A tooltip rather than a popover/ⓘ button: no extra chrome, can't
            // steal key status from the terminal, and can't fight the row's hover tracking.
            // Child `.help`s (rail, tag pill) still win over their own rects.
            .help([
                live.map { [$0.name, dot?.help ?? $0.status].compactMap { $0 }.joined(separator: " — ") },
                live.flatMap { dot == .blocked ? $0.attention : $0.detail },
                live?.cwd,
                ccStamp().map { "CC turned \($0.shortAge) ago" }
                    ?? (focused ? nil : tab.lastActive[ref.key]).map { "you were here \($0.shortAge) ago" },
            ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        .onTapGesture { controller?.activate(tab: tab.id, paneIndex: index) }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            registry.setRenaming(.pane(tab.id, name: ref.key))
        })
        .contextMenu { paneContextMenu(tab, ref: ref, tag: tag) }
        .popover(isPresented: Binding(
            get: { registry.taggingPane.map { $0 == (tab.id, ref.key) } ?? false },
            // Only clear shared state if it still points at *this* row — opening B's popover
            // (context-menu "New Tag…") flips A's getter false, and A's NSPopover-dismiss
            // callback would otherwise race B's open by nilling `taggingPane` from under it.
            set: { if !$0, registry.taggingPane.map({ $0 == (tab.id, ref.key) }) ?? false {
                registry.taggingPane = nil
            } }
        ), arrowEdge: .trailing) {
            TagEditView(seed: tag) {
                registry.setPaneTag(tab: tab.id, name: ref.key, to: $0)
                registry.taggingPane = nil
            }
        }
    }

    @ViewBuilder
    /// Pane-scoped actions only — tab-scoped actions live on the tab heading menu.
    private func paneContextMenu(_ tab: TabModel, ref: SessionRef, tag: PaneTag?) -> some View {
        Group {
            Button("Rename Pane…") { registry.setRenaming(.pane(tab.id, name: ref.key)) }
            // Top-3 recent tags inline (one click); the rest stay under the submenu.
            ForEach(recentTags.prefix(3), id: \.self) { tagButton($0, tab: tab.id, ref: ref.key, prefix: "Tag: ") }
            Menu("Tag") {
                ForEach(recentTags.dropFirst(3), id: \.self) { tagButton($0, tab: tab.id, ref: ref.key) }
                if recentTags.count > 3 { Divider() }
                Button("New Tag…") { registry.taggingPane = (tab.id, ref.key) }
                if tag != nil {
                    Button("Clear Tag") { registry.setPaneTag(tab: tab.id, name: ref.key, to: nil) }
                }
            }
            if registry.ccLive[ref.hostID]?[ref.key]?.sock != nil {
                Button("Set CC Name to '\(tab.paneLabels[ref.key] ?? ref.name)'") {
                    controller?.syncCCName(tab: tab, ref: ref)
                }
            }
            movePaneMenu(tab, ref: ref)
        }
    }

    /// Pinned-tab badge — tilted like an actual push-pin.
    private func pinBadge(size: CGFloat) -> some View {
        Image(systemName: "pin.fill")
            .font(.system(size: size)).foregroundStyle(.secondary)
            .rotationEffect(.degrees(-18))
    }

    /// CC subtitle — status lives in the right-edge rail; recency is the row's afterglow /
    /// doze and the hover peek's age line.
    /// Blocked: the question CC is asking, in bright `.primary` (the red lives in the
    /// rail). Otherwise `name · detail` is a live
    /// activity feed (what the session is, what it's doing / last did), falling back to
    /// cwd basename, then the cached last-seen name for placeholder rows. Unread text is
    /// secondary and wraps to 3 lines so the activity is readable in place; `read` text
    /// (focused pane, or nothing new since the user last left it — see `ccSeenDetail`)
    /// demotes to one tertiary line: still a scent trail of what the session last said,
    /// but visually "done". CC session names render a half-step heavier (.medium) than the
    /// status text — without it the name reads as a second pane title one row down. The
    /// question (`attention`) is never demoted here — it has its own ack. Always returns a
    /// `Text` (empty when no label) so the call-site `.frame(minHeight:)` actually reserves
    /// the slot; `EmptyView().frame(...)` is a layout no-op.
    private func ccLine(live: CCProbe.Info?, cached: String?, fallback: String,
                        attention: String?, read: Bool) -> some View {
        // cwd basename is only useful when more specific than the pane's own name — an
        // unnamed CC at a shared repo root would read identically on every row.
        let cwdLeaf = live?.cwd
            .map { ($0 as NSString).lastPathComponent }
            .flatMap { $0 == fallback ? nil : $0 }
        // The agent identity reads as small caps — a typographic role change (label-like)
        // rather than a third color: uppercased at a smaller size with a touch of tracking,
        // because terminal mono families rarely carry a real smcp feature for
        // `Font.smallCaps()` to use. Color stays with the line (secondary unread / tertiary
        // read or cached) so "dim = read" remains one rule.
        func name(_ n: String) -> Text {
            Text(n.uppercased()).font(mono(10, .medium)).kerning(0.5)
        }
        // `cached` is for the CC-exited case only; a running-but-unnamed session must not
        // fall through to the previous session's name in `.secondary` (live) styling.
        let label: Text
        if let attention {
            label = Text(attention)
        } else if let live {
            switch (live.name, live.detail) {
            case let (n?, d?): label = name(n) + Text(" · \(d)")
            case let (n?, nil): label = name(n)
            case let (nil, d?): label = Text(d)
            case (nil, nil): label = Text(cwdLeaf ?? "")
            }
        } else {
            label = cached.map(name) ?? Text("")
        }
        // The question renders bright, not red: with several agents blocked at once a
        // 3-line red paragraph per row reads as a wall of alarm. Red stays on the
        // StatusRail bar; the question earns attention by being the only `.primary`
        // subtitle text in the sidebar.
        let style: AnyShapeStyle = attention != nil ? AnyShapeStyle(.primary)
            : (read || live == nil) ? AnyShapeStyle(.tertiary)
            : AnyShapeStyle(.secondary)
        return label
            // `attention == nil`: the read-state belongs to the detail text only — a blocked
            // question must keep its 3 lines even when the unrelated detail counts as read
            // (⌥⌥ sweep, unchanged-detail exit-stamp, question arriving while focused).
            // `live == nil`: a cached placeholder name stays one line, keeping cold-restored
            // rows as uniform as the old fixed-height slot did.
            // `!revealAll`: ⌥-hold lifts only this clamp — tertiary color and doze stay, so
            // the peek expands the text without re-skinning the sidebar.
            .font(mono(11)).lineLimit(((read && !revealAll) || live == nil) && attention == nil ? 1 : 3)
            // vertical: true — claim the wrapped height even when the layout pass proposes
            // a tight one (otherwise the text can collapse back to one ellipsized line);
            // horizontal stays flexible so it still wraps to the sidebar width.
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(style)
        // Truncation past the cap is recoverable via the row-level hover peek (paneRow's
        // `.help`), which supersets this line — no per-Text tooltip here so the two can't
        // disagree.
    }

    // MARK: -

    private func beginRename(_ tab: TabModel) {
        registry.setRenaming(.tab(tab.id))
    }

    private func renameField(seed: String, font: Font) -> some View {
        TextField("", text: $renameText, onCommit: commitRename)
            .textFieldStyle(.plain).font(font)
            .focused($renameFieldFocused)
            .onExitCommand { registry.setRenaming(nil) }
            .onAppear {
                renameText = seed
                // @FocusState can't steal firstResponder from SurfaceView unprompted —
                // resign it explicitly after the field mounts (InspectorView.swift:47 idiom).
                DispatchQueue.main.async {
                    _ = controller?.focusedSurface?.resignFirstResponder()
                    renameFieldFocused = true
                }
            }
            .onChange(of: renameFieldFocused) { focused in
                // Nil-targeted selectAll would route to SurfaceView (CLAUDE.md "Sheet ⌘V").
                guard focused, NSApp.keyWindow?.firstResponder is NSTextView else { return }
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
    }


    private func commitRename() {
        switch registry.renaming {
        case .tab(let id):
            // Empty ⇢ reset to first session name → heading condition becomes false → row hides.
            let fallback = registry.tabs.first { $0.id == id }?.tree.leafRefs.first?.name
            if let title = renameText.isEmpty ? fallback : renameText {
                registry.renameTab(id, to: title)
            }
        case .pane(let id, let name):
            registry.setPaneLabel(tab: id, name: name, to: renameText.isEmpty ? nil : renameText)
        case nil: break
        }
        registry.setRenaming(nil)
    }
}

/// `surface.title` is `@Published`; observing it here means only the label re-renders
/// when the shell sends OSC 0/2 — not the whole sidebar.
private struct PaneLabel: View {
    @ObservedObject var surface: Ghostty.SurfaceView
    let userLabel: String?
    let fallback: String
    let active: Bool
    let suppressSubtitle: Bool
    let fontFamily: String?
    var body: some View {
        // Upstream's `titleFallbackTimer` sets `"👻"` after 500ms if no OSC title arrived
        // (SurfaceView_AppKit.swift:323) — treat it as "no title" so the session name shows.
        // A path-shaped title (OMZ-style `%n@%m:%~`, `$PWD`, `~/…`) also counts as no-title:
        // the user wants the zmx session id, not whatever the shell reports as cwd.
        let t = surface.title
        let isPathish = t.hasPrefix("/") || t.hasPrefix("~") || t.contains(":/") || t.contains(":~")
        let label = userLabel ?? (t.isEmpty || t == "👻" || isPathish ? fallback : t)
        return VStack(alignment: .leading, spacing: 0) {
            Text(label).font(forkMono(13, .regular, fontFamily)).lineLimit(1)
                .foregroundStyle(active ? .primary : .secondary)
            if !suppressSubtitle && label != fallback {
                Text(fallback).font(forkMono(10, .regular, fontFamily)).lineLimit(1)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Force the enclosing `NSScrollView` to overlay (slim, auto-fading) scrollers even when
/// the system preference is "Always". The legacy 15pt gutter eats ~8% of a 200pt sidebar.
/// AppKit resets `scrollerStyle` on `preferredScrollerStyleDidChange` (mouse hot-plug),
/// hence the observer. Registration leaks for app lifetime — sidebar is a singleton.
private struct OverlayScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in
            v?.enclosingScrollView?.scrollerStyle = .overlay
        }
        NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil, queue: .main
        ) { [weak v] _ in v?.enclosingScrollView?.scrollerStyle = .overlay }
        return v
    }
    func updateNSView(_: NSView, context: Context) {}
}

/// Row-local hover scope. Hover changes re-render `content(hovered)` only — not
/// the enclosing `SidebarView.body` — so scrolling past rows doesn't storm the
/// `ScrollView` diff.
/// `tick` also re-evaluates the content on a periodic clock — the row's chrome derives from
/// wall-clock age (afterglow / doze / peek age) and would otherwise go stale when nothing
/// else triggers a render.
private struct Hovering<Content: View>: View {
    @State private var hovered = false
    let tick: TimeInterval
    @ViewBuilder let content: (Bool) -> Content
    var body: some View {
        TimelineView(.periodic(from: .now, by: tick)) { _ in content(hovered) }
            .onHover { hovered = $0 }
    }
}

extension PaneState {
    /// One display string per state, shared by every indicator's tooltip and the peek badge —
    /// three call sites had drifted into three phrasings of "blocked".
    var help: String {
        switch self {
        case .working: "Working"
        case .waiting: "Finished — unread"
        case .blocked: "Needs your input"
        }
    }
}

/// Right-edge status pill — reads as a vertical heatmap down the sidebar; host-accent hue so
/// busy rows also signal *which* host. `PaneMachine.dot` is the single source of truth
/// (probe `status` feeds it via `.probe(busy:)`), so `tempo`-vs-`status` can't render
/// contradictory indicators on one row.
private struct StatusRail: View {
    let state: PaneState?
    let accent: Color
    /// CC's `needs`/`waitingFor` when known — nil with showCC off (rail renders regardless).
    var blockedDetail: String? = nil
    var body: some View {
        // Help is per-state so a working/waiting/empty rail doesn't claim "needs input".
        Group {
            switch state {
            case .working: Pulsing { RoundedRectangle(cornerRadius: 1.5).fill(accent) }
            case .waiting:
                RoundedRectangle(cornerRadius: 1.5).strokeBorder(accent, lineWidth: 1)
                    .help(PaneState.waiting.help)
            case .blocked:
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.blocked)
                    .help(blockedDetail ?? PaneState.blocked.help)
            case nil:      Color.clear
            }
        }
        // `.id` forces a view swap on state change so the new pill springs in (scale+fade)
        // instead of teleporting — a small "hey, this row changed" beat. Keyed on `state`,
        // so the per-tick re-renders that don't change state animate nothing.
        .id(state)
        .transition(.scale(scale: 0.3).combined(with: .opacity))
        .animation(.bouncy(duration: 0.35, extraBounce: 0.15), value: state)
        .frame(width: 3, height: 20)
    }
}

/// `.symbolEffect(.pulse)` is macOS 14+; this is the 13-safe equivalent. Mounted only while
/// the pulsing state applies, so `@State on` resets on re-mount.
private struct Pulsing<Content: View>: View {
    @State private var on = false
    @ViewBuilder let content: Content
    var body: some View {
        content.opacity(on ? 1 : 0.45)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

private struct HoverHighlight: ViewModifier {
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .background(hovered ? Theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .onHover { hovered = $0 }
    }
}

private struct Spine: Shape {
    var first: Bool
    var last: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        let x = r.minX + 4
        p.move(to: .init(x: x, y: first ? r.midY : r.minY))
        p.addLine(to: .init(x: x, y: last ? r.midY : r.maxY))
        p.move(to: .init(x: x, y: r.midY))
        p.addLine(to: .init(x: r.maxX - 2, y: r.midY))
        return p
    }
}

/// Live-swap reorder for both host and tab drag — the `dragging` binding (not the
/// `.text` payload) discriminates which kind is in flight. SwiftUI gives no drag-cancel
/// hook, so each `.onDrag` clears the *other* binding first; otherwise a cancelled tab
/// drag would leak into the next host drag's `dropEntered` and fire a spurious `moveTab`.
private struct ReorderDelegate<ID: Equatable>: DropDelegate {
    let target: ID
    @Binding var dragging: ID?
    let move: (ID, ID) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.easeInOut(duration: 0.15)) { move(dragging, target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { .init(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

/// User's configured terminal face (so the sidebar reads as part of the grid, not a bolt-on
/// SwiftUI panel); falls back to system mono. `fixedSize` so Dynamic Type doesn't reflow.
fileprivate func forkMono(_ size: CGFloat, _ weight: Font.Weight = .regular,
                          _ family: String?) -> Font {
    if let family, !family.isEmpty {
        return .custom(family, fixedSize: size).weight(weight)
    }
    return .system(size: size, weight: weight, design: .monospaced)
}

extension Ghostty.Config {
    /// `font-family` is a `RepeatableString` whose C-API path (`c_get.zig:79`) returns
    /// `false` for non-packed structs without `cval()`, so it can't be read here without an
    /// upstream patch (seam policy). `window-title-font-family` is `?[:0]const u8` and works
    /// — upstream already exposes it (`windowTitleFontFamily`); we reuse that as the sidebar
    /// face. Set `window-title-font-family = <your terminal font>` to get matched typography.
    var forkFontFamily: String? { windowTitleFontFamily }
}

extension ForkHost {
    /// Primary tint (the A half) — used for text/stroke/status-rail; the dot is the only
    /// bicolor render.
    var accent: Color { Self.color(Self.pair(slot).a) }
    static func color(_ i: Int) -> Color {
        Color(hue: palette[i % N], saturation: 0.45, brightness: 0.7)
    }
}

/// Split-pebble host marker. Hard-stop gradient at 0.5 for a clean half; same-color stops
/// render solid (diagonal-slot case — first N hosts) so no `a==b` branch needed. The slot
/// also seeds `Pebble`, so each host's dot has its own slightly-irregular silhouette —
/// shape becomes a second recognition cue alongside the color pair.
struct HostDot: View {
    let slot: Int
    var size: CGFloat = 10

    init(slot: Int, size: CGFloat = 10) { self.slot = slot; self.size = size }
    /// nil → secondary placeholder dot (focus-mode badge for an unknown host).
    init(host: ForkHost?, size: CGFloat = 10) { self.slot = host?.slot ?? -1; self.size = size }

    /// The dot's silhouette — selection rings overlay this same shape so they hug the pebble
    /// outline. Keep the slot→seed mapping here only.
    static func outline(slot: Int) -> Pebble { Pebble(seed: slot) }

    var body: some View {
        let (a, b) = ForkHost.pair(slot)
        Self.outline(slot: slot)
            .fill(slot < 0 ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(LinearGradient(
                stops: [.init(color: ForkHost.color(a), location: 0.5),
                        .init(color: ForkHost.color(b), location: 0.5)],
                startPoint: .leading, endPoint: .trailing)))
            .frame(width: size, height: size)
    }
}
#endif
