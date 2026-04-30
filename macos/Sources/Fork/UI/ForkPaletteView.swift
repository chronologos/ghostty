#if os(macOS)
import SwiftUI

private extension SessionRegistry {
    /// Every (tab, host, paneIndex, ref) across all hosts — shared by ⌘K and ⌘⇧K.
    var allPanes: [(tab: TabModel, host: ForkHost, index: Int, ref: SessionRef)] {
        tabs.flatMap { tab -> [(TabModel, ForkHost, Int, SessionRef)] in
            guard let host = host(id: tab.hostID) else { return [] }
            return tab.tree.leafRefs.enumerated().map { (tab, host, $0.offset, $0.element) }
        }
    }
}

/// ⌘K — fuzzy-find any pane (across all hosts/tabs) by label / session id / tab title
/// and jump to it. Reuses upstream's `CommandPaletteView` for match + ↑↓⏎ nav.
struct ForkPanePalette: View {
    weak var controller: ForkWindowController?
    let onDone: () -> Void
    @EnvironmentObject private var registry: SessionRegistry
    @State private var isPresented = true

    var body: some View {
        CommandPaletteView(isPresented: $isPresented, options: options)
            .frame(width: 560, height: 400)
            .onChange(of: isPresented) { if !$0 { onDone() } }
    }

    private var options: [CommandOption] {
        registry.allPanes.map { p in
            CommandOption(
                title: p.tab.paneLabels[p.ref.key] ?? p.ref.name,
                subtitle: "\(p.tab.title) · \(p.host.label)",
                leadingColor: p.host.accent,
                badge: p.tab.paneTags[p.ref.key]?.text
            ) { [weak controller, id = p.tab.id, i = p.index] in
                controller?.activate(tab: id, paneIndex: i)
            }
        }
    }
}

/// ⌘⇧K — grep `zmx history` of every session for a string; click to jump.
/// Match is client-side `contains` on the fetched buffer — `controlArgv` stays
/// argv-only so user input never touches a shell (CLAUDE.md security boundary).
struct ScrollbackSearchView: View {
    weak var controller: ForkWindowController?
    let onDone: () -> Void
    @EnvironmentObject private var registry: SessionRegistry
    @State private var query = ""
    @State private var hits: [Hit] = []
    @State private var searching = false
    @State private var generation = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var debounce: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    struct Hit: Identifiable {
        let id = UUID()
        let tabID: TabModel.ID
        let paneIndex: Int
        let label: String
        let crumb: String
        let accent: Color
        let snippet: String
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary)
                TextField("Search scrollback (all sessions)…", text: $query)
                    .textFieldStyle(.plain).focused($fieldFocused).onSubmit(search)
                    .onChange(of: query) { _ in
                        debounce?.cancel()
                        debounce = Task {
                            try? await Task.sleep(for: .milliseconds(300))
                            if !Task.isCancelled { search() }
                        }
                    }
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(hits) { hit in
                        Button {
                            onDone()
                            controller?.activate(tab: hit.tabID, paneIndex: hit.paneIndex)
                        } label: {
                            HStack(spacing: 8) {
                                Circle().fill(hit.accent).frame(width: 6, height: 6)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(hit.label).font(.system(size: 12, weight: .medium))
                                        Text(hit.crumb).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    Text(hit.snippet)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !searching && hits.isEmpty && !query.isEmpty {
                Text("No matches").font(.system(size: 11)).foregroundStyle(.secondary).padding()
            }
        }
        .frame(width: 600, height: 420)
        .onAppear { fieldFocused = true }
        .onExitCommand { debounce?.cancel(); searchTask?.cancel(); onDone() }
    }

    private func search() {
        searchTask?.cancel()
        hits = []
        generation += 1
        let gen = generation
        let q = query
        guard !q.isEmpty else { searching = false; return }
        debounce?.cancel()
        let targets = registry.allPanes
        searching = true
        searchTask = Task {
            await withTaskGroup(of: Hit?.self) { group in
                for p in targets {
                    group.addTask {
                        guard let buf = try? await ZmxAdapter.history(host: p.host, ref: p.ref),
                              let line = buf.split(separator: "\n")
                                  .last(where: { $0.localizedCaseInsensitiveContains(q) })
                        else { return nil }
                        return Hit(
                            tabID: p.tab.id, paneIndex: p.index,
                            label: p.tab.paneLabels[p.ref.key] ?? p.ref.name,
                            crumb: "· \(p.tab.title) · \(p.host.label)",
                            accent: p.host.accent,
                            snippet: String(line).trimmingCharacters(in: .whitespaces)
                        )
                    }
                }
                for await hit in group {
                    if Task.isCancelled { break }
                    if let hit { await MainActor.run { if gen == generation { hits.append(hit) } } }
                }
            }
            await MainActor.run { if gen == generation { searching = false } }
        }
    }
}
#endif
