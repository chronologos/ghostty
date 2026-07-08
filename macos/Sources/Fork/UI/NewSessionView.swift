#if os(macOS)
import SwiftUI

struct NewSessionIntent {
    var hostID: ForkHost.ID
    var name: String?
    var cwd: String?
    var cmd: [String]?
    var external: Bool = false
}

/// Reducer for the two-stage new-session palette. Owns *all* state — including
/// the fetched session list — so `advance` resets everything atomically and
/// `commit`/`canSmartJump` are testable (`NewSessionMachineTests`).
struct NewSessionMachine {
    enum Stage: Hashable { case host, session }

    enum Action: Equatable {
        case attach(name: String, external: Bool)
        case create(name: String, smartJump: Bool)
        case beep
        case none
    }

    private(set) var stage: Stage
    private(set) var host: ForkHost
    /// `sel` resets only when the query *changes* — a macOS `TextField` re-writes
    /// its binding with the unchanged text when the field editor commits on ⏎, so
    /// an unguarded `didSet` here zeroed `sel` between arrow-key selection and
    /// `.onSubmit` (⏎ always picked host 0). Stage transitions reset `sel`
    /// explicitly in `advance`/`back`. No view-side `onChange` coupling.
    var query = "" { didSet { if query != oldValue { sel = 0 } } }
    private(set) var sel = 0
    private(set) var recents: ZmxAdapter.ListResult?
    private(set) var unreachable = false
    let locked: Bool
    let placeholder: String

    init(host: ForkHost, locked: Bool, placeholder: String) {
        self.host = host
        self.locked = locked
        self.placeholder = placeholder
        stage = locked ? .session : .host
    }

    // MARK: derived

    func hosts(in all: [ForkHost]) -> [ForkHost] {
        query.isEmpty ? all : all.filter { $0.label.localizedCaseInsensitiveContains(query) }
    }

    var sessions: [ZmxAdapter.ListEntry] {
        guard let r = recents else { return [] }
        let all = r.managed + r.external
        return query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var nameValid: Bool {
        query.isEmpty || SessionRef(hostID: host.id, name: query).isValid
    }

    /// ⇧⏎ needs a real typed name (z-jumping the random placeholder can't match), the
    /// name must not already exist — `zmx attach` would attach and discard the jump —
    /// no existing row may be selected (commit() would attach it instead), and the
    /// session list must have loaded (the exists-check below is vacuous against `[]`).
    var canSmartJump: Bool {
        stage == .session && sel == 0 && recents != nil && !query.isEmpty && nameValid
            && !sessions.contains { $0.name == query }
    }

    // MARK: events

    /// `count` = filtered list length; `.session` adds the "create new" slot 0.
    mutating func move(_ d: Int, in allHosts: [ForkHost]) {
        let n = stage == .host ? hosts(in: allHosts).count : sessions.count + 1
        guard n > 0 else { return }
        sel = max(0, min(n - 1, sel + d))
    }

    mutating func advance(to h: ForkHost) {
        host = h; query = ""; sel = 0; recents = nil; unreachable = false; stage = .session
    }

    mutating func back() {
        guard !locked else { return }
        query = ""; sel = 0; stage = .host
    }

    mutating func preselect(in all: [ForkHost]) {
        if stage == .host, let i = all.firstIndex(where: { $0.id == host.id }) { sel = i }
    }

    /// View calls after the async `zmx list` resolves; `nil` = host unreachable.
    mutating func setRecents(_ r: ZmxAdapter.ListResult?) {
        unreachable = (r == nil)
        recents = r ?? .init()
    }

    /// Mutating: at `.host` it advances internally and returns `.none`.
    mutating func commit(shift: Bool, in allHosts: [ForkHost]) -> Action {
        switch stage {
        case .host:
            let h = hosts(in: allHosts)
            if sel < h.count { advance(to: h[sel]) }
            return .none
        case .session:
            if sel > 0, sel - 1 < sessions.count {
                let e = sessions[sel - 1]
                return .attach(name: e.name, external: e.external)
            }
            if shift { return canSmartJump ? .create(name: query, smartJump: true) : .beep }
            return nameValid ? .create(name: query.isEmpty ? placeholder : query, smartJump: false)
                             : .none
        }
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
    let onSubmit: (SessionRef, _ smartJump: Bool) -> Void
    let onCancel: () -> Void

    @State private var m: NewSessionMachine
    @FocusState private var focused: Bool

    init(title: String? = nil,
         host: ForkHost,
         locked: Bool = false,
         placeholder: String,
         onSubmit: @escaping (SessionRef, Bool) -> Void,
         onCancel: @escaping () -> Void) {
        self.title = title
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self._m = State(initialValue: .init(host: host, locked: locked, placeholder: placeholder))
    }

    private var hosts: [ForkHost] { m.hosts(in: registry.hosts) }

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
            m.preselect(in: registry.hosts)
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
            m.setRecents(r)
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
                      prompt: Text(m.stage == .host ? "host" : m.placeholder))
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
                    guard m.stage == .host else { return .ignored }
                    commit(false); return .handled
                }
                .backport.onKeyPress(.delete) { _ in
                    guard m.stage == .session, m.query.isEmpty, !m.locked else { return .ignored }
                    m.back(); return .handled
                }
                .backport.onKeyPress(.downArrow) { _ in m.move(1, in: registry.hosts); return .handled }
                .backport.onKeyPress(.upArrow) { _ in m.move(-1, in: registry.hosts); return .handled }
                .onExitCommand(perform: onCancel)
        }
        .animation(Theme.settle, value: m.stage)
    }

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
                            row(selected: i == m.sel, action: { m.advance(to: h) }) {
                                HostDot(host: h, size: 8)
                                    .opacity(registry.isConnected(h.id) ? 1 : 0.35)
                                Text(h.label).font(.system(size: 13))
                            }
                        }
                    case .session:
                        ForEach(Array(m.sessions.enumerated()), id: \.element) { i, e in
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
                case .session where s > 0 && s - 1 < m.sessions.count:
                    proxy.scrollTo(m.sessions[s - 1])
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
        } else if m.stage == .session, m.sessions.isEmpty, m.recents != nil {
            // "Couldn't reach" ≠ "No sessions" — a failed query must not imply the host is
            // empty; ⏎ still works (the new pane will surface the ssh error itself).
            Text(m.unreachable ? "Couldn't reach \(m.host.label) — ⏎ still creates"
                 : m.query.isEmpty ? "No sessions on \(m.host.label)"
                 : "No match — ⏎ creates")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        } else if m.stage == .session, m.recents == nil {
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
                    .opacity(m.canSmartJump ? 1 : 0.35)
                    .help(m.canSmartJump
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

    private func commit(_ shift: Bool) {
        switch m.commit(shift: shift, in: registry.hosts) {
        case .attach(let name, let ext): submit(name, external: ext)
        case .create(let name, let sj): submit(name, smartJump: sj)
        case .beep: NSSound.beep()
        case .none: break
        }
    }

    private func submit(_ name: String, external: Bool = false, smartJump: Bool = false) {
        onSubmit(SessionRef(hostID: m.host.id, name: name, external: external),
                 smartJump && !external)
    }
}
#endif
