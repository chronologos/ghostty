#if os(macOS)
import SwiftUI

struct NewSessionIntent {
    var hostID: ForkHost.ID
    var name: String?
    var cwd: String?
    var cmd: [String]?
    var external: Bool = false
}

/// ⌘T sheet: host picker · form · recents (SPEC §9).
struct NewSessionView: View {
    @EnvironmentObject private var registry: SessionRegistry

    @State private var hostID: ForkHost.ID
    @State private var name: String = ""
    @State private var cwd: String = ""
    @State private var command: String = ""
    @State private var recents: ZmxAdapter.ListResult?
    @State private var placeholder: String = ""

    private var nameValid: Bool {
        name.isEmpty || SessionRef(hostID: hostID, name: name).isValid
    }

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
        .onAppear { placeholder = registry.uniqueAutoName() }
        .task(id: hostID) {
            recents = nil
            guard let h = registry.host(id: hostID) else { return }
            let r = await ZmxAdapter.list(host: h)
            guard !Task.isCancelled else { return }
            recents = r
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
        VStack(alignment: .leading, spacing: 14) {
            field("Name", $name, prompt: placeholder)
            field("Working directory (local only)", $cwd, prompt: "~")
            field("Command", $command, prompt: "optional")
            Spacer()
            HStack {
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Connect") { submit(name: name.isEmpty ? placeholder : name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!nameValid)
            }
        }
        .padding()
    }

    private func field(_ label: String, _ binding: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("", text: binding, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder private var recentsList: some View {
        if let recents {
            List {
                if !recents.managed.isEmpty {
                    Section("Recent") {
                        ForEach(recents.managed, id: \.self) { n in
                            Button(n) { submit(name: n) }.buttonStyle(.plain)
                        }
                    }
                }
                if !recents.external.isEmpty {
                    Section("Other zmx sessions") {
                        ForEach(recents.external, id: \.self) { n in
                            Button(n) { submit(name: n, external: true) }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .overlay {
                if recents.managed.isEmpty && recents.external.isEmpty {
                    Text("No sessions").foregroundStyle(.secondary)
                }
            }
        } else {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func submit(name: String?, external: Bool = false) {
        let cmdArr = command.isEmpty ? nil : command.split(separator: " ").map(String.init)
        onSubmit(.init(
            hostID: hostID,
            name: name,
            cwd: cwd.isEmpty ? nil : cwd,
            cmd: cmdArr,
            external: external))
    }
}
#endif
