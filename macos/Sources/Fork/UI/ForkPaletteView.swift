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
    @Environment(\.forkTokens) private var tokens
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
            let alias = p.tab.paneLabels[p.ref.key]
            // An aliased pane leads with the alias; its session id joins the crumb so the
            // palette can still be matched on either.
            let crumb = "\(p.tab.title) · \(p.host.label)"
            return CommandOption(
                title: alias ?? p.ref.name,
                subtitle: (alias != nil && alias != p.ref.name) ? "\(p.ref.name) · \(crumb)" : crumb,
                leadingColor: tokens.hostAccent(p.host),
                badge: p.tab.paneTags[p.ref.key]?.map(\.text).joined(separator: " · ")
            ) { [weak controller, id = p.tab.id, i = p.index] in
                controller?.activate(tab: id, paneIndex: i)
            }
        }
        return out
    }
}

/// Fork-owned palette chrome: query field › option list › count footer in a `Panel`
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
        Panel(title: "Go to", chord: "⌘K") {
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
                    PromptMark(size: 15)
                    TextField("", text: $query,
                              prompt: Text("Jump to pane or run a command…").foregroundColor(tokens.inactive))
                        .textFieldStyle(.plain)
                        .forkFont(15).foregroundStyle(tokens.bright).tint(tokens.text)
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
                .padding(.horizontal, 14)
            }
            .frame(height: 44)
            PanelRule()
            if items.isEmpty {
                Spacer()
                Text("No matches").foregroundStyle(tokens.inactive).forkFont(12)
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
                        .background(OverlayScroller())
                    }
                    .onChange(of: selected) { sel in
                        guard let sel, sel < items.count else { return }
                        proxy.scrollTo(items[sel].id)
                    }
                }
            }
            PanelRule()
            HStack(spacing: 12) {
                Text(trimmedQuery.isEmpty ? "\(options.count) entries"
                                          : "\(items.count) of \(options.count)")
                    .foregroundStyle(tokens.inactive).forkFont(10)
                Spacer()
                KeyHint("↑↓", "move")
                KeyHint("⏎", "run", enabled: selected != nil)
                KeyHint("esc", "close")
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
        }
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
                // A pane leads with its host's color, an action with the prompt mark. The
                // option's `leadingIcon` is upstream's field and isn't drawn: a different
                // symbol per action was six more glyphs to learn beside titles that already
                // say what they do.
                if let color = opt.leadingColor {
                    color.frame(width: 8, height: 8).frame(width: 16)
                } else {
                    PromptMark(size: 12).frame(width: 16)
                }
                VStack(alignment: .leading, spacing: 1) {
                    highlight(opt.title).foregroundStyle(isSelected ? tokens.bright : tokens.text)
                        .forkFont(13, isSelected ? .bold : .regular)
                    if let sub = opt.subtitle {
                        // Subtitle highlights only when the title itself didn't match —
                        // same rule as upstream's CommandRow.
                        (titleMatched(opt) ? Text(sub) : highlight(sub))
                            .foregroundStyle(tokens.inactive)
                            .lineLimit(1).truncationMode(.middle).forkFont(11)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 12)
                if let badge = opt.badge, !badge.isEmpty {
                    Text(badge.uppercased()).kerning(0.5)
                        .foregroundStyle(tokens.text).forkFont(9, .bold)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .overlay(Rectangle().strokeBorder(tokens.rule, lineWidth: 1))
                }
                if let symbols = opt.symbols {
                    Text(symbols.joined()).foregroundStyle(tokens.text).forkFont(10, .semibold)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panelRow(selected: isSelected, hovered: hovered == opt.id)
        .id(opt.id)
        .onHover { hovered = $0 ? opt.id : nil }
        .help(opt.description ?? "")
    }

    private func titleMatched(_ opt: CommandOption) -> Bool {
        let q = trimmedQuery
        return !q.isEmpty && opt.title.matchedIndices(for: q) != nil
    }

    /// Bright-bold the matched characters — upstream's matcher, the fork's emphasis.
    private func highlight(_ text: String) -> Text {
        let q = trimmedQuery
        guard !q.isEmpty, let indices = text.matchedIndices(for: q) else { return Text(text) }
        var a = AttributedString(text)
        for idx in indices {
            let off = text.distance(from: text.startIndex, to: idx)
            let s = a.index(a.startIndex, offsetByCharacters: off)
            let e = a.index(s, offsetByCharacters: 1)
            a[s..<e].foregroundColor = tokens.bright
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
        /// The *latest* matching line, with up to one line either side for context.
        let before: String?
        let snippet: String
        let after: String?
        /// Matching lines in this pane's buffer (the row shows only the latest).
        let count: Int
    }
    /// Panes whose history couldn't be fetched (timeout, host down) or came back empty —
    /// `zmx history` exits 0 with no output when the daemon doesn't answer in time, so an
    /// empty buffer is "not searched", not "searched, no match".
    @State private var unsearched = 0
    @State private var searchedPanes = 0

    static let size = CGSize(width: 640, height: 440)

    var body: some View {
        Panel(title: "Search scrollback", chord: "⌘⇧K") {
            HStack(spacing: 10) {
                PromptMark(size: 15)
                TextField("", text: $query,
                          prompt: Text("Search every session's scrollback…").foregroundColor(tokens.inactive))
                    .textFieldStyle(.plain).forkFont(15).foregroundStyle(tokens.bright).tint(tokens.text)
                    .focused($fieldFocused).onSubmit(search)
                    .onChange(of: query) { _ in
                        debounce?.cancel()
                        debounce = Task {
                            try? await Task.sleep(for: .milliseconds(300))
                            if !Task.isCancelled { search() }
                        }
                    }
                if searching { Lamp(.working) }
            }
            .padding(.horizontal, 14).frame(height: 44)
            PanelRule()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(hits) { hit in
                        Button {
                            onDone()
                            controller?.activate(tab: hit.tabID, paneIndex: hit.paneIndex)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                HostDot(slot: hit.slot, size: 8).padding(.top, 4)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(hit.label).foregroundStyle(tokens.text).forkFont(12, .bold)
                                        Text(hit.crumb).foregroundStyle(tokens.inactive).forkFont(11)
                                        if hit.count > 1 {
                                            Text("· \(hit.count) matches, latest shown")
                                                .foregroundStyle(tokens.inactive).forkFont(10)
                                        }
                                    }
                                    if let b = hit.before {
                                        Text(b).foregroundStyle(tokens.inactive).lineLimit(1).forkFont(10)
                                    }
                                    Text(hit.snippet).foregroundStyle(tokens.bright).lineLimit(1).forkFont(10)
                                    if let a = hit.after {
                                        Text(a).foregroundStyle(tokens.inactive).lineLimit(1).forkFont(10)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        PanelRule()
                    }
                }
                .background(OverlayScroller())
            }
            if !searching && hits.isEmpty && !query.isEmpty {
                Text("No matches").foregroundStyle(tokens.inactive).forkFont(12).padding()
            }
            if !searching && !query.isEmpty {
                // Say what was actually searched: zmx keeps the last 10k lines per session,
                // and a pane whose history didn't come back isn't a pane with no match.
                PanelRule()
                Text("Searched \(searchedPanes) pane\(searchedPanes == 1 ? "" : "s")"
                     + (unsearched > 0 ? " · \(unsearched) unavailable (no answer)" : "")
                     + " · last 10k lines per session, as of when this opened")
                    .foregroundStyle(tokens.inactive).forkFont(10)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // Async: the borderless panel isn't key yet at onAppear time (same as the palette).
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
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
            var missing = 0
            hits = panes.compactMap { p in
                guard let buf = buffers["\(p.ref.hostID)/\(p.ref.key)"], !buf.isEmpty
                else { missing += 1; return nil }
                let lines = buf.split(separator: "\n", omittingEmptySubsequences: false)
                let matches = lines.indices.filter { lines[$0].localizedCaseInsensitiveContains(q) }
                guard let i = matches.last else { return nil }
                func tidy(_ j: Int) -> String? {
                    guard lines.indices.contains(j) else { return nil }
                    let t = String(lines[j]).trimmingCharacters(in: .whitespaces)
                    return t.isEmpty ? nil : t
                }
                return Hit(
                    tabID: p.tab.id, paneIndex: p.index,
                    label: p.tab.paneLabels[p.ref.key] ?? p.ref.name,
                    crumb: "· \(p.tab.title) · \(p.host.label)",
                    slot: p.host.slot,
                    before: tidy(i - 1),
                    snippet: tidy(i) ?? "",
                    after: tidy(i + 1),
                    count: matches.count
                )
            }
            unsearched = missing
            searchedPanes = panes.count - missing
            searching = false
        }
    }
}
#endif
