#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// Left sidebar: hosts as collapsible sections, tabs as rows (SPEC §9).
struct SidebarView: View {
    weak var controller: ForkWindowController?
    @EnvironmentObject private var registry: SessionRegistry
    @State private var renameText: String = ""
    @State private var draggingTab: TabModel.ID?
    @State private var hoveredPane: (TabModel.ID, Int)?
    @State private var tagging: (tab: TabModel.ID, index: Int)?
    @FocusState private var renameFieldFocused: Bool
    @AppStorage("forkSidebarCompact") private var compact = false

    private let clay = Color(red: 0xD9/255, green: 0x77/255, blue: 0x57/255)

    private var recentTags: ArraySlice<PaneTag> { registry.recentTags.prefix(5) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(registry.hosts) { host in
                        hostSection(host)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(.ultraThinMaterial)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 2) {
            actionRow(icon: "plus", label: "New tab", keys: ["⌘", "T"]) {
                controller?.showNewSessionSheet()
            }
            actionRow(icon: "server.rack", label: "Add host", keys: nil) {
                controller?.showNewHostSheet()
            }
            actionRow(icon: "sidebar.left", label: "Hide sidebar", keys: nil) {
                controller?.toggleSidebar()
            }
            actionRow(icon: compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                      label: compact ? "Show details" : "Hide details", keys: nil) {
                withAnimation(.snappy(duration: 0.12)) { compact.toggle() }
            }
        }
        .padding(6)
    }

    private func actionRow(icon: String, label: String, keys: [String]?,
                           perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 11))
                    .foregroundStyle(.secondary).frame(width: 14)
                Text(label).font(.system(size: 12))
                Spacer()
                if let keys { kbd(keys) }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverHighlight())
    }

    private func kbd(_ keys: [String]) -> some View {
        HStack(spacing: 2) {
            ForEach(keys, id: \.self) { k in
                Text(k)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(minWidth: 12)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 3))
            }
        }
    }

    // MARK: Host section

    @ViewBuilder
    private func hostSection(_ host: ForkHost) -> some View {
        let tabs = registry.tabs(on: host.id)
        let connected = registry.isConnected(host.id)

        Button {
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

        if host.expanded && !tabs.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(tabs) { tab in tabRow(tab) }
            }
            .padding(6)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5))
            .padding(.horizontal, 8)
            .transition(.opacity)
        }
    }

    // MARK: Tab → pane rows
    // Each row's label is `paneLabels[ref.key]` (persisted, ⌘I) › `surface.title` (OSC, live)
    // › `ref.name`, with `ref.name` as subtitle when the label differs. `tab.title` is a heading
    // above the group, shown only when it diverges from the first session name (⌘⇧I edits it).
    // Cold-restored tabs have no live surfaces until first activated.

    private func tabRow(_ tab: TabModel) -> some View {
        let active = tab.id == registry.activeTabID
        let refs = tab.tree.leafRefs
        let surfaces = controller?.surfaces(for: tab.id) ?? []
        let renaming = registry.renaming == .tab(tab.id)
        let heading = renaming || tab.collapsed || tab.title != refs.first?.name
        return VStack(alignment: .leading, spacing: 0) {
            if heading {
                tabHeading(tab, renaming: renaming, active: active, paneCount: refs.count)
            }
            if !tab.collapsed {
                ForEach(Array(refs.enumerated()), id: \.offset) { i, ref in
                    paneRow(tab, index: i, ref: ref,
                            surface: i < surfaces.count ? surfaces[i] : nil,
                            spine: refs.count > 1 ? (i == 0, i == refs.count - 1) : nil,
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
        HStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.15)) {
                    registry.setCollapsed(tab.id, !tab.collapsed)
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(tab.collapsed ? 0 : 90))
                    .frame(width: 14, alignment: .leading)
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
        .onTapGesture { controller?.activate(tab: tab.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename(tab) })
        .contextMenu {
            Button("Rename Tab…") { beginRename(tab) }
            Button(tab.collapsed ? "Expand Panes" : "Minimize Panes") {
                registry.setCollapsed(tab.id, !tab.collapsed)
            }
            Button("Close Tab") { controller?.closeForkTab(tab.id) }
        }
    }

    private func paneRow(_ tab: TabModel, index: Int, ref: SessionRef,
                         surface: Ghostty.SurfaceView?,
                         spine: (first: Bool, last: Bool)?, active: Bool) -> some View {
        let focused = active && (registry.focusedPaneIndex.map { $0 == index } ?? (index == 0))
        let age = focused ? nil : tab.lastActive[ref.key]
        let hovered = hoveredPane.map { $0 == (tab.id, index) } ?? false
        let userLabel = tab.paneLabels[ref.key]
        let tag = tab.paneTags[ref.key]
        let renaming = registry.renaming == .pane(tab.id, name: ref.key)
        return HStack(spacing: 0) {
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
            if let tag {
                Text(tag.text)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color(hue: tag.hue, saturation: 0.6, brightness: 0.5),
                                in: RoundedRectangle(cornerRadius: 3))
                    .padding(.trailing, 6)
            }
            if active && index == 0 {
                Button { controller?.kickRedraw(tabID: tab.id) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9))
                }
                .buttonStyle(.plain).opacity(0.5).help("Force redraw all panes")
                Button { controller?.confirmKill(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 9))
                }
                .buttonStyle(.plain).opacity(0.6)
                .help("Kill session(s) and close tab")
            } else if !compact {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(age?.shortAge ?? "")
                        .font(.system(size: 9)).foregroundStyle(ageStyle(age))
                        .frame(width: 24, alignment: .trailing)
                }
            }
        }
        .padding(.trailing, 12).frame(minHeight: 28)
        .background(
            focused ? clay.opacity(0.14) : hovered ? Color.primary.opacity(0.06) : .clear,
            in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredPane = (tab.id, index) }
            else if hovered { hoveredPane = nil }
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
        let t = surface.title
        let label = userLabel ?? (t.isEmpty || t == "👻" ? fallback : t)
        return VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 12)).lineLimit(1)
                .foregroundStyle(active ? .primary : .secondary)
            if !compact && label != fallback {
                Text(fallback).font(.system(size: 9)).lineLimit(1).foregroundStyle(.tertiary)
            }
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
