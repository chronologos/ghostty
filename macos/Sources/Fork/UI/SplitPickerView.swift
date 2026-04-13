#if os(macOS)
import SwiftUI

/// ⌘D picker: new session (default, ⏎) or attach an existing one on the active host.
/// Type to filter · ↓/↑ to select · ⏎ attaches selection or creates new.
struct SplitPickerView: View {
    let host: ForkHost
    let placeholder: String
    let onSubmit: (SessionRef) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var recents: ZmxAdapter.ListResult?
    @State private var sel: Int?

    private var nameValid: Bool {
        name.isEmpty || SessionRef(hostID: host.id, name: name).isValid
    }

    private var items: [(name: String, external: Bool)] {
        guard let r = recents else { return [] }
        let all = r.managed.map { ($0, false) } + r.external.map { ($0, true) }
        guard !name.isEmpty else { return all }
        return all.filter { $0.0.localizedCaseInsensitiveContains(name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Split on \(host.label)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("", text: $name, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
                .backport.onKeyPress(.downArrow) { _ in move(1); return .handled }
                .backport.onKeyPress(.upArrow) { _ in move(-1); return .handled }
                .onChange(of: name) { _ in sel = nil }
            Divider()
            list.frame(height: 140)
            HStack {
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(sel == nil ? "New" : "Attach") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sel == nil && !nameValid)
            }
        }
        .padding()
        .frame(width: 280)
        .task { recents = await ZmxAdapter.list(host: host) }
    }

    @ViewBuilder private var list: some View {
        if recents == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        } else if items.isEmpty {
            Text(name.isEmpty ? "no sessions on \(host.label)" : "no match — ⏎ to create")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            row(i, item.name, external: item.external)
                        }
                    }
                }
                .onChange(of: sel) { s in if let s { proxy.scrollTo(s) } }
            }
        }
    }

    private func row(_ i: Int, _ n: String, external: Bool) -> some View {
        Button { submit(n, external: external) } label: {
            HStack {
                Text(n).font(.system(size: 12))
                Spacer()
                if external {
                    Text("ext").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(sel == i ? Color.accentColor.opacity(0.25) : .clear,
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

    private func commit() {
        if let sel, sel < items.count {
            let it = items[sel]
            submit(it.name, external: it.external)
        } else if nameValid {
            submit(name.isEmpty ? placeholder : name)
        }
    }

    private func submit(_ n: String, external: Bool = false) {
        onSubmit(SessionRef(hostID: host.id, name: n, external: external))
    }
}
#endif
