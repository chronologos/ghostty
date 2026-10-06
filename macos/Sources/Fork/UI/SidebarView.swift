#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import GhosttyKit

/// Left sidebar: hosts as collapsible sections, tabs as rows (SPEC §9).
struct SidebarView: View {
    @Environment(\.forkTokens) private var tokens

    weak var controller: ForkWindowController?
    /// Off only for offscreen renders (`SidebarSnapshotTests`): mounting the view must not be
    /// what starts `zmx list` and ssh against whatever hosts the registry was seeded with.
    var polls = true
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
    /// self-regulates row height instead). The ⌥ gesture machinery lives in
    /// `OptionGestureRecognizer`; this is the only piece of its state row rendering reads
    /// (ccLine's lineLimit un-clamp).
    @State private var revealAll = false
    /// Tag-popover cursor — view-local: its only readers/writers are sidebar rows, and
    /// registry residence churned the debounce-save sink on every popover open/close.
    @State private var taggingPane: (tab: TabModel.ID, key: String)?

    private var fontFamily: String? { controller?.ghostty.config.forkFontFamily }
    private func mono(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { forkMono(s, w, fontFamily) }

    private var recentTags: ArraySlice<PaneTag> { registry.recentTags.prefix(5) }

    // MARK: Row gutter geometry
    // One layout rule per side: the *leading* gutter is identity (which tag a pane
    // wears), the *trailing* edge is state (lamps). Which panes hang
    // together is said by the rules instead: a hairline between tabs, none between the panes
    // of one tab. The heading's chevron column and the focus caption's indent are this same
    // width, so chips, chevrons and titles share one left edge.
    static let gutter: CGFloat = 16
    /// Centre line of the tag.
    static let tagX: CGFloat = 8
    static let bead: CGFloat = 7
    /// The title line's centre, measured from the top of the title block: a 14pt title is a
    /// ≈17pt line. The tag and the lamps are both placed by it.
    static let titleCenterTop: CGFloat = 8.5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                // Eager VStack: lazy materialisation made the overlay scroller jump
                // because each `hostSection` is variable-height and the content-size
                // estimate corrected on every scroll. Sidebar row counts are small
                // enough that rendering all of them is cheaper than the instability.
                VStack(alignment: .leading, spacing: 8) {
                    if focusMode {
                        focusSection
                    } else {
                        ForEach(registry.hosts) { host in
                            hostSection(host)
                        }
                    }
                }
                .padding(.bottom, 8)
                .background(OverlayScroller())
            }
            footer
        }
        // The terminal's own background, not a material: sidebar and grid are one surface,
        // divided by a rule.
        .background(tokens.ground)
        .overlay(alignment: .trailing) { tokens.rule.frame(width: 1) }
        // Polling (zmx list → aliases + reachability) starts with the sidebar regardless of
        // the CC toggle; the toggle only decides whether the loop also runs the CC probe.
        // Probe flag first so the poll's first reconcile already sees it.
        .task { if polls { registry.setCCProbeEnabled(showCC); registry.setPolling(true) } }
        .onChange(of: showCC) { if polls { registry.setCCProbeEnabled($0) } }
        .modifier(OptionGestureRecognizer(window: { controller?.window },
                                          revealAll: $revealAll,
                                          onPeek: { controller?.setCheatsheet($0) },
                                          onSweep: { registry.markAllCCRead() }))
        .onDisappear {
            // Stop the singleton's 3s poll loop — `setPolling(false)` cancels the
            // detached `Task`, which `.task`'s own auto-cancel can't (one-shot body
            // returns immediately). Otherwise leaks past last-window close
            // (`shouldQuitAfterLastWindowClosed` defaults false, AppDelegate.swift:1035).
            // Last-window only: the registry is shared, and a sibling window's sidebar has
            // no re-enable path short of its own next appear.
            if !ForkWindowController.anyOtherForkWindow(besides: controller?.window) {
                registry.setPolling(false)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            key("+ NEW", help: "New tab") { controller?.showSessionPicker() }
            key("HOSTS", help: "Hosts") { controller?.showHostsSheet() }
            key("HIDE", help: "Hide sidebar") { controller?.toggleSidebar() }
            key("TAGS", on: filterTagged, help: filterTagged ? "Show all" : "Tagged only") {
                withAnimation(.snappy(duration: 0.12)) { filterTagged.toggle() }
            }
            // Not `key` — macOS `Button` swallows mouseDown so `.onLongPressGesture`
            // on it never fires. Plain cap + tap/long-press composes exclusively.
            KeyCap(label: "FOCUS", on: focusMode, font: mono(10))
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
            // "CC", matching every other surface (tooltips, cheatsheet, host sheet) — this
            // toggle was the one label spelling the name out.
            key("CC", on: showCC, help: showCC ? "Hide CC session status" : "Show CC session status") {
                withAnimation(.snappy(duration: 0.12)) { showCC.toggle() }
            }
        }
        .padding(8)
    }

    /// A toolbar key. Words rather than symbols: six glyphs had to be learned, and a toggle's
    /// "on" was a tint. Here on is inverse video.
    private func key(_ label: String, on: Bool = false, help: String,
                     perform: @escaping () -> Void) -> some View {
        Button(action: perform) { KeyCap(label: label, on: on, font: mono(10)) }
            .buttonStyle(.plain)
            .help(help)
    }

    // MARK: Footer — the lamps' legend, which is also the fleet's tally: the rows scroll, this
    // doesn't, so "is anything waiting on me" has an answer that is always on screen.

    private var footer: some View {
        // A Set: the same session can be attached in two tabs, and it is one session.
        let refs = Set(registry.tabs.flatMap(\.tree.leafRefs))
        func count(_ s: PaneState) -> Int { refs.lazy.filter { registry.dot(ref: $0) == s }.count }
        let off = registry.hosts.reduce(0) {
            $0 + (controller?.detachedPlaceholders(on: $1.id).count ?? 0)
        }
        func row(words: Bool) -> some View {
            HStack(spacing: 0) {
                tally(.blocked, words ? "BLOCKED" : nil, count(.blocked), help: PaneState.blocked.help)
                Spacer(minLength: 8)
                tally(.finished, words ? "DONE" : nil, count(.waiting), help: PaneState.waiting.help)
                Spacer(minLength: 8)
                tally(.working, words ? "BUSY" : nil, count(.working), help: PaneState.working.help)
                Spacer(minLength: 8)
                tally(.detached, words ? "OFF" : nil, off, help: "Detached — sessions still running")
            }
        }
        // At the sidebar's narrow floor the words don't fit; a truncated "BLOCKED…" is worse
        // than none, and the lamps are the same ones the rows wear.
        return ViewThatFits(in: .horizontal) { row(words: true); row(words: false) }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .overlay(alignment: .top) { tokens.rule.frame(height: 1) }
    }

    /// Zero is an unlit lamp: a red square that is always lit beside "BLOCKED 0" is a false
    /// alarm, however useful as a legend.
    private func tally(_ kind: Lamp.Kind, _ word: String?, _ n: Int, help: String) -> some View {
        HStack(spacing: 5) {
            Lamp(n > 0 ? kind : .unlit)
            Text(word.map { "\($0) \(n)" } ?? "\(n)").font(mono(10)).kerning(0.5).fixedSize()
                .foregroundStyle(n > 0 ? tokens.text : tokens.inactive)
        }
        .help(help)
    }

    // MARK: Focus section — flat MRU-first list across all hosts.
    // `filterTagged` composes: off → last-16h; on → tagged-only, no time cutoff.

    private var focusTabs: [TabModel] { registry.focusTabs(taggedOnly: filterTagged) }

    private var focusSection: some View {
        let tabs = focusTabs
        // Own VStack so `.animation(value:)` sees the row positions it lays out;
        // attaching to the outer body VStack would also animate host-mode reflow.
        return VStack(alignment: .leading, spacing: 6) {
            if tabs.isEmpty {
                Label(filterTagged ? "No tagged panes" : "Nothing in the last \(Int(cutoffHours))h",
                      systemImage: filterTagged ? "tag.slash" : "moon.zzz")
                    .font(mono(13)).foregroundStyle(tokens.inactive)
                    .padding(.horizontal, 16).padding(.top, 12)
            } else {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { i, tab in
                    VStack(alignment: .leading, spacing: 3) {
                        // ⌘N + host ride on the tab's own heading when it has one (`tabHeading`
                        // draws them — one line of chrome per card instead of two). A
                        // default-titled tab has no heading, so it keeps this caption row:
                        // ⌘N + host above the tab, which frees the ~56pt leading column that
                        // was truncating pane titles, and is that tab's only tab-level
                        // right-click target. Indented by the row gutter so the ⌘N chips of
                        // headed and headless cards sit on the same line as the pane titles.
                        if !hasHeading(tab) {
                            // ⌘N left, dot+host right — caption recedes behind the rows.
                            HStack(spacing: 6) {
                                focusCaptionLeading(tab, index: i)
                                Spacer()
                                focusCaptionHost(tab)
                            }
                            // Same insets as `tabHeading` and the rows: gutter on the left,
                            // the state-rail column on the right.
                            .padding(.leading, Self.gutter).padding(.trailing, 8)
                            .contentShape(Rectangle())
                            .contextMenu { tabContextMenu(tab) }
                        }
                        tabRow(tab, focusIndex: i)
                    }
                    .modifier(ForkCard())
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: tabs.map(\.id))
    }

    /// Focus-mode card caption, leading half: the ⌘N chip + pin. Drawn either on the tab's
    /// heading or, for a headless tab, on its own caption row — same pieces, so the two
    /// kinds of card can't drift.
    @ViewBuilder
    private func focusCaptionLeading(_ tab: TabModel, index i: Int) -> some View {
        // No empty pill on rows 10+ — the Spacer handles alignment.
        if i < 9 { keyHint("⌘\(i + 1)") }
        if tab.pinned { pinBadge(size: 8) }
    }

    /// Focus-mode card caption, trailing half: which host this card lives on. The dot holds
    /// its size; the label gives way first when a long heading needs the room (the heading is
    /// right there, and the square still says which host, so the name is the most redundant thing
    /// on the line).
    @ViewBuilder
    private func focusCaptionHost(_ tab: TabModel) -> some View {
        let host = registry.host(id: tab.hostID)
        HostDot(host: host, size: 7, square: true)
        Text(host?.label ?? "—")
            .font(mono(11)).foregroundStyle(tokens.inactive).lineLimit(1)
    }

    /// Does this tab draw a `tabHeading`? Only when its title says more than its first
    /// session's name does (or it's collapsed / mid-rename, which need the row regardless).
    private func hasHeading(_ tab: TabModel) -> Bool {
        registry.renaming == .tab(tab.id) || tab.collapsed
            || tab.title != tab.tree.leafRefs.first?.name
    }

    private func tagButton(_ t: PaneTag, tab: TabModel.ID, ref: String,
                           prefix: String = "") -> some View {
        Button { registry.setPaneTag(tab: tab, name: ref, to: t) } label: {
            Label(prefix + t.text, systemImage: "circle.fill").foregroundStyle(Theme.tag(t.hue))
        }
    }

    /// Worst-child rollup for collapsed headers — the same `Lamp` the rows wear, so there is
    /// one encoding to learn (the old inline dot had to re-state the rail's in a second shape).
    @ViewBuilder
    private func stateLamp(_ s: PaneState?) -> some View {
        if let s { Lamp(s).help(s.help) }
    }

    private func keyHint(_ chord: String) -> some View {
        Text(chord).font(mono(10, .semibold)).foregroundStyle(tokens.text)
    }

    // MARK: Host section

    @ViewBuilder
    private func hostSection(_ host: ForkHost) -> some View {
        // Same accessor ⌘1-9 indexes (`gotoTab`) — a filter added here alone would desync them.
        let tabs = registry.hostTabs(on: host.id, taggedOnly: filterTagged)
        // Filter-on + no tagged tabs on this host → hide the whole section so the
        // sidebar isn't cluttered with empty host cards.
        if !(filterTagged && tabs.isEmpty) {
            // One module per host: a cut-corner frame holding a title strip and the rows. A
            // host with no live surface gets the quiet line — the frame is the host's lamp.
            let line = registry.isConnected(host.id) ? tokens.text : tokens.rule
            VStack(alignment: .leading, spacing: 0) {
                hostHeader(host, tabs: tabs)
                if host.expanded {
                    line.frame(height: 1)
                    if !tabs.isEmpty {
                        hostBody(tabs: tabs)
                    } else {
                        // Expanded host, zero tabs: without this the module opens onto nothing
                        // and the section reads as broken rather than empty.
                        Text("No sessions — right-click the host to create one")
                            .font(mono(11)).foregroundStyle(tokens.inactive)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                }
            }
            .clipShape(Chamfer())
            .overlay(Chamfer().strokeBorder(line, lineWidth: 1))
            .padding(.horizontal, 8)
        }
    }

    private func hostHeader(_ host: ForkHost, tabs: [TabModel]) -> some View {
        let connected = registry.isConnected(host.id)
        let index = registry.hosts.firstIndex { $0.id == host.id }
        return Button {
            withAnimation(.snappy(duration: 0.15)) { registry.setExpanded(host.id, !host.expanded) }
        } label: {
            HStack(spacing: 6) {
                // No chevron: a collapsed module is a strip with nothing under it. And nothing
                // on the strip that has to be explained: it once led with a part-number-style
                // "H-01" and ended with a bare tab count, and neither said what it was.
                HostDot(host: host, size: 8, square: true)
                Text(host.label.uppercased())
                    .font(mono(11, .bold)).kerning(1).lineLimit(1)
                    .foregroundStyle(connected ? tokens.text : tokens.inactive)
                    .layoutPriority(1)
                if let since = registry.hostUnreachableSince[host.id] {
                    // Transport-level cue (zmx list failing), distinct from the dot's
                    // "no live surface" dimming — without it, hours-old CC status on a
                    // dead ssh host reads as live.
                    // The reason matters: "zmx list timed out" (a few sessions not answering)
                    // and "ssh couldn't connect" send the user to different places.
                    let why = registry.hostUnreachableWhy[host.id].map { " — \($0)" } ?? ""
                    Lamp(.unresponsive)
                        .help("No answer since \(since.formatted(date: .omitted, time: .shortened))\(why). Status shown may be stale.")
                } else if let n = controller?.detachedPlaceholders(on: host.id).count, n > 0 {
                    // After a VPN flap / wake every ssh pane here is sitting at its reattach
                    // prompt while the sessions are fine — say so without making the user
                    // click through tabs to find out. The action is in the context menu.
                    HStack(spacing: 3) {
                        Lamp(.detached)
                        Text("\(n)").font(mono(10, .semibold))
                    }
                    .foregroundStyle(tokens.inactive)
                    .help("\(n) pane\(n == 1 ? "" : "s") detached — sessions still running. Right-click → Reattach.")
                }
                // The filler gives way first: a long host name or a narrow sidebar squeezes it
                // to nothing before anything that says something.
                Hatch().stroke(connected ? tokens.text : tokens.rule, lineWidth: 1)
                    .frame(minWidth: 0, maxWidth: .infinity).frame(height: 8).clipped()
                if !host.expanded {
                    // Roll up over the same filtered set the rows render — with the tag filter on, a hidden untagged tab's state must
                    // not drive a lamp that points at something the user can't see.
                    stateLamp(tabs.lazy.compactMap { registry.rollup(tab: $0) }.max())
                }
                if let index, index < 9 {
                    keyHint("⌘⌥\(index + 1)")
                }
            }
            .padding(.horizontal, 10).frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverHighlight())
        .onDrag {
            draggingTab = nil; draggingHost = host.id
            return NSItemProvider(object: host.id as NSString)
        }
        .onDrop(of: [.text], delegate: ReorderDelegate(
            target: host.id, dragging: $draggingHost, move: registry.moveHost))
        .contextMenu {
            Button("New Session on \(host.label)…") {
                controller?.showSessionPicker(lockedTo: host)
            }
            Button("Manage Host…") { controller?.showHostsSheet(select: host.id) }
            if let n = controller?.detachedPlaceholders(on: host.id).count, n > 0 {
                Button("Reattach \(n) Detached Pane\(n == 1 ? "" : "s")") {
                    controller?.reattachDetached(on: host.id)
                }
            }
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
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { i, tab in
                // The rule is the grouping: between tabs, never between one tab's panes.
                VStack(alignment: .leading, spacing: 0) {
                    if i > 0 { tokens.rule.frame(height: 1) }
                    tabRow(tab)
                }
            }
        }
        .padding(4)
        .transition(.opacity)
    }

    // MARK: Tab → pane rows
    // Each row's label is `paneLabels[ref.key]` (the alias — cache of the daemon-side
    // `ghostty_name` session label, ⌘I renames both) › `surface.title` (OSC, live) ›
    // `ref.name` (the immutable session id), with the id as subtitle when the alias
    // differs. `tab.title` is a heading
    // above the group, shown only when it diverges from the first session name (⌘⇧I edits it).
    // Cold-restored tabs have no live surfaces until first activated.

    /// `focusIndex`: the card's position in focus mode (drives the ⌘N chip) — nil in host
    /// mode, where the row's visual position *is* the ⌘N index and no chip is drawn.
    private func tabRow(_ tab: TabModel, focusIndex: Int? = nil) -> some View {
        let active = tab.id == registry.activeTabID
        let allRefs = tab.tree.leafRefs
        let surfaces = controller?.surfaces(for: tab.id) ?? []
        let renaming = registry.renaming == .tab(tab.id)
        return VStack(alignment: .leading, spacing: 0) {
            if hasHeading(tab) {
                tabHeading(tab, renaming: renaming, active: active, paneCount: allRefs.count,
                           focusIndex: focusIndex)
            }
            if !tab.collapsed {
                ForEach(Array(allRefs.enumerated()), id: \.0) { i, ref in
                    // Index-match: `surfaces` may be one ahead of `allRefs` for ≤80ms after a
                    // split (debounced persistActive) — accepted; matching by ref instead
                    // would mis-pair duplicate-ref tabs (PR26) permanently.
                    paneRow(tab, index: i, ref: ref,
                            surface: i < surfaces.count ? surfaces[i] : nil,
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
                            paneCount: Int, focusIndex: Int? = nil) -> some View {
        let toggle = {
            withAnimation(.snappy(duration: 0.15)) {
                registry.setCollapsed(tab.id, !tab.collapsed)
            }
        }
        return HStack(spacing: 0) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(tokens.inactive)
                    .rotationEffect(.degrees(tab.collapsed ? 0 : 90))
                    .frame(width: Self.gutter, height: 18, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Focus mode: the card's caption (⌘N · pin … host) rides on this line instead of
            // taking a row of its own above it.
            if let focusIndex {
                HStack(spacing: 6) { focusCaptionLeading(tab, index: focusIndex) }
                    .padding(.trailing, 6)
            }
            if renaming {
                renameField(seed: tab.title, font: mono(12, .semibold))
            } else {
                Text(tab.title.uppercased())
                    .font(mono(10, .semibold)).kerning(1.2).lineLimit(1)
                    .foregroundStyle(active ? tokens.text : tokens.inactive)
                    // The title keeps its width; the host label on the same line truncates
                    // first (see `focusCaptionHost`).
                    .layoutPriority(1)
            }
            Spacer(minLength: 6)
            if tab.collapsed {
                stateLamp(registry.rollup(tab: tab))
                    .padding(.trailing, 6)
                Text("\(paneCount)").font(mono(11)).foregroundStyle(tokens.inactive)
                    .padding(.trailing, focusIndex == nil ? 0 : 6)
            }
            if focusIndex != nil {
                HStack(spacing: 6) { focusCaptionHost(tab) }
            }
        }
        .padding(.top, 2).padding(.trailing, 8).frame(height: 18)
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

    /// "Merge Into ▸ <tab> ▸ To the Right / Below" — fold all of `tab`'s panes into
    /// another tab on the same host, side-by-side (horizontal split) or stacked
    /// (vertical split). Hidden when no valid destination exists.
    @ViewBuilder
    private func mergeIntoMenu(_ tab: TabModel) -> some View {
        let targets = registry.tabs(on: tab.hostID).filter { $0.id != tab.id }
        // mergeTab skips externals; an external-only src would be a dead menu item.
        if !targets.isEmpty, tab.tree.leafRefs.contains(where: { !$0.external }) {
            Menu("Merge Into…") {
                ForEach(targets) { dst in
                    Menu(dst.title.isEmpty ? "(untitled)" : dst.title) {
                        Button {
                            controller?.mergeTab(from: tab.id, into: dst.id, direction: .horizontal)
                        } label: {
                            Label("To the Right (side by side)", systemImage: "rectangle.split.2x1")
                        }
                        Button {
                            controller?.mergeTab(from: tab.id, into: dst.id, direction: .vertical)
                        } label: {
                            Label("Below (stacked)", systemImage: "rectangle.split.1x2")
                        }
                    }
                }
            }
        }
    }

    private func paneRow(_ tab: TabModel, index: Int, ref: SessionRef,
                         surface: Ghostty.SurfaceView?, active: Bool) -> some View {
        let focused = active && (registry.focusedPaneIndex.map { $0 == index } ?? (index == 0))
        let userLabel = tab.paneLabels[ref.key]
        let tag = tab.paneTags[ref.key]
        let renaming = registry.renaming == .pane(tab.id, name: ref.key)
        let live = showCC ? registry.ccLive[tab.hostID]?[ref.key] : nil
        let dot = registry.dot(ref: ref)
        // Lamp-tooltip + question text: "what is it waiting for" is the triage answer
        // for a blocked pane. Scoped to .blocked — a stale `needs` on a working pane reads
        // as a false alarm. Shared with `ccLine` so the two can't derive differently.
        let blockedDetail = dot == .blocked ? live?.attention : nil
        let cue = zmxCue(ref, hydrated: surface != nil)
        // Recency lives in two carriers, not a column: sleep (the long tail —
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
        // The row's second line. What CC says wins;
        // a row CC has nothing to say about shows where the session is sitting (the daemon's
        // cwd, plus the command it was created to run) — the same line the ⌘T picker prints,
        // so a plain shell's second line says something instead of holding an empty band.
        // With neither, there is no second line and the row is its 28pt minimum.
        // `cached` only for placeholder rows (no surface yet) — on a hydrated pane where CC
        // has exited it'd show the dead session's name as stale. `surface.title` is read
        // un-observed (only `PaneLabel` subscribes): it feeds the repeated-name check
        // alone, and a row re-renders on every probe publish anyway.
        let shownTitle = PaneLabel.displayed(userLabel: userLabel, title: surface?.title ?? "",
                                             fallback: ref.name)
        let ccText = showCC ? ccLabel(live: live,
                                      cached: surface == nil ? tab.ccNames[ref.key] : nil,
                                      fallback: ref.name, title: shownTitle,
                                      attention: blockedDetail) : nil
        let whereText = showCC && ccText == nil
            ? registry.zmxCwd[tab.hostID]?[ref.key].flatMap(SessionNameLabel.whereLine) : nil
        // tick: sleep and the peek age both derive from wall-clock age — without
        // a clock, a row nothing else re-renders (showCC off, no focus changes) would never
        // fall asleep.
        return Hovering(tick: 60) { hovered, peek in
            // Long-tail recency: past the focus cutoff a row sleeps, and its text goes to the
            // inactive gray. Never asleep: the active tab (literally on screen), hovered rows
            // (hover means you're trying to read it), blocked rows (a pane asking for you
            // must not be the faintest row in the sidebar), and rows with unread status text
            // (sleep keys on *your* visits, so it would gray hardest exactly the catch-up
            // content the unread model exists to surface). The ⌥ reveal deliberately does
            // NOT wake a row or brighten read text — it only un-clamps the line count, so
            // holding ⌥ reads as "more of the same sidebar", not a different one.
            let asleep = !(active || hovered || dot == .blocked || unread)
                && Theme.asleep(lastSeen(),
                                cutoff: SessionRegistry.focusCutoffSeconds(hours: cutoffHours))
            // A session with nobody home reads inactive whatever its age.
            let gone = cue.map { $0.lamp != .unresponsive } ?? false
            let tint = focused ? tokens.bright : (asleep || gone) ? tokens.inactive : tokens.text
            HStack(spacing: 0) {
                // Leading gutter = identity: this pane's tag (drawn from the title
                // block below, so it sits on the title line whatever the row's height).
                // The trailing edge is state only — lamps.
                Color.clear.frame(width: Self.gutter)
                // Content column: the original row line + (when peeked) the ledger below it.
                // `.top`: lamps and the tag sticker stay level with the title line however
                // many lines the status text below it wraps to.
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            Group {
                                if renaming {
                                    renameField(seed: userLabel ?? ref.name, font: mono(14))
                                } else if let surface {
                                    PaneLabel(surface: surface, userLabel: userLabel, fallback: ref.name,
                                              tint: tint, struck: cue?.lamp == .ended, focused: focused,
                                              suppressSubtitle: showCC, fontFamily: fontFamily)
                                } else {
                                    Text(userLabel ?? ref.name)
                                        .font(mono(14, focused ? .bold : .regular)).lineLimit(1)
                                        .strikethrough(cue?.lamp == .ended)
                                        .foregroundStyle(tint)
                                }
                            }
                            // The tag: a filled square in the gutter, level with
                            // the title. It used to be a hollow ring in the trailing column,
                            // beside the state indicator — where a red tag read as an alarm (red is
                            // `Theme.blocked`'s color, and that column is where alarms live).
                            // Hung off the title as an overlay rather than laid out in the
                            // gutter so it tracks the title line exactly: rows are 1–4 lines
                            // tall and only the title knows where its own centre is.
                            .overlay(alignment: .topLeading) {
                                if let tag {
                                    Rectangle().fill(Theme.tag(tag.hue))
                                        .frame(width: Self.bead, height: Self.bead)
                                        .offset(x: Self.tagX - Self.gutter - Self.bead / 2,
                                                y: Self.titleCenterTop - Self.bead / 2)
                                        .help(tag.text)
                                }
                            }
                            if showCC {
                                // Replaces PaneLabel's zmx-name subtitle (suppressed via `showCC`
                                // above) with `ccText` › `whereText` › nothing (decided above the
                                // row). A row with unread CC status text may grow to 3 subtitle
                                // lines (4 total — the wrap cap lives in `ccLine`).
                                if let ccText {
                                    ccLine(ccText, live: live, attention: blockedDetail,
                                           read: read, unclamped: peek)
                                } else if let whereText {
                                    // `.head`: the leaf of a path is the part that identifies it.
                                    Text(whereText).font(mono(11)).lineLimit(1).truncationMode(.head)
                                        .foregroundStyle(tokens.inactive)
                                }
                            }
                        }
                        Spacer(minLength: 6)
                        // The tag's *name* — hover only. At rest the tag is the square in the
                        // leading gutter and this column holds nothing but state; the label
                        // slides in while you're actually pointing at the row, which is when
                        // "which tag is that color" is the question.
                        if let tag, hovered {
                            Text(tag.text.uppercased()).font(mono(10, .bold)).kerning(0.5)
                                .foregroundStyle(tokens.ground).fixedSize()
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Theme.tag(tag.hue))
                                .transition(.opacity.combined(with: .move(edge: .trailing)))
                                .padding(.trailing, 6).padding(.top, 1)
                        }
                        // One lamp per fact, rightmost = the row's main one, so the right edge
                        // reads as a column. Every row has it, lit or not: an unlit lamp is
                        // what makes a lit one legible as "on". Watching is its own lamp because
                        // it is armed on panes that are busy — the two have to coexist.
                        HStack(spacing: 3) {
                            if registry.panes[ref]?.watched == true {
                                Lamp(.watching).help("Watching — ⌘⌥A to disarm")
                            }
                            if let cue, dot != nil { Lamp(cue.lamp).help(cue.help) }
                            if let dot {
                                Lamp(dot).help(dot == .blocked ? blockedDetail ?? dot.help : dot.help)
                            } else if let cue {
                                Lamp(cue.lamp).help(cue.help)
                            } else {
                                // Unlit on the focused row too: its outline and title already
                                // say "here", and a lit lamp means "wants your eyes".
                                Lamp(.unlit)
                            }
                        }
                        .padding(.top, Self.titleCenterTop - Lamp.size / 2)
                    }
                    .animation(.snappy(duration: 0.15), value: hovered)
                    // Peek ledger — suppressed while renaming (growth under a focused text
                    // field just shoves it around mid-edit).
                    if peek, !renaming {
                        let ages = [
                            ccStamp().map { "CC turned \($0.shortAge) ago" },
                            (focused ? nil : tab.lastActive[ref.key]).map { "you were here \($0.shortAge) ago" },
                        ].compactMap { $0 }
                        PanePeek(state: dot,
                                 // CC's cwd (where the agent works) › the zmx daemon's own
                                 // tracking — the only source for a plain shell on an ssh
                                 // host, and it works with the CC toggle off.
                                 cwd: live?.cwd ?? registry.zmxCwd[tab.hostID]?[ref.key]?.cwd,
                                 zmxState: cue?.word,
                                 // Wire name, not ref.name: managed sessions attach as
                                 // "{hostID}-{name}" — showing the bare name as the ZMX
                                 // identity invites a `zmx attach` that silently creates
                                 // a fresh empty session instead.
                                 session: ZmxAdapter.wireName(ref),
                                 host: registry.host(id: tab.hostID)?.label ?? "—",
                                 age: ages.isEmpty ? nil : ages.joined(separator: " · "),
                                 ccName: live?.name,
                                 rawStatus: live?.status,
                                 fontFamily: fontFamily)
                            .transition(.opacity)
                    }
                }
            }
            .padding(.trailing, 7).padding(.vertical, 2).frame(minHeight: 30)
            // "Here" is a shape, not a shade: a bright cut-corner outline (+ the heavier,
            // brighter title above). Hover is the same outline in the quiet rule color.
            .overlay(Chamfer(cut: 5).strokeBorder(
                focused ? tokens.bright : hovered ? tokens.rule : .clear, lineWidth: 1))
            .contentShape(Rectangle())
            // Hover peek — formerly a multi-line `.help` tooltip here, now the in-row
            // PanePeek ledger (rest the cursor `Theme.peekDelay` to open). Everything the
            // one-line subtitle elides — state, the full detail/question, cwd, identity,
            // age — lives there instead. Child `.help`s (lamps, tag) still win over
            // their own rects.
        }
        .onTapGesture { controller?.activate(tab: tab.id, paneIndex: index) }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            registry.setRenaming(.pane(tab.id, name: ref.key))
        })
        .contextMenu { paneContextMenu(tab, ref: ref, tag: tag) }
        .popover(isPresented: Binding(
            get: { taggingPane.map { $0 == (tab.id, ref.key) } ?? false },
            // Only clear shared state if it still points at *this* row — opening B's popover
            // (context-menu "New Tag…") flips A's getter false, and A's NSPopover-dismiss
            // callback would otherwise race B's open by nilling `taggingPane` from under it.
            set: { if !$0, taggingPane.map({ $0 == (tab.id, ref.key) }) ?? false {
                taggingPane = nil
            } }
        ), arrowEdge: .trailing) {
            TagEditView(seed: tag) {
                registry.setPaneTag(tab: tab.id, name: ref.key, to: $0)
                taggingPane = nil
            }
        }
        // Identity guard: the enclosing ForEach is offset-keyed (deliberate — see tabRow's
        // index-match comment), so without this a removed sibling shifts a *different* pane
        // into this slot and it inherits Hovering's @State (hazard class #2 — the peek
        // ledger turns that leak into a fully expanded wrong row, not just a faint wash).
        // Compound offset+ref key stays unique under PR26 duplicate-ref attach.
        .id("\(index)-\(ref.key)")
    }

    /// What the last `zmx list` says is *wrong* with this pane's session, if anything — the
    /// pane's own pty can't tell (every way a zmx client ends is exit 0, and a placeholder
    /// looks the same whether there's anything left to reattach to).
    /// - ended: shown for cold rows too — it's what stops "just looking at a tab" from
    ///   silently re-creating dead sessions.
    /// - detached: only for a hydrated pane (a cold row has no client by definition).
    ///   Covers the placeholder at its prompt *and* a pane whose client was switched to
    ///   another session in-band (`zmx attach other` typed inside it) — either way the
    ///   thing this row names has nobody attached.
    private func zmxCue(_ ref: SessionRef, hydrated: Bool) -> (lamp: Lamp.Kind, word: String, help: String)? {
        switch registry.liveness[ref] {
        case .ended:
            (.ended, "ENDED",
             "This zmx session is gone — its shell exited, or it was killed. Reattaching starts a fresh shell under the same name.")
        case .unresponsive(let err):
            (.unresponsive, "NOT RESPONDING",
             "The zmx daemon didn't answer (\(err)). The session is very likely still alive, just busy.")
        case .listed(let clients) where clients == 0 && hydrated:
            (.detached, "DETACHED",
             "No zmx client is attached to this session — the pane is at its reattach prompt, or its client switched to another session.")
        default: nil
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
                Button("New Tag…") { taggingPane = (tab.id, ref.key) }
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
            .font(.system(size: size)).foregroundStyle(tokens.inactive)
            .rotationEffect(.degrees(-18))
    }

    /// CC subtitle — status lives in the right-edge lamp; recency is the row's
    /// sleep and the hover peek's age line.
    /// Blocked: the question CC is asking, in `tokens.bright` (the red lives in the
    /// lamp). Otherwise `name · detail` is a live
    /// activity feed (what the session is, what it's doing / last did), falling back to
    /// cwd basename, then the cached last-seen name for placeholder rows. Unread text is
    /// secondary and wraps to 3 lines so the activity is readable in place; `read` text
    /// (focused pane, or nothing new since the user last left it — see `ccSeenDetail`)
    /// demotes to one tertiary line: still a scent trail of what the session last said,
    /// but visually "done". CC session names render a half-step heavier (.medium) than the
    /// status text — without it the name reads as a second pane title one row down. The
    /// question (`attention`) is never demoted here — it has its own ack.
    ///
    /// Content and styling are split: `ccLabel` returns nil when CC has nothing to say, and
    /// the row then shows the session's where-line instead (or no second line at all). The
    /// slot used to be reserved unconditionally — an empty 13pt band under every plain shell.
    ///
    /// `title` is what the row's first line already shows. A CC session named after its pane
    /// (the usual case — the alias and the CC name are kept in sync) would otherwise print
    /// the same word twice, once as the title and once in small caps below it; the name is
    /// dropped when it only repeats the title, and a name with nothing after it then yields
    /// nil rather than a line that says nothing new.
    private func ccLabel(live: CCProbe.Info?, cached: String?, fallback: String,
                         title: String, attention: String?) -> Text? {
        // cwd basename is only useful when more specific than the pane's own name — an
        // unnamed CC at a shared repo root would read identically on every row.
        let cwdLeaf = live?.cwd
            .map { ($0 as NSString).lastPathComponent }
            .flatMap { $0 == fallback ? nil : $0 }
        func echoesTitle(_ n: String) -> Bool { Self.echoes(n, title: title) }
        // The agent identity reads as small caps — a typographic role change (label-like)
        // rather than a third color: uppercased at a smaller size with a touch of tracking,
        // because terminal mono families rarely carry a real smcp feature for
        // `Font.smallCaps()` to use. Color stays with the line (secondary unread / tertiary
        // read or cached) so "dim = read" remains one rule.
        func name(_ n: String) -> Text {
            Text(n.uppercased()).font(mono(11, .medium)).kerning(0.5)
        }
        // `cached` is for the CC-exited case only; a running-but-unnamed session must not
        // fall through to the previous session's name in live styling.
        if let attention { return Text(attention) }
        guard let live else {
            return cached.flatMap { echoesTitle($0) ? nil : name($0) }
        }
        let n = live.name.flatMap { echoesTitle($0) ? nil : $0 }
        switch (n, live.detail) {
        case let (n?, d?): return name(n) + Text(" · \(d)")
        case let (n?, nil): return name(n)
        case let (nil, d?): return Text(d)
        case (nil, nil): return cwdLeaf.map { Text($0) }
        }
    }

    /// Does a CC session name merely repeat the row's title? Case- and punctuation-blind:
    /// `API-SERVER`, `api_server` and `Api Server` are the same name as far as "does line two repeat
    /// line one" goes. A name that folds to nothing never matches (it isn't a repeat of
    /// anything — and two empty folds comparing equal would hide it). Pure, for tests.
    static func echoes(_ name: String, title: String) -> Bool {
        func fold(_ s: String) -> String {
            String(String.UnicodeScalarView(
                s.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
        }
        let f = fold(name)
        return !f.isEmpty && f == fold(title)
    }

    private func ccLine(_ label: Text, live: CCProbe.Info?,
                        attention: String?, read: Bool, unclamped: Bool) -> some View {
        // The question renders bright, not red: with several agents blocked at once a
        // 3-line red paragraph per row reads as a wall of alarm. Red stays on the
        // lamp; the question and unread status text share `tokens.bright` ("look here"),
        // and the lamp beside them says which of the two it is.
        let style = (attention == nil && (read || live == nil)) ? tokens.inactive : tokens.bright
        return label
            // `attention == nil`: the read-state belongs to the detail text only — a blocked
            // question must keep its 3 lines even when the unrelated detail counts as read
            // (⌥⌥ sweep, unchanged-detail exit-stamp, question arriving while focused).
            // `live == nil`: a cached placeholder name stays one line, keeping cold-restored
            // rows as uniform as the old fixed-height slot did.
            // `!revealAll`: ⌥-hold lifts only this clamp — the inactive color and sleep stay, so
            // the peek expands the text without re-skinning the sidebar.
            // `unclamped` (row peek open): lifts the cap to 8 — enough for any real status
            // text/question, but bounded so a pathological multi-paragraph probe string
            // can't spring the row over the whole sidebar (the old floating tooltip had no
            // layout impact; an in-row expansion does).
            .font(mono(12))
            .lineLimit(unclamped ? 8
                       : ((read && !revealAll) || live == nil) && attention == nil ? 1 : 3)
            // vertical: true — claim the wrapped height even when the layout pass proposes
            // a tight one (otherwise the text can collapse back to one ellipsized line);
            // horizontal stays flexible so it still wraps to the sidebar width.
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(style)
        // Truncation past the cap is recoverable via the row-level hover peek (the PanePeek
        // ledger, which also un-clamps this line) — no per-Text tooltip here so the two
        // can't disagree.
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
            registry.renamePane(tab: id, name: name, to: renameText.isEmpty ? nil : renameText)
        case nil: break
        }
        registry.setRenaming(nil)
    }
}

/// `surface.title` is `@Published`; observing it here means only the label re-renders
/// when the shell sends OSC 0/2 — not the whole sidebar.
private struct PaneLabel: View {
    @Environment(\.forkTokens) private var tokens

    @ObservedObject var surface: Ghostty.SurfaceView
    let userLabel: String?
    let fallback: String
    /// Decided by the row (bright / text / inactive) — it knows about sleep and liveness.
    let tint: Color
    /// The session has ended: the name is crossed out, not just grayed.
    let struck: Bool
    /// The pane keyboard focus is in — a heavier title, part of the focused row's
    /// "here" shape along with its outline.
    let focused: Bool
    let suppressSubtitle: Bool
    let fontFamily: String?

    /// The title line's text: alias › OSC title › session id. Static so `paneRow` can ask
    /// what line one says (the CC-name dedupe in `ccLabel`) without a second copy of the rule.
    static func displayed(userLabel: String?, title t: String, fallback: String) -> String {
        // Upstream's `titleFallbackTimer` sets `"👻"` after 500ms if no OSC title arrived
        // (SurfaceView_AppKit.swift:323) — treat it as "no title" so the session name shows.
        // A path-shaped title (OMZ-style `%n@%m:%~`, `$PWD`, `~/…`) also counts as no-title:
        // the user wants the zmx session id, not whatever the shell reports as cwd.
        let isPathish = t.hasPrefix("/") || t.hasPrefix("~") || t.contains(":/") || t.contains(":~")
        return userLabel ?? (t.isEmpty || t == "👻" || isPathish ? fallback : t)
    }

    var body: some View {
        let label = Self.displayed(userLabel: userLabel, title: surface.title, fallback: fallback)
        return VStack(alignment: .leading, spacing: 0) {
            Text(label).font(forkMono(14, focused ? .bold : .regular, fontFamily)).lineLimit(1)
                .strikethrough(struck)
                .foregroundStyle(tint)
            if !suppressSubtitle && label != fallback {
                Text(fallback).font(forkMono(11, .regular, fontFamily)).lineLimit(1)
                    .foregroundStyle(tokens.inactive)
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

/// Row-local hover scope. Hover changes re-render `content(hovered, peek)` only — not
/// the enclosing `SidebarView.body` — so scrolling past rows doesn't storm the
/// `ScrollView` diff.
/// `hovered` is the immediate edge (background wash, tag pill); `peek` arms only after the
/// cursor has *rested* on the row for `Theme.peekDelay` and drives the row's expansion.
/// The intent timer restarts on every hover edge, so mouse traversal and scrolling (rows
/// sliding under a still cursor re-enter hover) never pop rows open in passing.
/// `tick` also re-evaluates the content on a periodic clock — the row's chrome derives from
/// wall-clock age (sleep / peek age) and would otherwise go stale when nothing
/// else triggers a render.
private struct Hovering<Content: View>: View {
    @State private var hovered = false
    @State private var peek = false
    @State private var intent: Task<Void, Never>?
    /// AppKit ground truth for "is the mouse actually on this row right now" — rebound by
    /// `MouseInside` once its NSView mounts. Defaults pessimistic-true (a fresh row whose
    /// check hasn't bound yet shouldn't lose its first peek).
    @State private var mouseInside: () -> Bool = { true }
    let tick: TimeInterval
    @ViewBuilder let content: (_ hovered: Bool, _ peek: Bool) -> Content
    var body: some View {
        TimelineView(.periodic(from: .now, by: tick)) { _ in content(hovered, peek) }
            .background(MouseInside { mouseInside = $0 })
            .onHover { h in
                hovered = h
                intent?.cancel()
                if h {
                    intent = Task {
                        try? await Task.sleep(for: .seconds(Theme.peekDelay))
                        guard !Task.isCancelled else { return }
                        // Re-check against AppKit before expanding: rows can slide under a
                        // *stationary* cursor (scroll, focus-mode MRU reorder) and AppKit
                        // doesn't reliably deliver `.onHover(false)` for view movement —
                        // never exhale a row the mouse isn't on, and clear its stale wash.
                        guard mouseInside() else { hovered = false; return }
                        withAnimation(Theme.exhale) { peek = true }
                    }
                } else {
                    withAnimation(Theme.settle) { peek = false }
                }
            }
            // Rows can diff out mid-hover (tab closed, focus reorder, filter toggle) without
            // `.onHover(false)` ever firing (hazard: stale hover state) — disarm the timer so
            // it can't fire into a row that no longer exists.
            .onDisappear { intent?.cancel() }
    }
}

/// Invisible AppKit view that answers "is the mouse inside this row's bounds *right now*?"
/// — the check `Hovering` runs before expanding. SwiftUI `.onHover` state can go stale when
/// a row moves under a stationary cursor; `mouseLocationOutsideOfEventStream` can't.
private struct MouseInside: NSViewRepresentable {
    let bind: (@escaping () -> Bool) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in
            bind {
                guard let v, let win = v.window else { return false }
                return v.bounds.contains(v.convert(win.mouseLocationOutsideOfEventStream, from: nil))
            }
        }
        return v
    }
    func updateNSView(_: NSView, context: Context) {}
}

/// The peek ledger — the in-row expansion that replaced the pane-row tooltip. In-row rather
/// than a tooltip/popover: no floating chrome, can't steal key status from the terminal, and
/// the reveal can be staged (rule draws itself, lines cascade in) instead of popping in a
/// gray box. Content is the WHERE/WHEN half of the row's story — state + age, working dir,
/// zmx identity; the WHAT (CC's status text / blocked question) is `ccLine` directly above,
/// which un-clamps its line limit while the peek is open.
private struct PanePeek: View {
    @Environment(\.forkTokens) private var tokens

    let state: PaneState?
    let cwd: String?
    /// ENDED / DETACHED / NOT RESPONDING from the last poll, nil when healthy.
    var zmxState: String? = nil
    /// zmx wire name — what `zmx attach <this>` takes on the host; the one identity that
    /// never appears in the row once a user label or OSC title covers it.
    let session: String
    let host: String
    let age: String?
    /// CC session's self-reported name — the row tooltip used to lead with it; without it
    /// two simultaneously blocked panes with user labels are indistinguishable.
    let ccName: String?
    /// Probe's raw status string — the state label when PaneMachine has no dot, so a CC
    /// mid-operation (e.g. "compacting") doesn't read as IDLE.
    let rawStatus: String?
    let fontFamily: String?
    /// Drives the staged reveal. Flipped once on mount: the peek view is re-inserted on
    /// every open (so the cascade replays each time) but survives the enclosing row's
    /// 60s tick re-renders (so it never replays in place).
    @State private var revealed = false

    private var stateLine: (label: String, tint: Color) {
        switch state {
        case .working: ("WORKING", tokens.text)
        case .blocked: ("NEEDS YOU", Theme.blocked)
        case .waiting: ("UNREAD", tokens.bright)
        case nil:      (((rawStatus?.isEmpty == false ? rawStatus! : "idle").uppercased(), tokens.inactive))
        }
    }

    var body: some View {
        // WHO + WHEN share the state line: "fix-auth · CC turned 2m ago". Empty-but-non-nil
        // fields (probe quirk, same as the cwd guard below) must not leave a dangling " · ".
        let whoWhen = [ccName, age].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
        VStack(alignment: .leading, spacing: 3) {
            // The rule draws left→right — the expansion's one signature beat.
            Rectangle().fill(tokens.rule).frame(height: 1)
                .scaleEffect(x: revealed ? 1 : 0.001, anchor: .leading)
                .animation(.smooth(duration: 0.3).delay(0.02), value: revealed)
                .padding(.bottom, 2)
            line(0, label: stateLine.label, tint: stateLine.tint, value: whoWhen)
            // Empty-but-non-nil cwd (probe quirk) must not render a dangling DIR label —
            // the old tooltip's `.filter { !$0.isEmpty }` did this job.
            if let cwd, !cwd.isEmpty {
                line(1, label: "DIR", tint: tokens.inactive, value: cwd)
            }
            line(cwd?.isEmpty == false ? 2 : 1, label: "ZMX",
                 tint: zmxState == nil ? tokens.inactive : tokens.text,
                 value: "\(session) @ \(host)" + (zmxState.map { " · \($0.lowercased())" } ?? ""))
        }
        .padding(.top, 5).padding(.bottom, 6)
        .onAppear { revealed = true }
    }

    /// One label/value ledger line. Labels are small caps (same typographic role as the CC
    /// session name in `ccLine` — identity-ish, not content); values stay secondary so the
    /// ledger never competes with the unread status text above it.
    private func line(_ i: Int, label: String, tint: Color, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(forkMono(9.5, .semibold, fontFamily)).kerning(0.8)
                .foregroundStyle(tint)
                // lineLimit, not wrap: a wide window-title-font face can push "NEEDS YOU"
                // (or a raw probe status) past the column — truncate, never two-line.
                .lineLimit(1)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(forkMono(11, .regular, fontFamily))
                .foregroundStyle(tokens.text)
                .lineLimit(1).truncationMode(.middle)
        }
        // Cascade: each line fades in and settles down 4pt, 45ms apart — one orchestrated
        // reveal rather than a block pop. Exit has no per-line animation (the whole peek
        // fades as one under `Theme.settle`).
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed ? 0 : -4)
        .animation(.smooth(duration: 0.25).delay(0.07 + Double(i) * 0.045), value: revealed)
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

/// One square lamp per fact about a session. Replaces four separate carriers — the right-edge
/// rail, the liveness symbols, the watch eye and the collapsed-header dot — with one shape in
/// one place, so the right edge reads as a column and there is a single encoding to learn:
/// filled = wants your eyes, outline = armed or in progress, gray = nobody home. The kinds differ
/// in *shape*, never in hue alone: on a theme whose text is already black or white,
/// `text` and `bright` are the same color.
/// `PaneMachine.dot` is still the single source of truth for the first three
/// (probe `status` feeds it via `.probe(busy:)`), so `tempo`-vs-`status` can't render
/// contradictory indicators on one row.
struct Lamp: View {
    enum Kind: Equatable {
        case unlit, working, finished, blocked, detached, ended, unresponsive, watching
    }
    static let size: CGFloat = 10

    @Environment(\.forkTokens) private var tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: Kind

    init(_ kind: Kind) { self.kind = kind }
    init(_ state: PaneState) {
        switch state {
        case .working: kind = .working
        case .waiting: kind = .finished
        case .blocked: kind = .blocked
        }
    }

    var body: some View {
        Group {
            switch kind {
            case .unlit: Rectangle().strokeBorder(tokens.rule, lineWidth: 1)
            case .finished: Rectangle().fill(tokens.bright)
            // Steady, not blinking: with several agents blocked at once a column of flashing
            // red is the wall of alarm the plain question text was chosen to avoid.
            case .blocked: Rectangle().fill(Theme.blocked)
            case .working:
                Rectangle().strokeBorder(tokens.text, lineWidth: 1)
                    .overlay(alignment: .leading) { filling.padding(1) }
            case .detached:
                HStack(spacing: 2) {
                    tokens.inactive.frame(width: 3)
                    tokens.inactive.frame(width: 3)
                }
            case .ended:
                Hatch(pitch: 3).stroke(tokens.inactive, lineWidth: 1).clipped()
                    .overlay(Rectangle().strokeBorder(tokens.inactive, lineWidth: 1))
            case .unresponsive: Rectangle().strokeBorder(Theme.blocked, lineWidth: 1)
            case .watching:
                Rectangle().strokeBorder(tokens.text, lineWidth: 1)
                    .overlay(tokens.text.frame(width: 4, height: 4))
            }
        }
        .frame(width: Self.size, height: Self.size)
    }

    /// The only motion in the sidebar: the lamp fills left to right in eight steps a second,
    /// like a block cursor walking ▏▎▍▌▋▊▉█. Stepped off the wall clock rather than animated,
    /// so every busy lamp is in phase and a re-render can't restart it. Mounted only while
    /// working.
    @ViewBuilder private var filling: some View {
        let full = Self.size - 2
        if reduceMotion {
            tokens.text.frame(width: full / 2)
        } else {
            TimelineView(.periodic(from: .now, by: 0.125)) { ctx in
                let step = Int(ctx.date.timeIntervalSinceReferenceDate * 8) % 8 + 1
                tokens.text.frame(width: full * CGFloat(step) / 8)
            }
        }
    }
}

/// The hidden sidebar's way back: the toolbar's own key cap, where the toolbar's first key
/// was. (It used to be a bare `sidebar.left` symbol — the last of the icon toolbar, and the
/// only thing on screen once the sidebar was gone.) Floats over the terminal, which is why
/// `KeyCap` fills with `ground` rather than nothing.
struct SidebarRevealKey: View {
    let fontFamily: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            KeyCap(label: "SHOW", font: forkMono(10, .regular, fontFamily)).frame(width: 48)
        }
        .buttonStyle(.plain)
        .help("Show sidebar (⌘⇧B)")
    }
}

/// A toolbar key's face. Separate from the `Button` that usually wraps it because the focus
/// key can't be one (see `header`).
struct KeyCap: View {
    @Environment(\.forkTokens) private var tokens
    let label: String
    var on = false
    let font: Font
    @State private var hovered = false
    var body: some View {
        Text(label).font(font).kerning(0.4).lineLimit(1).minimumScaleFactor(0.75)
            .foregroundStyle(on ? tokens.ground : tokens.text)
            .padding(.horizontal, 3).frame(maxWidth: .infinity).frame(height: 22)
            .background(on ? tokens.text : tokens.ground, in: Chamfer(cut: 5))
            .overlay(Chamfer(cut: 5).strokeBorder(hovered ? tokens.bright : tokens.text, lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

private struct HoverHighlight: ViewModifier {
    @Environment(\.forkTokens) private var tokens
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .background(hovered ? tokens.rule : .clear)
            .onHover { hovered = $0 }
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

/// Split-pebble host marker. Hard-stop gradient at 0.5 for a clean half; same-color stops
/// render solid (diagonal-slot case — first N hosts) so no `a==b` branch needed. The slot
/// also seeds `Pebble`, so each host's dot has its own slightly-irregular silhouette —
/// shape becomes a second recognition cue alongside the color pair.
struct HostDot: View {
    @Environment(\.forkTokens) private var tokens

    let slot: Int
    var size: CGFloat = 10
    /// The sidebar's cut: same color pair, plain square. The sheets keep the pebble.
    var square = false

    init(slot: Int, size: CGFloat = 10) { self.slot = slot; self.size = size }
    /// nil → secondary placeholder dot (focus-mode badge for an unknown host).
    init(host: ForkHost?, size: CGFloat = 10, square: Bool = false) {
        self.slot = host?.slot ?? -1; self.size = size; self.square = square
    }

    /// The dot's silhouette — selection rings overlay this same shape so they hug the pebble
    /// outline. Keep the slot→seed mapping here only.
    static func outline(slot: Int) -> Pebble { Pebble(seed: slot) }

    var body: some View {
        let (a, b) = ForkHost.pair(slot)
        (square ? AnyShape(Rectangle()) : AnyShape(Self.outline(slot: slot)))
            .fill(slot < 0 ? AnyShapeStyle(tokens.textSecondary) : AnyShapeStyle(LinearGradient(
                stops: [.init(color: tokens.hostColor(a), location: 0.5),
                        .init(color: tokens.hostColor(b), location: 0.5)],
                startPoint: .leading, endPoint: .trailing)))
            .frame(width: size, height: size)
    }
}
#endif
