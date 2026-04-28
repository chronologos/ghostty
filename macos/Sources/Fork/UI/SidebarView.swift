#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// Left sidebar: hosts as collapsible sections, tabs as rows (SPEC §9).
struct SidebarView: View {
    weak var controller: ForkWindowController?
    @EnvironmentObject private var registry: SessionRegistry
    @State private var renameText: String = ""
    @State private var draggingTab: TabModel.ID?
    @State private var tagging: (tab: TabModel.ID, index: Int)?
    @FocusState private var renameFieldFocused: Bool
    @AppStorage("forkSidebarCompact") private var compact = false
    @AppStorage("forkSidebarFilterTagged") private var filterTagged = false
    @AppStorage("forkSidebarFocus") private var focusMode = false
    @Environment(\.colorScheme) private var scheme

    private let clay = Color(red: 0xD9/255, green: 0x77/255, blue: 0x57/255)
    private var dark: Bool { scheme == .dark }

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
    // `filterTagged` composes: off → last-8h; on → tagged-only, no time cutoff.

    private var focusTabs: [TabModel] {
        let cutoff = Date().addingTimeInterval(-8 * 3600)
        let tagged = filterTagged
        let active = registry.activeTabID
        // `newTab` synchronously publishes with `lastActive == [:]` before async focus
        // settlement fires `touchPane`; treat active as `.distantFuture` so it both
        // passes the cutoff and sorts first instead of flashing at the bottom.
        func mru(_ t: TabModel) -> Date {
            t.id == active ? .distantFuture : (t.lastActive.values.max() ?? .distantPast)
        }
        return registry.tabs
            .filter { $0.id == active || (tagged ? !$0.paneTags.isEmpty : mru($0) > cutoff) }
            .sorted { mru($0) > mru($1) }
    }

