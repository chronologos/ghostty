#if os(macOS)
import SwiftUI

/// Compact session picker: new (default, ⏎) or attach an existing one on `host`.
/// Type to filter · ↓/↑ to select · ⏎ attaches selection or creates new ·
/// ⌘⏎ creates with the shell started at the zsh-z match for the typed name (smart jump).
/// Used for ⌘T, ⌘D split, and the host context-menu "New Session".
struct SplitPickerView: View {
    let title: String
    let host: ForkHost
    let placeholder: String
    /// `smartJump` is only ever true for *new* sessions — attaching an existing one keeps
    /// whatever cwd it already has.
    let onSubmit: (SessionRef, _ smartJump: Bool) -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var registry: SessionRegistry
    @State private var name: String = ""
    @State private var recents: ZmxAdapter.ListResult?
    @State private var unreachable = false
    @State private var sel: Int?

    private var nameValid: Bool {
        name.isEmpty || SessionRef(hostID: host.id, name: name).isValid
    }

    private var items: [ZmxAdapter.ListEntry] {
        guard let r = recents else { return [] }
        let all = r.managed + r.external
        guard !name.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("", text: $name, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
                .backport.onKeyPress(.downArrow) { _ in move(1); return .handled }
                .backport.onKeyPress(.upArrow) { _ in move(-1); return .handled }
                .onChange(of: name) { _ in sel = nil }
            Divider()
            list.frame(height: 140)
            HStack {
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                if sel == nil {
                    // ⌘⏎ — create with the shell started at zsh-z's frecency match for the
                    // typed name (resolved on the session's host). Needs a real typed name
                    // (z-jumping the random placeholder can't match), and the name must not
                    // already exist: `zmx attach` would attach to the existing session and
                    // silently discard the jump command.
                    let exists = items.contains { $0.name == name }
                    Button("New @ z") { commit(smartJump: true) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(name.isEmpty || !nameValid || exists)
                        .help(exists
                              ? "A session with this name already exists — ⏎ attaches to it"
                              : "⌘⏎ — create with shell started at the z-jump directory for this name")
                }
                Button(sel == nil ? "New" : "Attach") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sel == nil && !nameValid)
            }
        }
        .padding()
        .frame(width: 280)
        .task {
            let r = await ZmxAdapter.list(host: host)
            unreachable = (r == nil)
            recents = r ?? .init()
        }
    }

    @ViewBuilder private var list: some View {
        if recents == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        } else if unreachable && items.isEmpty {
            // A failed query must not read as "no sessions" — the sessions are very likely
            // still there; ⏎ still works (the new pane will surface the ssh error itself).
            // Sentence case, matching the other sheets' empty states.
            Text("Couldn't reach \(host.label) — ⏎ still creates")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        } else if items.isEmpty {
            Text(name.isEmpty ? "No sessions on \(host.label)" : "No match — ⏎ to create")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, e in
                            row(i, e)
                        }
                    }
                }
                .onChange(of: sel) { s in if let s { proxy.scrollTo(s) } }
            }
        }
    }

    private func row(_ i: Int, _ e: ZmxAdapter.ListEntry) -> some View {
        Button { submit(e.name, external: e.external) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(e.name).font(.system(size: 12, design: .monospaced))
                    if let title = registry.tabTitle(for: e.name, external: e.external, on: host.id) {
                        Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                SessionMetaLabel(entry: e,
                                 inSidebar: registry.isInSidebar(e.name, external: e.external, on: host.id),
                                 ccInfo: registry.ccInfo(for: e, on: host.id))
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(sel == i ? Theme.selectedRow : .clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(i)
    }

    private func move(_ d: Int) {
        guard !items.isEmpty else { return }
        switch (sel, d) {
        case (nil, 1): sel = 0
        case (0, -1): sel = nil
        case (let i?, _): sel = max(0, min(items.count - 1, i + d))
        default: break
        }
    }

    private func commit(smartJump: Bool = false) {
        if let sel, sel < items.count {
            // Attaching an existing session: it already has a cwd — smartJump is ignored.
            let it = items[sel]
            submit(it.name, external: it.external)
        } else if nameValid {
            submit(name.isEmpty ? placeholder : name, smartJump: smartJump)
        }
    }

    private func submit(_ n: String, external: Bool = false, smartJump: Bool = false) {
        onSubmit(SessionRef(hostID: host.id, name: n, external: external), smartJump && !external)
    }
}
#endif
