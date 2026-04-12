#if os(macOS)
import SwiftUI

/// Left sidebar: hosts as collapsible sections, tabs as rows (SPEC §9).
struct SidebarView: View {
    weak var controller: ForkWindowController?
    @EnvironmentObject private var registry: SessionRegistry
    @State private var renamingTab: TabModel.ID?
    @State private var renameText: String = ""

    private let clay = Color(red: 0xD9/255, green: 0x77/255, blue: 0x57/255)
    private let olive = Color(red: 0x7F/255, green: 0xA8/255, blue: 0x6B/255)

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
                    .fill(connected ? olive : Color.secondary.opacity(0.4))
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
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle().fill(accent(for: host.id)).frame(width: 2)
            }
            .padding(.leading, 10)
        }
    }

    // MARK: Tab row

    @ViewBuilder
    private func tabRow(_ tab: TabModel) -> some View {
        let active = tab.id == registry.activeTabID
        let renaming = renamingTab == tab.id
        let panes = tab.tree.paneCount
        HStack(spacing: 8) {
            Rectangle().fill(active ? clay : .clear).frame(width: 3)
            if renaming {
                TextField("", text: $renameText, onCommit: commitRename)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .onExitCommand { renamingTab = nil }
            } else {
                Text(tab.title).font(.system(size: 12)).lineLimit(1)
                    .foregroundStyle(active ? .primary : .secondary)
            }
            Spacer()
            if panes > 1 {
                Text("\(panes)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 3))
            }
            Button { controller?.closeForkTab(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain).opacity(active ? 0.6 : 0)
        }
        .padding(.trailing, 12).frame(height: 30)
        .background(active ? clay.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .padding(.trailing, 6)
        .contentShape(Rectangle())
        .onTapGesture { controller?.activate(tab: tab.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename(tab) })
        .contextMenu {
            Button("Rename…") { beginRename(tab) }
            Button("Close Tab") { controller?.closeForkTab(tab.id) }
            Divider()
            Button("Kill Session…", role: .destructive) { controller?.confirmKill(tab) }
        }
        if active && panes > 1 {
            MinimapView(tree: tab.tree)
                .padding(.leading, 12).padding(.trailing, 12).padding(.bottom, 4)
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

    private func accent(for id: String) -> Color {
        let h = id.utf8.reduce(UInt32(2166136261)) { ($0 &* 16777619) ^ UInt32($1) }
        return Color(hue: Double(h % 360) / 360, saturation: 0.45, brightness: 0.7)
    }
}
#endif
