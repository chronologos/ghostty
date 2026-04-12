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
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                    ForEach(registry.hosts) { host in
                        hostSection(host)
                    }
                }
                .padding(.vertical, 8)
            }
            Divider()
            footer
        }
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func hostSection(_ host: ForkHost) -> some View {
        let tabs = registry.tabs(on: host.id)
        Button { registry.setExpanded(host.id, !host.expanded) } label: {
            HStack(spacing: 8) {
                Rectangle().fill(accent(for: host.id)).frame(width: 3, height: 14)
                Circle()
                    .fill(registry.isConnected(host.id) ? olive : .secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(host.label).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(tabs.count)").font(.system(size: 10)).foregroundStyle(.secondary)
                Image(systemName: host.expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .buttonStyle(.plain)

        if host.expanded {
            ForEach(tabs) { tab in tabRow(tab) }
        }
    }

    @ViewBuilder
    private func tabRow(_ tab: TabModel) -> some View {
        let active = tab.id == registry.activeTabID
        let renaming = renamingTab == tab.id
        HStack(spacing: 8) {
            Rectangle().fill(active ? clay : .clear).frame(width: 3)
            if renaming {
                TextField("", text: $renameText, onCommit: commitRename)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .onExitCommand { renamingTab = nil }
            } else {
                Text(tab.title).font(.system(size: 12)).lineLimit(1)
            }
            Spacer()
            Button { controller?.closeForkTab(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain).opacity(active ? 0.6 : 0)
        }
        .padding(.leading, 16).padding(.trailing, 12).frame(height: 32)
        .background(active ? clay.opacity(0.12) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginRename(tab) }
        .onTapGesture { controller?.activate(tab: tab.id) }
        .contextMenu {
            Button("Rename…") { beginRename(tab) }
            Button("Close Tab") { controller?.closeForkTab(tab.id) }
        }
    }

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

    private var footer: some View {
        HStack {
            Button { controller?.showNewSessionSheet() } label: {
                Label("New Session", systemImage: "plus").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func accent(for id: String) -> Color {
        let h = id.utf8.reduce(UInt32(2166136261)) { ($0 &* 16777619) ^ UInt32($1) }
        return Color(hue: Double(h % 360) / 360, saturation: 0.45, brightness: 0.7)
    }
}
#endif