    private var focusSection: some View {
        let tabs = focusTabs
        // Own VStack so `.animation(value:)` sees the row positions it lays out;
        // attaching to the outer body VStack would also animate host-mode reflow.
        return VStack(alignment: .leading, spacing: 4) {
            if tabs.isEmpty {
                Text(filterTagged ? "No tagged panes" : "Nothing in the last 8h")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.top, 12)
            } else {
                ForEach(tabs) { tabRow($0).padding(.horizontal, 8) }
            }
        }
        .animation(.snappy(duration: 0.2), value: tabs.map(\.id))
    }

    // MARK: Host section

    @ViewBuilder
    private func hostSection(_ host: ForkHost) -> some View {
        let allTabs = registry.tabs(on: host.id)
        let tabs = filterTagged ? allTabs.filter(tabHasTag) : allTabs
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
                Circle()
                    .fill(connected ? ForkHost.accent(for: host) : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(host.label)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(connected ? .primary : .secondary)
                Spacer()
                Text("\(tabs.count)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverHighlight())
        .padding(.horizontal, 8)
        .contextMenu {
            Button("New Session on \(host.label)…") {
                controller?.showSessionPicker(on: host)
            }
            Button("Manage Host…") { controller?.showHostDetail(host) }
            if host.id != ForkHost.local.id {
                Divider()
                Button("Remove Host", role: .destructive) {
                    controller?.removeHost(host.id)
                }
            }
        }
    }

    private func hostBody(tabs: [TabModel]) -> some View {
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

    /// True if any pane in this tab has a tag assigned. Used by the `filterTagged` toggle.
    private func tabHasTag(_ tab: TabModel) -> Bool {
        tab.tree.leafRefs.contains { tab.paneTags[$0.key] != nil }
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
                    paneRow(tab, index: i, ref: ref,
                            surface: i < surfaces.count ? surfaces[i] : nil,
                            spine: allRefs.count > 1 ? (i == 0, i == allRefs.count - 1) : nil,
                            active: active)
                }
            }
        }
        .onDrag {
            draggingTab = tab.id
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(
            target: tab.id, dragging: $draggingTab, registry: registry))
    }

    private func tabHeading(_ tab: TabModel, renaming: Bool, active: Bool,
                            paneCount: Int) -> some View {
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
                renameField(seed: tab.title, font: .system(size: 10, weight: .semibold))
            } else {
                Text(tab.title.uppercased())
                    .font(.system(size: 9, weight: .semibold)).kerning(0.6).lineLimit(1)
                    .foregroundStyle(clay.opacity(active ? 1 : 0.6))
            }
            Spacer()
            if tab.collapsed {
                Text("\(paneCount)").font(.system(size: 9)).foregroundStyle(.tertiary)
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
        let age = focused ? nil : tab.lastActive[ref.key]
        let userLabel = tab.paneLabels[ref.key]
        let tag = tab.paneTags[ref.key]
        let renaming = registry.renaming == .pane(tab.id, name: ref.key)
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
                if renaming {
                    renameField(seed: userLabel ?? ref.name, font: .system(size: 12))
                } else if let surface {
                    PaneLabel(surface: surface, userLabel: userLabel, fallback: ref.name,
                              active: active, compact: compact)
                } else {
                    Text(userLabel ?? ref.name).font(.system(size: 12)).lineLimit(1)
                        .foregroundStyle(active ? .primary : .secondary)
                }
                Spacer()
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
                            Text(tag.text).font(.system(size: 8, weight: .medium))
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
                if !compact {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(age?.shortAge ?? "")
                            .font(.system(size: 9)).foregroundStyle(ageStyle(age))
                            .frame(width: 24, alignment: .trailing)
                    }
                }
            }
            .padding(.trailing, 12).frame(minHeight: 28)
            .background(
                focused ? clay.opacity(dark ? 0.14 : 0.20)
                        : hovered ? Color.primary.opacity(0.06) : .clear,
                in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .onTapGesture { controller?.activate(tab: tab.id, paneIndex: index) }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            registry.setRenaming(.pane(tab.id, name: ref.key))
        })
        .contextMenu {
            Button("Rename Pane…") { registry.setRenaming(.pane(tab.id, name: ref.key)) }
            Button("Rename Tab…") { beginRename(tab) }
            Divider()
            ForEach(recentTags, id: \.self) { t in
                Button { registry.setPaneTag(tab: tab.id, name: ref.key, to: t) } label: {
                    Label(t.text, systemImage: "circle.fill")
                        .foregroundStyle(Color(hue: t.hue, saturation: 0.6, brightness: 0.5))
                }
            }
            Button("Tag…") { tagging = (tab.id, index) }
            if tag != nil {
                Button("Clear Tag") { registry.setPaneTag(tab: tab.id, name: ref.key, to: nil) }
            }
            Divider()
            movePaneMenu(tab, ref: ref)
            if let surface {
                Button(controller?.isWatching(surface) == true ? "Stop Watching" : "Watch (⌘⌥A)") {
                    controller?.toggleWatch(on: surface)
                }
                Button("Force Repaint") { forkWigglePane(surface) }
            }
            Button("Minimize Panes") { registry.setCollapsed(tab.id, true) }
            Button("Close Tab") { controller?.closeForkTab(tab.id) }
            Button("Kill This Session…", role: .destructive) {
                controller?.confirmKillPane(tab: tab, ref: ref, surface: surface)
            }
            Button("Kill All & Close Tab…", role: .destructive) { controller?.confirmKill(tab) }
        }
        .popover(isPresented: Binding(
            get: { tagging.map { $0 == (tab.id, index) } ?? false },
            set: { if !$0 { tagging = nil } }
        ), arrowEdge: .trailing) {
            TagEditView(seed: tag) {
                registry.setPaneTag(tab: tab.id, name: ref.key, to: $0)
                tagging = nil
            }
        }
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
        case .some(..<300):  return AnyShapeStyle(clay)
        case .some(..<3600): return AnyShapeStyle(.secondary)
        default:             return AnyShapeStyle(.tertiary)
        }
    }

    private func spineHeat(_ freshest: Date?) -> Color {
        switch freshest.map({ Date().timeIntervalSince($0) }) {
        case .some(..<300):  return clay
        case .some(..<3600): return clay.opacity(0.6)
        default:             return clay.opacity(0.35)
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
    var body: some View {
        // Upstream's `titleFallbackTimer` sets `"👻"` after 500ms if no OSC title arrived
        // (SurfaceView_AppKit.swift:323) — treat it as "no title" so the session name shows.
        // A path-shaped title (OMZ-style `%n@%m:%~`, `$PWD`, `~/…`) also counts as no-title:
        // the user wants the zmx session id, not whatever the shell reports as cwd.
        let t = surface.title
        let isPathish = t.hasPrefix("/") || t.hasPrefix("~") || t.contains(":/") || t.contains(":~")
        let label = userLabel ?? (t.isEmpty || t == "👻" || isPathish ? fallback : t)
        return VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 12)).lineLimit(1)
                .foregroundStyle(active ? .primary : .secondary)
            if !compact && label != fallback {
                Text(fallback).font(.system(size: 9)).lineLimit(1).foregroundStyle(.tertiary)
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

private struct TabDropDelegate: DropDelegate {
    let target: TabModel.ID
    @Binding var dragging: TabModel.ID?
    let registry: SessionRegistry

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            registry.moveTab(dragging, before: target)
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { .init(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

extension ForkHost {
    static func accent(for host: ForkHost) -> Color {
        let hue = host.accentHue ?? {
            let h = host.id.utf8.reduce(UInt32(2166136261)) { ($0 &* 16777619) ^ UInt32($1) }
            return Double(h % 360) / 360
        }()
        return Color(hue: hue, saturation: 0.45, brightness: 0.7)
    }
}
#endif
