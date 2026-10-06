#if os(macOS)
import SwiftUI

struct NewSessionIntent {
    var hostID: ForkHost.ID
    var name: String?
    var cwd: String?
    var cmd: [String]?
    var external: Bool = false
    /// The user typed `name` (vs. the auto placeholder / an attach): a fresh named session
    /// gets its id seeded as its `ghostty_name` alias too, so it starts life renamable and
    /// labeled in `zmx list`. Auto names (`shell-abc`) stay unlabeled — that would be noise.
    var named: Bool = false
}

/// Reducer for the two-stage new-session palette. Owns *all* state — including
/// the fetched session list — so `advance` resets everything atomically and
/// `commit`/`canSmartJump` are testable (`NewSessionMachineTests`).
struct NewSessionMachine {
    enum Stage: Hashable { case host, session }

    enum Action: Equatable {
        case attach(name: String, external: Bool)
        /// `typed`: the user wrote the name (vs. taking the auto placeholder) — a typed
        /// name is seeded as the session's alias too. Decided here, where the branch is.
        case create(name: String, smartJump: Bool, typed: Bool)
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
    /// Why the session list couldn't be fetched (nil = it was).
    private(set) var failure: ZmxAdapter.ListFailure?
    var unreachable: Bool { failure != nil }
    let locked: Bool
    /// The auto name ⏎ creates when nothing is typed. Re-rolled in `setRecents` if the
    /// host already has a session by that name.
    private(set) var placeholder: String

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
        // Match the alias as well as the id — the alias is what the user reads in the
        // sidebar, the id is what `zmx` and ⏎-create key on.
        // …and the directory it's sitting in: typing "ghostty" should find the session
        // in ~/dev/ghostty whatever it happens to be called.
        return query.isEmpty ? all : all.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.alias?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.cwd?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// Sessions whose daemon didn't answer the list probe. Shown (dim, attachable) rather
    /// than dropped: a busy session that vanishes from the picker reads as "gone", and
    /// typing its name then looks like a create.
    var unresponsive: [ZmxAdapter.Unresponsive] {
        guard let r = recents else { return [] }
        return query.isEmpty ? r.unresponsive
            : r.unresponsive.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// The typed name already belongs to a managed session on the host — answered or not.
    private var nameTaken: Bool {
        sessions.contains { $0.name == query }
            || (recents?.unresponsive.contains { !$0.external && $0.name == query } ?? false)
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
            && !nameTaken
    }

    // MARK: events

    /// `count` = filtered list length; `.session` adds the "create new" slot 0.
    mutating func move(_ d: Int, in allHosts: [ForkHost]) {
        let n = stage == .host ? hosts(in: allHosts).count : sessions.count + 1
        guard n > 0 else { return }
        sel = max(0, min(n - 1, sel + d))
    }

    mutating func advance(to h: ForkHost) {
        host = h; query = ""; sel = 0; recents = nil; failure = nil; stage = .session
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
        setRecents(r.map(Result.success) ?? .failure(.other("")))
    }

    /// `reroll`: a fresh auto name. The placeholder is only unique against *this process's*
    /// panes; a Detach-closed session (still running by design) or one created from another
    /// Mac shares the same `{hostID}-` namespace. `zmx attach` on a taken name silently
    /// **attaches** — someone else's scrollback in a "new" pane, any initial command
    /// dropped, and a later Kill takes out the old session. The host's real list is right
    /// here, so check against it.
    mutating func setRecents(_ r: Result<ZmxAdapter.ListResult, ZmxAdapter.ListFailure>,
                             reroll: (() -> String)? = nil) {
        switch r {
        case .success(let list):
            failure = nil
            recents = list
            let taken = Set(list.managed.map(\.name) + list.unresponsive.filter { !$0.external }.map(\.name))
            var tries = 0
            while let reroll, taken.contains(placeholder), tries < 8 { placeholder = reroll(); tries += 1 }
        case .failure(let f):
            failure = f
            recents = .init()
        }
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
            if shift { return canSmartJump ? .create(name: query, smartJump: true, typed: true) : .beep }
            if nameValid {
                return .create(name: query.isEmpty ? placeholder : query, smartJump: false,
                               typed: !query.isEmpty)
            }
            // The query can't be a new id (a space, say) but matched exactly one existing
            // session by alias — ⏎ means "that one". Anything more ambiguous beeps rather
            // than dead-ending silently.
            if sessions.count == 1, let e = sessions.first {
                return .attach(name: e.name, external: e.external)
            }
            return .beep
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
    @Environment(\.forkTokens) private var tokens

    @EnvironmentObject private var registry: SessionRegistry

    let title: String?
    /// (ref, smartJump, named) — `named` = the user typed the session name (not the
    /// auto placeholder, not an attach), so the controller seeds it as the alias too.
    let onSubmit: (SessionRef, _ smartJump: Bool, _ named: Bool) -> Void
    let onCancel: () -> Void
    /// How stage 2 learns what's on the host. Injected only by offscreen renders.
    let lister: ZmxAdapter.Lister

    @State private var m: NewSessionMachine
    @FocusState private var focused: Bool

    static let size = CGSize(width: 480, height: 340)

    init(title: String? = nil,
         host: ForkHost,
         locked: Bool = false,
         placeholder: String,
         lister: @escaping ZmxAdapter.Lister = ZmxAdapter.liveLister,
         onSubmit: @escaping (SessionRef, Bool, Bool) -> Void,
         onCancel: @escaping () -> Void) {
        self.title = title
        self.lister = lister
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self._m = State(initialValue: .init(host: host, locked: locked, placeholder: placeholder))
    }

    private var hosts: [ForkHost] { m.hosts(in: registry.hosts) }

    // MARK: body

    var body: some View {
        Panel(title: title ?? "New session", chord: m.locked ? "⌘D" : "⌘T") {
            field.padding(.horizontal, 14).frame(height: 44)
            PanelRule()
            list.padding(6).frame(maxHeight: .infinity)
            PanelRule()
            footer.padding(.horizontal, 14).padding(.vertical, 6)
        }
        .frame(width: Self.size.width, height: Self.size.height)
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
            let r = await lister(m.host)
            guard !Task.isCancelled else { return }
            m.setRecents(r, reroll: { registry.uniqueAutoName() })
        }
    }

    // MARK: field

    private var field: some View {
        HStack(spacing: 10) {
            if m.stage == .host { PromptMark(size: 15) }
            if m.stage == .session {
                // Host chip — the committed stage-1 choice. Tappable (back to host pick)
                // unless host-locked.
                HStack(spacing: 6) {
                    HostDot(host: m.host, size: 8)
                    Text(m.host.label.uppercased()).kerning(0.6).foregroundStyle(tokens.text).forkFont(10, .bold)
                }
                .padding(.horizontal, 7).frame(height: 20)
                .overlay(Chamfer(cut: 4).strokeBorder(m.locked ? tokens.rule : tokens.text, lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture { m.back() }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            TextField("", text: $m.query,
                      prompt: Text(m.stage == .host ? "host" : m.placeholder).foregroundColor(tokens.inactive))
                .textFieldStyle(.plain)
                .forkFont(15).foregroundStyle(tokens.bright).tint(tokens.text)
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
                                Text(h.label).forkFont(13, i == m.sel ? .bold : .regular)
                                    .foregroundStyle(i == m.sel ? tokens.bright
                                                     : registry.isConnected(h.id) ? tokens.text : tokens.inactive)
                            }
                        }
                    case .session:
                        ForEach(Array(m.sessions.enumerated()), id: \.element) { i, e in
                            row(selected: i + 1 == m.sel,
                                action: { submit(e.name, external: e.external) }) {
                                VStack(alignment: .leading, spacing: 0) {
                                    SessionNameLabel(entry: e)
                                    if let t = registry.tabTitle(for: e.name, external: e.external, on: m.host.id) {
                                        Text(t).foregroundStyle(tokens.inactive).forkFont(10)
                                    }
                                }
                                Spacer()
                                SessionMetaLabel(
                                    entry: e,
                                    inSidebar: registry.isInSidebar(e.name, external: e.external, on: m.host.id),
                                    ccInfo: registry.ccInfo(for: e, on: m.host.id))
                            }
                        }
                        // Not keyboard-selectable (they sit outside `m.sessions`' index
                        // space) — click attaches; the pane will show whatever zmx says.
                        ForEach(m.unresponsive, id: \.self) { u in
                            row(selected: false, action: { submit(u.name, external: u.external) }) {
                                UnresponsiveSessionLabel(entry: u)
                                Spacer()
                            }
                        }
                    }
                }
                .background(OverlayScroller())
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
                .panelRow(selected: selected)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var emptyState: some View {
        if m.stage == .host, hosts.isEmpty {
            Text("No host matches").foregroundStyle(tokens.inactive).forkFont(11)
        } else if m.stage == .session, m.sessions.isEmpty, m.unresponsive.isEmpty, m.recents != nil {
            // "Couldn't reach" ≠ "No sessions" — a failed query must not imply the host is
            // empty; ⏎ still works (the new pane will surface the ssh error itself). And say
            // *why*: a zmx that's slow to list and an ssh that can't connect are different
            // problems.
            Text(m.failure.map { "No list from \(m.host.label) — \($0.summary). ⏎ still creates" }
                 ?? (m.query.isEmpty ? "No sessions on \(m.host.label)" : "No match — ⏎ creates"))
                .multilineTextAlignment(.center)
                .foregroundStyle(tokens.inactive).forkFont(11)
                .padding(.horizontal, 20)
        } else if m.stage == .session, m.recents == nil {
            Lamp(.working)
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 12) {
            switch m.stage {
            case .host:
                KeyHint("⏎ / tab", "select", enabled: !hosts.isEmpty)
            case .session:
                KeyHint("⏎", m.sel > 0 ? "attach" : "create", enabled: m.sel > 0 || m.nameValid)
                // Clickable + window-level shortcut so ⇧⏎ works on macOS 13 (where
                // backport.onKeyPress is a no-op) and via mouse. NOT `.disabled` — a
                // disabled button's shortcut is inert, so ⇧⏎ would fall through to
                // onSubmit (plain create); commit(true) already beeps when ineligible.
                Button { commit(true) } label: { KeyHint("⇧⏎", "create @ z", enabled: m.canSmartJump) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .shift)
                    .help(m.canSmartJump
                          ? "Create with the shell started at the z-jump directory for this name"
                          : "Needs a new, valid name (and no row selected)")
                if !m.locked { KeyHint("⌫", "host") }
            }
            Spacer()
            KeyHint("esc", "cancel")
        }
    }

    // MARK: actions

    private func commit(_ shift: Bool) {
        switch m.commit(shift: shift, in: registry.hosts) {
        case .attach(let name, let ext): submit(name, external: ext)
        case .create(let name, let sj, let typed): submit(name, smartJump: sj, named: typed)
        case .beep: NSSound.beep()
        case .none: break
        }
    }

    private func submit(_ name: String, external: Bool = false, smartJump: Bool = false,
                        named: Bool = false) {
        onSubmit(SessionRef(hostID: m.host.id, name: name, external: external),
                 smartJump && !external, named && !external)
    }
}
#endif
