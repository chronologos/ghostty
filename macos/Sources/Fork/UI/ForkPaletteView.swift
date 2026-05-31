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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: isPresented) { if !$0 { onDone() } }
    }

    private var options: [CommandOption] {
        var out: [CommandOption] = []
        // Action entries (replaced the built-in bare-letter hover keys). Only when the
        // referent exists — `controller` is weak and `focusedSurface` is nil for cold tabs.
        if let s = controller?.focusedSurface {
            out.append(.init(title: "Force Repaint Pane", symbols: ["⌘", "⇧", "R"],
                             leadingIcon: "arrow.clockwise") { forkWigglePane(s) })
        }
        if let id = registry.activeTabID, let t = registry.tabs.first(where: { $0.id == id }) {
            out.append(.init(title: t.pinned ? "Unpin Tab" : "Pin Tab",
                             symbols: ["⌘", "⌥", "P"], leadingIcon: "pin") {
                SessionRegistry.shared.setPinned(id, !t.pinned)
            })
        }
        // User-defined pane commands (`fork.json` hoverCommands) — run on the focused pane.
        // Replaces bare-letter hover dispatch entirely.
        for (key, hc) in registry.hoverCommands.sorted(by: { $0.key < $1.key })
            where controller?.focusedSurface != nil {
            out.append(.init(title: hc.cmd.first ?? key,
                             subtitle: hc.cmd.dropFirst().joined(separator: " "),
                             leadingIcon: "terminal", badge: hc.mode.rawValue) {
                [weak controller] in controller?.runPaneCommand(hc)
            })
        }
        out += registry.allPanes.map { p in
            CommandOption(
                title: p.tab.paneLabels[p.ref.key] ?? p.ref.name,
                subtitle: "\(p.tab.title) · \(p.host.label)",
                leadingColor: p.host.accent,
                badge: p.tab.paneTags[p.ref.key]?.text
            ) { [weak controller, id = p.tab.id, i = p.index] in
                controller?.activate(tab: id, paneIndex: i)
            }
        }
        return out
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
    /// History buffers keyed `"{hostID}/{ref.key}"`, fetched once per sheet by `fetchTask`.
    /// Typing refines the query against these — the old shape re-ran `zmx history` (one
    /// process, or one ssh connection, per pane) on every 300ms-debounced keystroke.
    /// Content written after the sheet opened isn't searched; reopen to refresh.
    @State private var buffers: [String: String] = [:]
    @State private var fetchTask: Task<Void, Never>?

    struct Hit: Identifiable {
        let id = UUID()
        let tabID: TabModel.ID
        let paneIndex: Int
        let label: String
        let crumb: String
        let slot: Int
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
                                HostDot(slot: hit.slot, size: 6)
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
        .onExitCommand { onDone() }
        .onDisappear { debounce?.cancel(); searchTask?.cancel(); fetchTask?.cancel() }
    }

    /// One shared history fetch per sheet. Re-searches await the same task — it is never
    /// cancelled by retyping (only by sheet dismissal), so a half-fetched buffer set can't
    /// masquerade as the full one.
    private func bufferFetch() -> Task<Void, Never> {
        if let fetchTask { return fetchTask }
        // Local first so cheap matches surface while ssh is still in flight; the width cap
        // is for ssh — `run()` does `Process().run()` before its first suspension, so the
        // cooperative pool bounds waiting tasks, not subprocess count, and N panes on one
        // host = N fresh ssh connections (no ControlMaster) → sshd MaxStartups drops.
        let targets = registry.allPanes
            .sorted { $0.host.transport.isLocal && !$1.host.transport.isLocal }
        let t = Task {
            var i = 0
            await withTaskGroup(of: (String, String)?.self) { group in
                func add(_ p: (tab: TabModel, host: ForkHost, index: Int, ref: SessionRef)) {
                    group.addTask {
                        guard let buf = try? await ZmxAdapter.history(host: p.host, ref: p.ref)
                        else { return nil }
                        return ("\(p.ref.hostID)/\(p.ref.key)", buf)
                    }
                }
                while i < min(4, targets.count) { add(targets[i]); i += 1 }
                for await result in group {
                    if let (key, buf) = result { buffers[key] = buf }
                    if i < targets.count { add(targets[i]); i += 1 }
                }
            }
        }
        fetchTask = t
        return t
    }

    private func search() {
        searchTask?.cancel()
        hits = []
        generation += 1
        let gen = generation
        let q = query
        guard !q.isEmpty else { searching = false; return }
        debounce?.cancel()
        searching = true
        let panes = registry.allPanes
        searchTask = Task {
            await bufferFetch().value
            guard gen == generation, !Task.isCancelled else { return }
            // Pure client-side match against the cached buffers — no per-keystroke processes.
            hits = panes.compactMap { p in
                guard let buf = buffers["\(p.ref.hostID)/\(p.ref.key)"],
                      let line = buf.split(separator: "\n")
                          .last(where: { $0.localizedCaseInsensitiveContains(q) })
                else { return nil }
                return Hit(
                    tabID: p.tab.id, paneIndex: p.index,
                    label: p.tab.paneLabels[p.ref.key] ?? p.ref.name,
                    crumb: "· \(p.tab.title) · \(p.host.label)",
                    slot: p.host.slot,
                    snippet: String(line).trimmingCharacters(in: .whitespaces)
                )
            }
            searching = false
        }
    }
}
#endif
