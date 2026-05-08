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
    @AppStorage("forkSidebarCompact") private var compact = false
    @AppStorage(SessionRegistry.kFilterTagged) private var filterTagged = false
    @AppStorage(SessionRegistry.kFocusMode) private var focusMode = false
    @AppStorage("forkSidebarShowCC") private var showCC = false
    @Environment(\.colorScheme) private var scheme
    /// ⌥-hold peeks the details view (`isCompact` below); ⌥⌥ toggles `compact` itself.
    /// Own monitor (not `navMonitor`) so this stays @State and doesn't churn the registry's
    /// `objectWillChange` → debounce-save on every modifier tap.
    @State private var optionHeld = false
    @State private var lastOptionPress: Date?
    @State private var flagsMonitor: Any?

    private let clay = Color(red: 0xD9/255, green: 0x77/255, blue: 0x57/255)
    private var dark: Bool { scheme == .dark }
    private var fontFamily: String? { controller?.ghostty.config.forkFontFamily }
    private func mono(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { forkMono(s, w, fontFamily) }
    /// Single source for the details view: header button writes `compact`, ⌥-hold transiently
    /// overrides it, ⌥⌥ toggles it. Everything that differs between compact and details
    /// (age column, subtitle, ⌘N/host-label cell, host-header ⌘⌥N) gates on this.
    private var isCompact: Bool { compact && !optionHeld }

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
        // focusMode swaps the entire focusSection ↔ ForEach(hosts) subtree under
        // withAnimation — rows are diffed out without geometry change, so per-row
        // `.onHover(false)` doesn't fire and `hoveredPane` would stay armed.
        .onChange(of: focusMode) { _ in controller?.hoveredPane = nil }
        .onAppear {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { ev in
                // Local monitors are app-wide; QuickTerminal bypasses the fork seam, so
                // ⌥⌥ in its window would otherwise flip our persisted `compact` flag.
                guard ev.window === controller?.window else { return ev }
                let held = ev.modifierFlags.contains(.option)
                if held, !optionHeld {
                    let now = Date()
                    if let last = lastOptionPress, now.timeIntervalSince(last) < 0.4 {
                        compact.toggle()
                        lastOptionPress = nil
                    } else {
                        lastOptionPress = now
                    }
                }
                if held != optionHeld { optionHeld = held }
                return ev
            }
        }
        .onDisappear {
            flagsMonitor.map(NSEvent.removeMonitor); flagsMonitor = nil
            // Stop the singleton's 3s ccPoll loop — `setCCProbeEnabled` cancels the
            // detached `Task`, which `.task`'s own auto-cancel can't (one-shot body
            // returns immediately). Otherwise leaks past last-window close
            // (`shouldQuitAfterLastWindowClosed` defaults false, AppDelegate.swift:1035).
            registry.setCCProbeEnabled(false)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification)) { _ in optionHeld = false }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            iconButton("plus", help: "New tab") { controller?.showNewSessionSheet() }
            iconButton("server.rack", help: "Add host") { controller?.showNewHostSheet() }
            iconButton("sidebar.left", help: "Hide sidebar") { controller?.toggleSidebar() }
            iconButton(compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                       help: compact ? "Show details" : "Hide details") {
                withAnimation(.snappy(duration: 0.12)) { compact.toggle() }
            }
            iconButton(filterTagged ? "tag.fill" : "tag",
                       help: filterTagged ? "Show all" : "Tagged only",
                       tint: filterTagged ? clay : nil) {
                withAnimation(.snappy(duration: 0.12)) { filterTagged.toggle() }
            }
            iconButton("scope",
                       help: focusMode ? "All hosts" : "Focus (recent only)",
                       tint: focusMode ? clay : nil) {
                withAnimation(.snappy(duration: 0.12)) { focusMode.toggle() }
            }
            iconButton("sparkle",
                       help: showCC ? "Hide Claude session names" : "Show Claude session names",
                       tint: showCC ? clay : nil) {
                withAnimation(.snappy(duration: 0.12)) { showCC.toggle() }
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func iconButton(_ icon: String, help: String, tint: Color? = nil,
                            perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: icon).font(.system(size: 12))
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
                Text(filterTagged ? "No tagged panes" : "Nothing in the last 16h")
                    .font(mono(11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.top, 12)
            } else {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { i, tab in
                    HStack(alignment: .top, spacing: 6) {
                        ZStack(alignment: .topTrailing) {
                            // Digit hint takes the badge slot — only fixed-width leading
                            // cell that's never text; a trailing overlay collides with the
                            // age column on tabs without a heading row.
                            if !isCompact, let host = registry.host(id: tab.hostID) {
                                VStack(alignment: .leading, spacing: 2) {
                                    keyHint(i < 9 ? "⌘\(i + 1)" : " ")
                                    Text(host.label)
                                        .font(mono(8)).foregroundStyle(host.accent)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: 56, alignment: .leading)
                            } else {
                                hostBadge(tab.hostID)
                            }
                            if tab.pinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 6)).foregroundStyle(.secondary)
                                    .offset(x: 2, y: 1)
                            }
                        }
                        tabRow(tab)
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: tabs.map(\.id))
    }

    /// Worst-child rollup indicator for collapsed headers (host/tab). Mirrors `paneRow`'s
    /// per-pane switch but without per-pane help text — the parent doesn't know which child.
    @ViewBuilder
    private func stateDot(_ s: PaneState?, accent: Color) -> some View {
        switch s {
        case .blocked: Circle().fill(.red).frame(width: 6, height: 6).help("Blocked — needs input")
        case .waiting: Circle().fill(accent).frame(width: 6, height: 6).help("Finished — unread")
        case .working: ProgressView().controlSize(.mini).scaleEffect(0.6)
        case nil: EmptyView()
        }
    }

    private func keyHint(_ chord: String) -> some View {
        Text(chord)
            .font(mono(8, .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
    }

    private func hostBadge(_ id: ForkHost.ID) -> some View {
        let h = registry.host(id: id)
        return Image(systemName: h?.icon ?? "circle.fill")
            .font(.system(size: 8))
            .foregroundStyle(h?.accent ?? .secondary)
            .frame(width: 12)
            .padding(.top, 5)
            .help(h?.label ?? "")
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
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(host.expanded ? 90 : 0))
                    .frame(width: 10)
                Group {
                    if let icon = host.icon {
                        Image(systemName: icon).font(.system(size: 9, weight: .medium))
                    } else {
                        Circle().frame(width: 6, height: 6)
                    }
                }
                .foregroundStyle(connected ? host.accent : Color.secondary.opacity(0.4))
                .frame(width: 12)
                Text(host.label)
                    .font(mono(12, .medium))
                    .foregroundStyle(connected ? .primary : .secondary)
                Spacer()
                if !host.expanded {
                    stateDot(controller?.rollup(hostID: host.id), accent: host.accent)
                        .padding(.trailing, 6)
                }
                if !isCompact, let i = registry.hosts.firstIndex(where: { $0.id == host.id }), i < 9 {
                    keyHint("⌘⌥\(i + 1)")
                }
                Text("\(tabs.count)").font(mono(10)).foregroundStyle(.secondary)
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
            Button("Manage Host…") { controller?.showHostDetail(host.id) }
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
        .padding(6)
        .background(dark ? Color.black.opacity(0.18)
                         : Color(nsColor: .controlBackgroundColor).opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(Color.secondary.opacity(dark ? 0.15 : 0.1), lineWidth: 0.5))
        .padding(.horizontal, 8)
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
        let accent = registry.host(id: tab.hostID)?.accent ?? Color.secondary
        let toggle = {
            withAnimation(.snappy(duration: 0.15)) {
                registry.setCollapsed(tab.id, !tab.collapsed)
            }
        }
        return HStack(spacing: 0) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(tab.collapsed ? 0 : 90))
                    .frame(width: 14, height: 20, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if renaming {
                renameField(seed: tab.title, font: mono(10, .semibold))
            } else {
                Text(tab.title.uppercased())
                    .font(mono(9, .semibold)).kerning(0.6).lineLimit(1)
                    .foregroundStyle(accent.opacity(active ? 1 : 0.6))
            }
            Spacer()
            if tab.collapsed {
                stateDot(controller?.rollup(tab: tab), accent: accent)
                    .padding(.trailing, 6)
                Text("\(paneCount)").font(mono(9)).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4).padding(.trailing, 12).frame(height: 20)
        .contentShape(Rectangle())
        .onTapGesture {
            if tab.collapsed { toggle() }
            controller?.activate(tab: tab.id)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename(tab) })
        .contextMenu {
            Button("Rename Tab…") { beginRename(tab) }
            Button(tab.pinned ? "Unpin Tab" : "Pin Tab") { registry.setPinned(tab.id, !tab.pinned) }
            if focusMode {
                Button("Hide from Focus") { registry.dismissFromFocus(tab.id) }
            }
            Button(tab.collapsed ? "Expand Panes" : "Minimize Panes") {
                registry.setCollapsed(tab.id, !tab.collapsed)
            }
            mergeIntoMenu(tab)
            Button("Close Tab") { controller?.closeForkTab(tab.id) }
        }
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
        let accent = registry.host(id: tab.hostID)?.accent ?? clay
        // showCC swaps the age column from "when I last focused this pane" to "when CC last
        // turned". `ccLive[].updatedAt` is stale by design (`Info.==` excludes it), so the
        // closure reads the non-@Published `ccUpdatedAt` mirror — fresh on each 30s tick.
        let age = { (showCC ? registry.ccUpdatedAt[tab.hostID]?[ref.key] : nil)
                    ?? (focused ? nil : tab.lastActive[ref.key]) }
        return Hovering { hovered in
            HStack(spacing: 0) {
                Group {
                    if let spine {
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Spine(first: spine.first, last: spine.last)
                                .stroke(active ? spineHeat(tab.lastActive.values.max())
                                               : Color.secondary.opacity(0.3), lineWidth: 1)
                        }
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    if renaming {
                        renameField(seed: userLabel ?? ref.name, font: mono(12))
                    } else if let surface {
                        PaneLabel(surface: surface, userLabel: userLabel, fallback: ref.name,
                                  active: active, compact: isCompact || showCC, fontFamily: fontFamily)
                    } else {
                        Text(userLabel ?? ref.name).font(mono(12)).lineLimit(1)
                            .foregroundStyle(active ? .primary : .secondary)
                    }
                    if showCC {
                        // Replaces PaneLabel's zmx-name subtitle (suppressed via the
                        // `compact || showCC` above) — net zero lines. Fixed-height slot so
                        // focus-mode reorder doesn't gap rows where `ccLine` is empty.
                        ccLine(live: live, cached: tab.ccNames[ref.key], fallback: ref.name)
                            .frame(height: 12, alignment: .topLeading)
                    }
                }
                Spacer()
                switch registry.paneStatus(ref: ref, surfaceID: surface?.id) {
                case .blocked:
                    Circle().fill(.red).frame(width: 6, height: 6)
                        .padding(.trailing, 6)
                        .help(live?.needs ?? live?.waitingFor ?? "Needs your input")
                case .working:
                    ProgressView().controlSize(.mini).scaleEffect(0.6)
                        .padding(.trailing, 4)
                case .waiting:
                    Circle().fill(accent).frame(width: 6, height: 6)
                        .padding(.trailing, 6).help("Finished — unread")
                case nil: EmptyView()
                }
                if let surface, registry.watchedSurfaces.contains(surface.id) {
                    Image(systemName: "eye")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                        .help("Watching — ⌘⌥A to disarm")
                }
                if let tag {
                    let c = Color(hue: tag.hue, saturation: 0.6, brightness: dark ? 0.55 : 0.45)
                    HStack(spacing: 4) {
                        Circle().strokeBorder(c, lineWidth: 1.5)
                            .background(Circle().fill(hovered ? c : .clear))
                            .frame(width: 8, height: 8)
                        if hovered {
                            Text(tag.text).font(mono(8, .medium))
                                .foregroundStyle(c).fixedSize()
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                    }
                    .padding(.horizontal, hovered ? 5 : 0).padding(.vertical, hovered ? 2 : 0)
                    .background(hovered ? c.opacity(0.12) : .clear, in: Capsule())
                    .animation(.snappy(duration: 0.15), value: hovered)
                    .help(tag.text)
                    .padding(.trailing, 6)
                }
                if !isCompact {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        let a = age()
                        Text(a?.shortAge ?? "")
                            .font(mono(9)).foregroundStyle(ageStyle(a))
                            .frame(width: 24, alignment: .trailing)
                    }
                }
            }
            .padding(.trailing, 12).frame(minHeight: 28)
            .background(
                focused ? clay.opacity(dark ? 0.14 : 0.20)
                        : hovered ? Color.primary.opacity(0.06) : .clear,
                in: RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .trailing) {
                // Anchored to the row (not the content flow) so it reads as a right border,
                // not a pill competing with the tag circle for the same slot.
                if showCC {
                    CCStatusRail(status: live?.status, accent: accent)
                        .help(live?.waitingFor ?? "")
                }
            }
            .contentShape(Rectangle())
        }
        .onTapGesture { controller?.activate(tab: tab.id, paneIndex: index) }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            registry.setRenaming(.pane(tab.id, name: ref.key))
        })
        // Adjacent rows in a `VStack(spacing: 0)` can deliver B-enter before A-exit; an
        // unguarded nil here would clear B and leave hover-keys dead while B is still
        // visually highlighted (Hovering wrapper's @State is independent).
        .onHover { entering in
            if entering { controller?.hoveredPane = (tab.id, index, ref, surface?.id) }
            else if let h = controller?.hoveredPane, h.tab == tab.id, h.index == index {
                controller?.hoveredPane = nil
            }
        }
        // `.onHover(false)` doesn't fire when the row is diffed out — `.onDisappear` does.
        // Covers whole-tab removal (collapse/dismiss/close) where every row fires; for
        // single-pane removal the offset-keyed ForEach fires this on the *last* row only,
        // so `handleHoverKey` also guards `ref ∈ tab.tree`.
        .onDisappear {
            if let h = controller?.hoveredPane, h.tab == tab.id, h.index == index {
                controller?.hoveredPane = nil
            }
        }
        .contextMenu { paneContextMenu(tab, ref: ref, tag: tag, surface: surface) }
        .popover(isPresented: Binding(
            get: { registry.taggingPane.map { $0 == (tab.id, ref.key) } ?? false },
            // Only clear shared state if it still points at *this* row — hover-"t" on row B
            // flips row A's getter false, and A's NSPopover-dismiss callback would otherwise
            // race B's open by nilling `taggingPane` from under it.
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
    private func paneContextMenu(_ tab: TabModel, ref: SessionRef, tag: PaneTag?,
                                 surface: Ghostty.SurfaceView?) -> some View {
        // ⌥-right-click appends the bare-letter hover key to items that have one. Read at
        // menu-build time; NSMenu is modal so releasing ⌥ while open won't re-render.
        let hk: (String, String) -> String = { optionHeld ? "\($0)    \($1)" : $0 }
        return Group {
            Section {
                Button("Rename Pane…") { registry.setRenaming(.pane(tab.id, name: ref.key)) }
                Menu("Tag") {
                    ForEach(recentTags, id: \.self) { t in
                        Button { registry.setPaneTag(tab: tab.id, name: ref.key, to: t) } label: {
                            Label(t.text, systemImage: "circle.fill")
                                .foregroundStyle(Color(hue: t.hue, saturation: 0.6, brightness: 0.5))
                        }
                    }
                    if !recentTags.isEmpty { Divider() }
                    Button(hk("New Tag…", "T")) { registry.taggingPane = (tab.id, ref.key) }
                    if tag != nil {
                        Button(hk("Clear Tag", "C")) {
                            registry.setPaneTag(tab: tab.id, name: ref.key, to: nil)
                        }
                    }
                }
                if let surface {
                    Button(registry.watchedSurfaces.contains(surface.id) ? "Stop Watching" : "Watch (⌘⌥A)") {
                        controller?.toggleWatch(on: surface)
                    }
                    Button(hk("Force Repaint", "R")) { forkWigglePane(surface) }
                }
                if registry.ccLive[ref.hostID]?[ref.key]?.sock != nil {
                    Button(hk("Set CC Name to '\(tab.paneLabels[ref.key] ?? ref.name)'", "N")) {
                        controller?.syncCCName(tab: tab, ref: ref)
                    }
                }
            }
            Section {
                Button("Rename Tab…") { beginRename(tab) }
                Button(hk(tab.pinned ? "Unpin Tab" : "Pin Tab", "P")) {
                    registry.setPinned(tab.id, !tab.pinned)
                }
                if focusMode {
                    Button(hk("Hide from Focus", "H")) { registry.dismissFromFocus(tab.id) }
                }
                Button("Minimize Panes") { registry.setCollapsed(tab.id, true) }
                movePaneMenu(tab, ref: ref)
            }
            Section {
                Button("Close Tab") { controller?.closeForkTab(tab.id) }
                Button(hk("Kill This Session…", "K"), role: .destructive) {
                    controller?.confirmKillPane(tab: tab, ref: ref, surface: surface)
                }
                Button("Kill All & Close Tab…", role: .destructive) { controller?.confirmKill(tab) }
            }
        }
    }

    /// CC session name only — status and age live in the right-edge rail and the shared age
    /// column. `live.name` › cached last-seen › cwd basename. Always returns a `Text` (empty
    /// when no label) so the call-site `.frame(height: 12)` actually reserves the slot;
    /// `EmptyView().frame(...)` is a layout no-op.
    private func ccLine(live: CCProbe.Info?, cached: String?, fallback: String) -> some View {
        // cwd basename is only useful when more specific than the pane's own name — an
        // unnamed CC at a shared repo root would read identically on every row.
        let cwdLeaf = live?.cwd
            .map { ($0 as NSString).lastPathComponent }
            .flatMap { $0 == fallback ? nil : $0 }
        // `cached` is for the CC-exited case only; `live?.name` flattens to `String?`, so a
        // running-but-unnamed session would otherwise fall through to the previous session's
        // name and render it in `.secondary` (live) styling.
        return Text(live != nil ? (live?.name ?? cwdLeaf ?? "") : (cached ?? ""))
            .font(mono(9)).lineLimit(1)
            .foregroundStyle(live != nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .help(live?.cwd ?? "")
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

    private func ageStyle(_ date: Date?) -> AnyShapeStyle {
        switch date.map({ Date().timeIntervalSince($0) }) {
        case .some(..<300):  return AnyShapeStyle(.primary)
        case .some(..<3600): return AnyShapeStyle(.secondary)
        default:             return AnyShapeStyle(.tertiary)
        }
    }

    private func spineHeat(_ freshest: Date?) -> Color {
        switch freshest.map({ Date().timeIntervalSince($0) }) {
        case .some(..<300):  return .secondary
        case .some(..<3600): return .secondary.opacity(0.6)
        default:             return .secondary.opacity(0.35)
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
    let compact: Bool
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
            Text(label).font(forkMono(12, .regular, fontFamily)).lineLimit(1)
                .foregroundStyle(active ? .primary : .secondary)
            if !compact && label != fallback {
                Text(fallback).font(forkMono(9, .regular, fontFamily)).lineLimit(1)
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
private struct Hovering<Content: View>: View {
    @State private var hovered = false
    @ViewBuilder let content: (Bool) -> Content
    var body: some View {
        content(hovered).onHover { hovered = $0 }
    }
}

/// Right-edge status pill — reads as a vertical heatmap down the sidebar. Host-accent hue so
/// busy rows also signal *which* host without re-reading the badge. Fixed 3pt slot keeps the
/// age/tag column aligned across rows with no live CC.
private struct CCStatusRail: View {
    let status: String?
    let accent: Color
    var body: some View {
        Group {
            switch status {
            case "busy":    Pulsing { RoundedRectangle(cornerRadius: 1.5).fill(accent) }
            case "waiting": RoundedRectangle(cornerRadius: 1.5).strokeBorder(accent, lineWidth: 1)
            default:        Color.clear
            }
        }
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
            .background(hovered ? Color.primary.opacity(0.06) : .clear,
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
    var accent: Color {
        let hue = accentHue ?? {
            let h = id.utf8.reduce(UInt32(2166136261)) { ($0 &* 16777619) ^ UInt32($1) }
            return Double(h % 360) / 360
        }()
        return Color(hue: hue, saturation: 0.45, brightness: 0.7)
    }
}
#endif
