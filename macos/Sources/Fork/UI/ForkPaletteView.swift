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
/// and jump to it, plus pane actions and user hover-commands.
/// Renders through `ForkPaletteCard` (fork-owned chrome), NOT upstream's
/// `CommandPaletteView`: that card hard-caps itself at 500pt wide with a 200pt option
/// table (~4 visible rows) regardless of the panel it's given, which throws away the
/// window-scaled panel `showPanePalette` now provides. Matching reuses upstream's
/// `String.matchedIndices(for:)` so filter behavior (substring + initials) stays
/// identical to the terminal palette's.
struct ForkPanePalette: View {
    weak var controller: ForkWindowController?
    let onDone: () -> Void
    @EnvironmentObject private var registry: SessionRegistry

    var body: some View {
        ForkPaletteCard(options: options, onDone: onDone)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        // Tab-history navigation (also on the mouse thumb buttons / page-swipe gestures).
        // `canHistoryStep` runs the exact same walk navigation does — entries only show
        // when they'd actually land somewhere (dead and already-active history entries are
        // skipped, not offered).
        if registry.canHistoryStep(-1) {
            out.append(.init(title: "Back", subtitle: "Previous tab in visit history",
                             leadingIcon: "chevron.backward") {
                [weak controller] in controller?.navigateTabHistory(-1)
            })
        }
        if registry.canHistoryStep(+1) {
            out.append(.init(title: "Forward", subtitle: "Next tab in visit history",
                             leadingIcon: "chevron.forward") {
                [weak controller] in controller?.navigateTabHistory(+1)
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

/// Fork-owned palette chrome: query field › option list › count footer in a HandCut card
/// that fills whatever frame the presenting panel gives it (the panel scales with the
/// window — see `showPanePalette`). Keyboard contract matches upstream's palette: ↑↓ and
/// ⌃P/⌃N move, ⏎ runs, Esc closes, typing filters with first-match auto-select.
private struct ForkPaletteCard: View {
    @Environment(\.forkTokens) private var tokens

    let options: [CommandOption]
    let onDone: () -> Void
    @State private var query = ""
    /// nil = nothing selected (⏎ just closes — an accidental return on the unfiltered
    /// list must never fire an arbitrary action); set to 0 as soon as a query exists.
    @State private var selected: Int?
    @State private var hovered: UUID?
    @FocusState private var focused: Bool

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private var filtered: [CommandOption] {
        let q = trimmedQuery
        guard !q.isEmpty else { return options }
        return options.filter {
            $0.title.matchedIndices(for: q) != nil || ($0.subtitle?.matchedIndices(for: q) != nil)
        }
    }

    var body: some View {
        let items = filtered
        VStack(spacing: 0) {
            // Keyboard nav mirrors upstream's CommandPaletteQuery exactly: hidden
            // `Color.clear`-labeled buttons (an EmptyView label can be optimized out of
            // the hierarchy, killing the shortcuts) catch ↑↓/⌃P/⌃N when focus is outside
            // the field, AND `.onMoveCommand` catches the arrows the field editor
            // consumes as moveUp:/moveDown: while typing. Complementary paths — at most
            // one fires per press.
            ZStack {
                Group {
                    Button { move(-1, count: items.count) } label: { Color.clear }
                        .keyboardShortcut(.upArrow, modifiers: [])
                    Button { move(+1, count: items.count) } label: { Color.clear }
                        .keyboardShortcut(.downArrow, modifiers: [])
                    Button { move(-1, count: items.count) } label: { Color.clear }
                        .keyboardShortcut(KeyEquivalent("p"), modifiers: .control)
                    Button { move(+1, count: items.count) } label: { Color.clear }
                        .keyboardShortcut(KeyEquivalent("n"), modifiers: .control)
                }
                .buttonStyle(.plain).frame(width: 0, height: 0)
                .accessibilityHidden(true)

                HStack(spacing: 10) {
                    Image(systemName: "rectangle.split.3x1.fill")
                        .font(.system(size: 14)).foregroundStyle(tokens.textSecondary)
                    TextField("Jump to pane or run a command…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18, weight: .light))
                        .focused($focused)
                        .onSubmit { submit(items) }
                        .onExitCommand { onDone() }
                        .onMoveCommand { dir in
                            switch dir {
                            case .up: move(-1, count: items.count)
                            case .down: move(+1, count: items.count)
                            default: break
                            }
                        }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 48)
            Divider()
            if items.isEmpty {
                Spacer()
                Text("No matches").font(.system(size: 12)).foregroundStyle(tokens.textSecondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, opt in
                                row(opt, index: i, count: items.count)
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: selected) { sel in
                        guard let sel, sel < items.count else { return }
                        proxy.scrollTo(items[sel].id)
                    }
                }
            }
            Divider()
            HStack {
                Text(trimmedQuery.isEmpty ? "\(options.count) entries"
                                          : "\(items.count) of \(options.count)")
                Spacer()
                Text("↑↓ move · ⏎ run · esc close")
            }
            .font(.system(size: 10)).foregroundStyle(tokens.textSecondary)
            .padding(.horizontal, 14).padding(.vertical, 5)
        }
        .background(.ultraThinMaterial, in: HandCut(tl: 14, tr: 8, br: 16, bl: 10))
        .overlay(HandCut(tl: 14, tr: 8, br: 16, bl: 10).stroke(tokens.cardBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        // Margin inside the borderless panel so the shadow has room to render.
        .padding(24)
        // Async focus: the panel isn't key yet at onAppear time (same reason upstream's
        // palette defers); a sync set silently no-ops.
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: trimmedQuery) { q in
            if q.isEmpty { selected = nil } else if selected == nil { selected = 0 }
        }
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        if let cur = selected {
            selected = ((cur + delta) % count + count) % count
        } else {
            selected = delta > 0 ? 0 : count - 1
        }
    }

    private func submit(_ items: [CommandOption]) {
        // Clamp like upstream: a selection past the end of a shrunken filter list runs the
        // last visible item (it's the one rendered as selected).
        let opt = selected.flatMap { $0 < items.count ? items[$0] : items.last }
        onDone()
        opt?.action()
    }

    private func row(_ opt: CommandOption, index: Int, count: Int) -> some View {
        let isSelected = selected.map { $0 == index || ($0 >= count && index == count - 1) } ?? false
        return Button {
            onDone()
            opt.action()
        } label: {
            HStack(spacing: 9) {
                if let color = opt.leadingColor {
                    // Mini host dot — same organic pebble as the sidebar's, seeded stably
                    // from the title so the silhouette doesn't reshuffle while filtering.
                    Pebble(seed: opt.title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % 89)
                        .fill(color).frame(width: 9, height: 9)
                        .frame(width: 16)
                } else if let icon = opt.leadingIcon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tokens.textSecondary)
                        .frame(width: 16)
                } else {
                    Color.clear.frame(width: 16, height: 1)
                }
                VStack(alignment: .leading, spacing: 1) {
                    highlight(opt.title).font(.system(size: 13))
                    if let sub = opt.subtitle {
                        // Subtitle highlights only when the title itself didn't match —
                        // same rule as upstream's CommandRow.
                        (titleMatched(opt) ? Text(sub) : highlight(sub))
                            .font(.system(size: 11)).foregroundStyle(tokens.textSecondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 12)
                if let badge = opt.badge, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.clay.opacity(0.14), in: Capsule())
                        .foregroundStyle(Theme.clay)
                }
                if let symbols = opt.symbols {
                    HStack(spacing: 2) {
                        ForEach(Array(symbols.enumerated()), id: \.offset) { _, s in
                            Text(s).font(.system(size: 11, weight: .medium))
                        }
                    }
                    .foregroundStyle(tokens.textSecondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? tokens.selectedRow : hovered == opt.id ? tokens.hover : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .id(opt.id)
        .onHover { hovered = $0 ? opt.id : nil }
        .help(opt.description ?? "")
    }

    private func titleMatched(_ opt: CommandOption) -> Bool {
        let q = trimmedQuery
        return !q.isEmpty && opt.title.matchedIndices(for: q) != nil
    }

    /// Clay-bold the matched characters — upstream's matcher, the fork's accent.
    private func highlight(_ text: String) -> Text {
        let q = trimmedQuery
        guard !q.isEmpty, let indices = text.matchedIndices(for: q) else { return Text(text) }
        var a = AttributedString(text)
        for idx in indices {
            let off = text.distance(from: text.startIndex, to: idx)
            let s = a.index(a.startIndex, offsetByCharacters: off)
            let e = a.index(s, offsetByCharacters: 1)
            a[s..<e].foregroundColor = Theme.clay
            a[s..<e].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(a)
    }
}

/// ⌘⇧K — grep `zmx history` of every session for a string; click to jump.
/// Match is client-side `contains` on the fetched buffer — `controlArgv` stays
/// argv-only so user input never touches a shell (CLAUDE.md security boundary).
struct ScrollbackSearchView: View {
    @Environment(\.forkTokens) private var tokens

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
                Image(systemName: "text.magnifyingglass").foregroundStyle(tokens.textSecondary)
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
                                        Text(hit.crumb).font(.system(size: 11)).foregroundStyle(tokens.textSecondary)
                                    }
                                    Text(hit.snippet)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(tokens.textSecondary).lineLimit(1)
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
                Text("No matches").font(.system(size: 11)).foregroundStyle(tokens.textSecondary).padding()
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
