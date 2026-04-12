#if os(macOS)
import SwiftUI

struct NewSessionIntent {
    var hostID: ForkHost.ID
    var name: String?
    var cwd: String?
    var cmd: [String]?
}

/// ⌘T sheet: host picker · form · recents (SPEC §9).
struct NewSessionView: View {
    @EnvironmentObject private var registry: SessionRegistry

    @State private var hostID: ForkHost.ID
    @State private var name: String = ""
    @State private var cwd: String = ""
    @State private var command: String = ""
    @State private var recents: [String] = []

    let onSubmit: (NewSessionIntent) -> Void
    let onCancel: () -> Void

    init(defaultHostID: ForkHost.ID,
         onSubmit: @escaping (NewSessionIntent) -> Void,
         onCancel: @escaping () -> Void) {
        self._hostID = State(initialValue: defaultHostID)
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            hostList.frame(width: 160)
            Divider()
            form.frame(width: 280)
            Divider()
            recentsList.frame(width: 200)
        }
        .frame(height: 320)
        .task(id: hostID) {
            guard let h = registry.host(id: hostID) else { return }
            recents = await ZmxAdapter.list(host: h)
        }
    }

    private var hostList: some View {
        List(registry.hosts, selection: Binding(get: { hostID }, set: { hostID = $0 ?? hostID })) { h in
            HStack {
                Circle().fill(registry.isConnected(h.id) ? .green : .secondary).frame(width: 6, height: 6)
                Text(h.label)
            }
            .tag(h.id)
        }
        .listStyle(.sidebar)
    }

    private var form: some View {
        Form {
            TextField("Name", text: $name, prompt: Text(SessionRegistry.autoName()))
            TextField("Working dir (local only)", text: $cwd)
            TextField("Command", text: $command)
            HStack {
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Connect") { submit(name: name.isEmpty ? nil : name) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    private var recentsList: some View {
        List(recents, id: \.self) { n in
            Button(n) { submit(name: n) }.buttonStyle(.plain)
        }
        .overlay { if recents.isEmpty { Text("No sessions").foregroundStyle(.secondary) } }
    }

    private func submit(name: String?) {
        let cmdArr = command.isEmpty ? nil : command.split(separator: " ").map(String.init)
        onSubmit(.init(
            hostID: hostID,
            name: name,
            cwd: cwd.isEmpty ? nil : cwd,
            cmd: cmdArr))
    }
}
#endif
