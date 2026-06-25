#if os(macOS)
import SwiftUI

struct NewSessionIntent {
    var hostID: ForkHost.ID
    var name: String?
    var cwd: String?
    var cmd: [String]?
    var external: Bool = false
}

/// Pure two-stage state for the new-session palette — extracted so the
/// `advance`/`back`/`move` invariants are unit-testable
/// (`NewSessionMachineTests`) instead of only reachable by driving the sheet.
struct NewSessionMachine: Equatable {
    enum Stage: Hashable { case host, session }

    private(set) var stage: Stage
    private(set) var host: ForkHost
    /// `didSet` fires on *every* assignment — including `query = ""` from
    /// `advance`/`back` when it was already empty — so this is the single place
    /// `sel` resets. No view-side `onChange` coupling.
    var query = "" { didSet { sel = 0 } }
    private(set) var sel = 0
    let locked: Bool

    init(host: ForkHost, locked: Bool) {
        self.host = host
        self.locked = locked
        stage = locked ? .session : .host
    }

    var nameValid: Bool {
        query.isEmpty || SessionRef(hostID: host.id, name: query).isValid
    }

    /// `count` = filtered list length; `.session` adds the "create new" slot 0.
    mutating func move(_ d: Int, count: Int) {
        let n = stage == .host ? count : count + 1
        guard n > 0 else { return }
        sel = max(0, min(n - 1, sel + d))
    }

    mutating func advance(to h: ForkHost) {
        host = h; query = ""; stage = .session
    }

    mutating func back() {
        guard !locked else { return }
        query = ""; stage = .host
    }

    mutating func preselect(hostIndex i: Int) {
        if stage == .host { sel = i }
    }
}

/// Two-stage new-session palette (⌘T / ⌘⇧T / sidebar ＋ / ⌘D / host context-menu).
///
/// Stage 1 — host: type to filter, ↓/↑ to move, ⏎ or Tab commits and advances.
/// Stage 2 — session: type a name (or filter existing), ↓/↑ selects an existing
/// session, ⏎ attaches the selection or creates new, ⇧⏎ creates with the shell
/// started at the zsh-z frecency match for the typed name (smart jump). ⌫ on an
/// empty field steps back to the host stage.
///
/// `locked` skips stage 1 entirely — used for ⌘D (split = current pane's host)
/// and the host-row context menu where the host is already decided.
struct NewSessionView: View {
    @EnvironmentObject private var registry: SessionRegistry

    let title: String?
    let placeholder: String
    let onSubmit: (SessionRef, _ smartJump: Bool) -> Void
    let onCancel: () -> Void

    @State private var m: NewSessionMachine
    @State private var recents: ZmxAdapter.ListResult?
    @State private var unreachable = false
    @FocusState private var focused: Bool

    init(title: String? = nil,
         host: ForkHost,
         locked: Bool = false,
         placeholder: String,
         onSubmit: @escaping (SessionRef, Bool) -> Void,
         onCancel: @escaping () -> Void) {
        self.title = title
        self.placeholder = placeholder
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self._m = State(initialValue: .init(host: host, locked: locked))
    }

    // MARK: filtering

    private var hosts: [ForkHost] {
        guard !m.query.isEmpty else { return registry.hosts }
        return registry.hosts.filter { $0.label.localizedCaseInsensitiveContains(m.query) }
    }

