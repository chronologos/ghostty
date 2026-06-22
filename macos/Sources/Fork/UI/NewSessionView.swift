#if os(macOS)
import SwiftUI

struct NewSessionIntent {
    var hostID: ForkHost.ID
    var name: String?
    var cwd: String?
    var cmd: [String]?
    var external: Bool = false
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

    private enum Stage { case host, session }

    let title: String?
    let locked: Bool
    let placeholder: String
    let onSubmit: (SessionRef, _ smartJump: Bool) -> Void
    let onCancel: () -> Void

    @State private var stage: Stage
    @State private var host: ForkHost
    @State private var query: String = ""
    @State private var sel: Int = 0
    @State private var recents: ZmxAdapter.ListResult?
    @State private var unreachable = false
    /// Bumped on every advance — `.task(id:)` keys on this (not `host.id`) so backing
    /// out and re-advancing to the same host retries the fetch.
    @State private var fetchToken: Int = 0
    @FocusState private var focused: Bool

    init(title: String? = nil,
         host: ForkHost,
         locked: Bool = false,
         placeholder: String,
         onSubmit: @escaping (SessionRef, Bool) -> Void,
         onCancel: @escaping () -> Void) {
        self.title = title
        self.locked = locked
        self.placeholder = placeholder
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self._host = State(initialValue: host)
        self._stage = State(initialValue: locked ? .session : .host)
    }

    // MARK: filtering

    private var hosts: [ForkHost] {
        guard !query.isEmpty else { return registry.hosts }
        return registry.hosts.filter { $0.label.localizedCaseInsensitiveContains(query) }
    }

