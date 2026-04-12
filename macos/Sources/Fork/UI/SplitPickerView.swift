#if os(macOS)
import SwiftUI

/// ⌘D picker: new session (default, ⏎) or attach an existing one on the active host.
struct SplitPickerView: View {
    let host: ForkHost
    let placeholder: String
    let onSubmit: (SessionRef) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var recents: ZmxAdapter.ListResult?

    private var nameValid: Bool {
        name.isEmpty || SessionRef(hostID: host.id, name: name).isValid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Split on \(host.label)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("", text: $name, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .onSubmit { if nameValid { submit(name.isEmpty ? placeholder : name) } }
            Divider()
            Group {
                if let r = recents {
                    if r.managed.isEmpty && r.external.isEmpty {
                        Text("no sessions on \(host.label)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(r.managed, id: \.self) { row($0, external: false) }
                                ForEach(r.external, id: \.self) { row($0, external: true) }
                            }
                        }
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            }
            .frame(height: 140)
            HStack {
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("New") { submit(name.isEmpty ? placeholder : name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!nameValid)
            }
        }
        .padding()
        .frame(width: 280)
        .task { recents = await ZmxAdapter.list(host: host) }
    }

    private func row(_ n: String, external: Bool) -> some View {
        Button { submit(n, external: external) } label: {
            HStack {
                Text(n).font(.system(size: 12))
                Spacer()
                if external {
                    Text("ext").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func submit(_ n: String, external: Bool = false) {
        onSubmit(SessionRef(hostID: host.id, name: n, external: external))
    }
}
#endif