    private var sessions: [ZmxAdapter.ListEntry] {
        guard let r = recents else { return [] }
        let all = r.managed + r.external
        guard !m.query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(m.query) }
    }

    /// ⇧⏎ needs a real typed name (z-jumping the random placeholder can't match), the
    /// name must not already exist — `zmx attach` would attach and discard the jump —
    /// no existing row may be selected (commit() would attach it instead), and the
    /// session list must have loaded (the exists-check below is vacuous against `[]`).
    private var canSmartJump: Bool {
        m.stage == .session && m.sel == 0 && recents != nil && !m.query.isEmpty
            && m.nameValid && !sessions.contains { $0.name == m.query }
    }

    // MARK: body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
            field
            Theme.peekRule.frame(height: 1).padding(.vertical, 10)
            list.frame(maxHeight: .infinity)
            footer.padding(.top, 10)
        }
        .padding(14)
        .frame(width: 400, height: 300)
        // Window-level fallbacks so ⏎/Esc still work if focus ever leaves the field
        // (hazard #8 — a sheet refactor that drops these regresses silently).
        // Disabled while the field IS focused: commit() isn't idempotent (host-stage ⏎
        // advances, a second fire on the same event would then create the placeholder).
        .background(Group {
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            Button("Commit") { commit(false) }.keyboardShortcut(.defaultAction)
        }.disabled(focused).hidden())
        .onAppear {
            // Pre-select the default host so a bare ⏎ advances to it.
            if let i = hosts.firstIndex(where: { $0.id == m.host.id }) { m.preselect(hostIndex: i) }
            // @FocusState set synchronously in onAppear doesn't take — same defer as
            // ForkPaletteCard.
            DispatchQueue.main.async { focused = true }
        }
        // Keyed on `stage` (not `host.id`) so back→re-advance to the *same* host still
        // toggles the id and retries the fetch.
        .task(id: m.stage) {
            guard m.stage == .session else { return }
            let r = await ZmxAdapter.list(host: m.host)
            guard !Task.isCancelled else { return }
            unreachable = (r == nil)
            recents = r ?? .init()
        }
    }

    // MARK: field

    private var field: some View {
        HStack(spacing: 8) {
            if m.stage == .session {
                // Host chip — the committed stage-1 choice. Tappable (back to host pick)
                // unless host-locked.
                HStack(spacing: 5) {
                    HostDot(host: m.host, size: 8)
                    Text(m.host.label).font(.system(size: 12))
                    if !m.locked {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.chipBg, in: Capsule())
                .onTapGesture { m.back() }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            TextField("", text: $m.query,
                      prompt: Text(m.stage == .host ? "host" : placeholder))
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: m.stage == .session ? .monospaced : .default))
                .focused($focused)
                .onSubmit { commit(false) }
                // Field-level ⇧⏎ — the footer button's keyboardShortcut covers mouse +
                // macOS 13, but a focused TextField may swallow ⇧⏎ as plain ⏎ before
                // performKeyEquivalent reaches the button. Belt-and-suspenders.
                .backport.onKeyPress(.return) { mods in
                    guard mods.contains(.shift) else { return .ignored }
                    commit(true); return .handled
                }
                .backport.onKeyPress(.tab) { _ in
                    guard m.stage == .host, m.sel < hosts.count else { return .ignored }
                    advance(to: hosts[m.sel]); return .handled
                }
                .backport.onKeyPress(.delete) { _ in
                    guard m.stage == .session, m.query.isEmpty, !m.locked else { return .ignored }
                    m.back(); return .handled
                }
                .backport.onKeyPress(.downArrow) { _ in m.move(1, count: count); return .handled }
                .backport.onKeyPress(.upArrow) { _ in m.move(-1, count: count); return .handled }
                .onExitCommand(perform: onCancel)
        }
        .animation(Theme.settle, value: m.stage)
    }

    private var count: Int { m.stage == .host ? hosts.count : sessions.count }

    // MARK: list

    @ViewBuilder private var list: some View {
        // Row identity MUST be the stable entity (host.id / ListEntry), never the
        // enumerated offset — an offset-keyed `.id(i)` survives a filter unchanged,
        // so SwiftUI keeps the row alive with its *old* content while the underlying
        // hosts[i] has shifted.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    switch m.stage {
                    case .host:
                        ForEach(Array(hosts.enumerated()), id: \.element.id) { i, h in
                            row(selected: i == m.sel, action: { advance(to: h) }) {
                                HostDot(host: h, size: 8)
                                    .opacity(registry.isConnected(h.id) ? 1 : 0.35)
                                Text(h.label).font(.system(size: 13))
                            }
                        }
                    case .session:
                        ForEach(Array(sessions.enumerated()), id: \.element) { i, e in
                            row(selected: i + 1 == m.sel,
                                action: { submit(e.name, external: e.external) }) {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(e.name).font(.system(size: 12, design: .monospaced))
                                    if let t = registry.tabTitle(for: e.name, external: e.external, on: m.host.id) {
                                        Text(t).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                SessionMetaLabel(
                                    entry: e,
                                    inSidebar: registry.isInSidebar(e.name, external: e.external, on: m.host.id),
                                    ccInfo: registry.ccInfo(for: e, on: m.host.id))
                            }
                        }
                    }
                }
            }
            .onChange(of: m.sel) { s in
                switch m.stage {
                case .host where s < hosts.count:
                    proxy.scrollTo(hosts[s].id)
                case .session where s > 0 && s - 1 < sessions.count:
                    proxy.scrollTo(sessions[s - 1])
                default: break
                }
            }
        }
        .overlay { emptyState }
    }

    private func row<C: View>(selected: Bool, action: @escaping () -> Void,
                              @ViewBuilder _ content: () -> C) -> some View {
        Button(action: action) {
            HStack(spacing: 8) { content() }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Theme.selectedRow : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var emptyState: some View {
        if m.stage == .host, hosts.isEmpty {
            Text("No host matches").font(.system(size: 11)).foregroundStyle(.secondary)
        } else if m.stage == .session, sessions.isEmpty, recents != nil {
            // "Couldn't reach" ≠ "No sessions" — a failed query must not imply the host is
            // empty; ⏎ still works (the new pane will surface the ssh error itself).
            Text(unreachable ? "Couldn't reach \(m.host.label) — ⏎ still creates"
                 : m.query.isEmpty ? "No sessions on \(m.host.label)"
                 : "No match — ⏎ creates")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        } else if m.stage == .session, recents == nil {
            ProgressView().controlSize(.small)
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 12) {
            switch m.stage {
            case .host:
                hint("⏎ / tab", "select").opacity(hosts.isEmpty ? 0.35 : 1)
            case .session:
                hint("⏎", m.sel > 0 ? "attach" : "create")
                    .opacity(m.sel > 0 || m.nameValid ? 1 : 0.35)
                // Clickable + window-level shortcut so ⇧⏎ works on macOS 13 (where
                // backport.onKeyPress is a no-op) and via mouse. NOT `.disabled` — a
                // disabled button's shortcut is inert, so ⇧⏎ would fall through to
                // onSubmit (plain create); commit(true) already beeps when ineligible.
                Button { commit(true) } label: { hint("⇧⏎", "create @ z") }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .shift)
                    .opacity(canSmartJump ? 1 : 0.35)
                    .help(canSmartJump
                          ? "Create with the shell started at the z-jump directory for this name"
                          : "Needs a new, valid name (and no row selected)")
                if !m.locked { hint("⌫", "host") }
            }
            Spacer()
            hint("esc", "cancel")
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).padding(.horizontal, 4).padding(.vertical, 1)
                .background(Theme.chipBg, in: RoundedRectangle(cornerRadius: 3))
            Text(label)
        }
    }

    // MARK: actions

    private func advance(to h: ForkHost) {
        recents = nil
        unreachable = false
        m.advance(to: h)
    }

    private func commit(_ shift: Bool) {
        switch m.stage {
        case .host:
            if m.sel < hosts.count { advance(to: hosts[m.sel]) }
        case .session:
            if m.sel > 0, m.sel - 1 < sessions.count {
                let e = sessions[m.sel - 1]
                submit(e.name, external: e.external)
            } else if shift {
                // ⇧⏎ that can't z-jump must NOT fall through to plain create — that's
                // exactly the silent attach-and-discard the guard exists to prevent.
                if canSmartJump { submit(m.query, smartJump: true) } else { NSSound.beep() }
            } else if m.nameValid {
                submit(m.query.isEmpty ? placeholder : m.query)
            }
        }
    }

    private func submit(_ name: String, external: Bool = false, smartJump: Bool = false) {
        onSubmit(SessionRef(hostID: m.host.id, name: name, external: external),
                 smartJump && !external)
    }
}
#endif
