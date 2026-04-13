#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// Left sidebar: hosts as collapsible sections, tabs as rows (SPEC §9).
struct SidebarView: View {
    weak var controller: ForkWindowController?
    @EnvironmentObject private var registry: SessionRegistry
    @State private var renamingTab: TabModel.ID?
    @State private var renameText: String = ""
    @State private var draggingTab: TabModel.ID?

    private let clay = Color(red: 0xD9/255, green: 0x77/255, blue: 0x57/255)

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
            actionRow(icon: "magnifyingglass", label: "Sessions", keys: ["⌘", "K"]) {
                // SPEC §8 backlog
            }
            actionRow(icon: "server.rack", label: "Add host", keys: nil) {
                controller?.showNewHostSheet()
            }
            actionRow(icon: "sidebar.left", label: "Hide sidebar", keys: ["⌘", "\\"]) {
                controller?.toggleSidebar()
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

        Button { registry.setExpanded(host.id, !host.expanded) } label: {
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
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("New Session on \(host.label)") {
                controller?.newForkTab(intent: .init(hostID: host.id))
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
        }
    }

    // MARK: Tab → pane rows
    // Single-pane: one plain title row. Multi-pane: one row per leaf session,
    // grouped by a spine + elbow connector; tab title is not shown.

    private func tabRow(_ tab: TabModel) -> some View {
        let active = tab.id == registry.activeTabID
        let refs = tab.tree.leafRefs
        return Group {
            if refs.count <= 1 {
                paneRow(tab, index: 0, label: tab.title, spine: nil, head: true, active: active)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(refs.enumerated()), id: \.offset) { i, ref in
                        paneRow(tab, index: i, label: ref.name,
                                spine: (i == 0, i == refs.count - 1),
                                head: i == 0, active: active)
                    }
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

    private func paneRow(_ tab: TabModel, index: Int, label: String,
                         spine: (first: Bool, last: Bool)?, head: Bool,
                         active: Bool) -> some View {
        let renaming = head && renamingTab == tab.id
        return HStack(spacing: 0) {
            Group {
                if let spine {
                    Spine(first: spine.first, last: spine.last)
                        .stroke(active ? clay : Color.secondary.opacity(0.3), lineWidth: 1)
                } else {
                    Color.clear
                }
            }
            .frame(width: 14)
            if renaming {
                TextField("", text: $renameText, onCommit: commitRename)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .onExitCommand { renamingTab = nil }
            } else {
                Text(label).font(.system(size: 12)).lineLimit(1)
                    .foregroundStyle(active ? .primary : .secondary)
            }
            Spacer()
            if head {
                Button { controller?.kickRedraw(tabID: tab.id) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9))
                }
                .buttonStyle(.plain).opacity(active ? 0.5 : 0).allowsHitTesting(active)
                .help("Force redraw all panes")
                Button { controller?.closeForkTab(tab.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9))
                }
                .buttonStyle(.plain).opacity(active ? 0.6 : 0).allowsHitTesting(active)
            }
        }
        .padding(.trailing, 12).frame(height: 28)
        .background(active && (registry.focusedPaneIndex.map { $0 == index } ?? head)
                        ? clay.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { controller?.activate(tab: tab.id, paneIndex: index) }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if head { beginRename(tab) }
        })
        .contextMenu {
            if head { Button("Rename…") { beginRename(tab) } }
            Button("Close Tab") { controller?.closeForkTab(tab.id) }
            Divider()
            Button("Kill Session…", role: .destructive) { controller?.confirmKill(tab) }
        }
    }

    // MARK: -

    private func beginRename(_ tab: TabModel) {
        renameText = tab.title
        renamingTab = tab.id
    }

    private func commitRename() {
        if let id = renamingTab, !renameText.isEmpty {
            registry.renameTab(id, to: renameText)
        }
        renamingTab = nil
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
