#if os(macOS)
import SwiftUI

/// Minimal "add host" form: label · user@host. Validation mirrors `SSHTarget.isValid`.
struct NewHostView: View {
    @EnvironmentObject private var registry: SessionRegistry

    @State private var label: String = ""
    @State private var connection: String = ""

    let onDone: () -> Void

    private var target: ForkHost.SSHTarget? {
        let parts = connection.split(separator: "@", maxSplits: 1).map(String.init)
        let t: ForkHost.SSHTarget = parts.count == 2
            ? .init(user: parts[0], host: parts[1])
            : .init(user: nil, host: connection)
        return t.isValid ? t : nil
    }

    var body: some View {
        Form {
            TextField("Label", text: $label, prompt: Text("prod-web-01"))
            TextField("Connection", text: $connection, prompt: Text("user@host"))
            HStack {
                Button("Cancel") { onDone() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(target == nil)
            }
        }
        .padding().frame(width: 360)
    }

    private func add() {
        guard let t = target else { return }
        let id = ForkHost.id(for: t)
        registry.addHost(.init(id: id, label: label.isEmpty ? t.host : label, transport: .ssh(t)))
        onDone()
    }
}
#endif