    private var sessions: [ZmxAdapter.ListEntry] {
        guard let r = recents else { return [] }
        let all = r.managed + r.external
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var nameValid: Bool {
        query.isEmpty || SessionRef(hostID: host.id, name: query).isValid
    }

    /// ⇧⏎ needs a real typed name (z-jumping the random placeholder can't match), the
    /// name must not already exist — `zmx attach` would attach and discard the jump —
    /// no existing row may be selected (commit() would attach it instead), and the
    /// session list must have loaded (the exists-check below is vacuous against `[]`).
    private var canSmartJump: Bool {
        stage == .session && sel == 0 && recents != nil && !query.isEmpty && nameValid
            && !sessions.contains { $0.name == query }
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
        .onAppear {
            // Pre-select the default host so a bare ⏎ advances to it.
            if stage == .host, let i = hosts.firstIndex(where: { $0.id == host.id }) { sel = i }
            // @FocusState set synchronously in onAppear doesn't take — same defer as
            // ForkPaletteCard.
            DispatchQueue.main.async { focused = true }
        }
        .task(id: fetchToken) {
            guard stage == .session else { return }  // no eager prefetch from the host stage
            let r = await ZmxAdapter.list(host: host)
            guard !Task.isCancelled else { return }
            unreachable = (r == nil)
            recents = r ?? .init()
        }
    }

    // MARK: field

    private var field: some View {
        HStack(spacing: 8) {
            if stage == .session {
                // Host chip — the committed stage-1 choice. Tappable (back to host pick)
                // unless host-locked.
                HStack(spacing: 5) {
                    HostDot(host: host, size: 8)
                    Text(host.label).font(.system(size: 12))
                    if !locked {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.chipBg, in: Capsule())
                .onTapGesture { if !locked { back() } }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            TextField("", text: $query,
                      prompt: Text(stage == .host ? "host" : placeholder))
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: stage == .session ? .monospaced : .default))
                .focused($focused)
                // Plain ⏎ via onSubmit (works on macOS 13, where backport.onKeyPress is a
                // no-op); ⇧⏎ / Tab / ⌫ / arrows are 14+ niceties that degrade gracefully.
                .onSubmit { commit(false) }
                .backport.onKeyPress(.return) { mods in
                    guard mods.contains(.shift) else { return .ignored }
                    commit(true); return .handled
                }
                .backport.onKeyPress(.tab) { _ in
                    guard stage == .host, sel < hosts.count else { return .ignored }
                    advance(to: hosts[sel]); return .handled
                }
                .backport.onKeyPress(.delete) { _ in
                    guard stage == .session, query.isEmpty, !locked else { return .ignored }
                    back(); return .handled
                }
                .backport.onKeyPress(.downArrow) { _ in move(1); return .handled }
                .backport.onKeyPress(.upArrow) { _ in move(-1); return .handled }
                .onExitCommand(perform: onCancel)
                .onChange(of: query) { _ in sel = 0 }
        }
        .animation(Theme.settle, value: stage)
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
                    switch stage {
                    case .host:
                        ForEach(Array(hosts.enumerated()), id: \.element.id) { i, h in
                            row(selected: i == sel, action: { advance(to: h) }) {
                                HostDot(host: h, size: 8)
                                    .opacity(registry.isConnected(h.id) ? 1 : 0.35)
                                Text(h.label).font(.system(size: 13))
                            }
                        }
                    case .session:
                        ForEach(Array(sessions.enumerated()), id: \.element) { i, e in
                            row(selected: i + 1 == sel,
                                action: { submit(e.name, external: e.external) }) {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(e.name).font(.system(size: 12, design: .monospaced))
                                    if let t = registry.tabTitle(for: e.name, external: e.external, on: host.id) {
                                        Text(t).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                SessionMetaLabel(
                                    entry: e,
                                    inSidebar: registry.isInSidebar(e.name, external: e.external, on: host.id),
                                    ccInfo: registry.ccInfo(for: e, on: host.id))
                            }
                        }
                    }
                }
            }
            .onChange(of: sel) { s in
                switch stage {
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
        if stage == .host, hosts.isEmpty {
            Text("No host matches").font(.system(size: 11)).foregroundStyle(.secondary)
        } else if stage == .session, sessions.isEmpty, recents != nil {
            // "Couldn't reach" ≠ "No sessions" — a failed query must not imply the host is
            // empty; ⏎ still works (the new pane will surface the ssh error itself).
            Text(unreachable ? "Couldn't reach \(host.label) — ⏎ still creates"
                 : query.isEmpty ? "No sessions on \(host.label)"
                 : "No match — ⏎ creates")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        } else if stage == .session, recents == nil {
            ProgressView().controlSize(.small)
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 12) {
            switch stage {
            case .host:
                hint("⏎", "select")
                hint("tab", "select")
            case .session:
                hint("⏎", sel > 0 ? "attach" : "create")
                    .opacity(sel > 0 || nameValid ? 1 : 0.35)
                hint("⇧⏎", "create @ z").opacity(canSmartJump ? 1 : 0.35)
                    .help(canSmartJump
                          ? "Create with the shell started at the z-jump directory for this name"
                          : "Needs a new, valid name (and no row selected)")
                if !locked { hint("⌫", "host") }
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

    private func move(_ d: Int) {
        let n = stage == .host ? hosts.count
                               : sessions.count + 1  // slot 0 = "create new"
        guard n > 0 else { return }
        sel = max(0, min(n - 1, sel + d))
    }

    private func commit(_ shift: Bool) {
        switch stage {
        case .host:
            if sel < hosts.count { advance(to: hosts[sel]) }
        case .session:
            if sel > 0, sel - 1 < sessions.count {
                let e = sessions[sel - 1]
                submit(e.name, external: e.external)
            } else if shift {
                // ⇧⏎ that can't z-jump must NOT fall through to plain create — that's
                // exactly the silent attach-and-discard the guard exists to prevent.
                if canSmartJump { submit(query, smartJump: true) } else { NSSound.beep() }
            } else if nameValid {
                submit(query.isEmpty ? placeholder : query)
            }
        }
    }

    private func advance(to h: ForkHost) {
        host = h
        query = ""
        sel = 0
        recents = nil
        unreachable = false
        stage = .session
        fetchToken += 1
    }

    private func back() {
        query = ""
        sel = 0
        stage = .host
    }

    private func submit(_ name: String, external: Bool = false, smartJump: Bool = false) {
        onSubmit(SessionRef(hostID: host.id, name: name, external: external),
                 smartJump && !external)
    }
}
#endif
