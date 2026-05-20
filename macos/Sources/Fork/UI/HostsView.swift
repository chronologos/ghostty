#if os(macOS)
import SwiftUI

/// Master-detail "Hosts" sheet — list on the left (existing + "Add Host…"), detail on the
/// right (`HostDetailView` for an existing host, the new-host form otherwise). Replaces
/// `NewHostView` + the right-click-only "Manage Host…" entry point.
struct HostsView: View {
    enum Sel: Hashable { case host(ForkHost.ID), new }

    @EnvironmentObject private var registry: SessionRegistry
    @State private var sel: Sel?   // optional — `List(selection:)` writes nil on cmd-click
    /// `controller.removeHost`, not `registry.removeHost` — the latter would leak `liveTabs`/
    /// `progressSubs` and leave `surfaceTree` rendering the removed host's panes.
    let onRemove: (ForkHost.ID) -> Void
    let onDone: () -> Void

    init(select: ForkHost.ID? = nil, onRemove: @escaping (ForkHost.ID) -> Void,
         onDone: @escaping () -> Void) {
        self._sel = State(initialValue: select.map(Sel.host) ?? .new)
        self.onRemove = onRemove; self.onDone = onDone
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                master
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(20)
            }
            Divider()
            HStack {
                // Hidden — Done already saves (no discard semantics here), but `.cancelAction`
                // is what makes Esc dismiss a `beginSheet` panel.
                Button("", action: onDone).keyboardShortcut(.cancelAction).hidden()
                Spacer()
                Button("Done") { onDone() }.keyboardShortcut(.defaultAction)
            }.padding(12)
        }
        .frame(width: 640, height: 560)   // pinned here so `presentSheet(size:)` can't drift
    }

    private var master: some View {
        List(selection: $sel) {
            Section("Hosts") {
                ForEach(registry.hosts) { h in
                    Label {
                        Text(h.label).lineLimit(1)
                    } icon: {
                        HostDot(host: h, size: 12)
                    }
                    .tag(Sel.host(h.id))
                }
            }
            Label("Add Host…", systemImage: "plus").tag(Sel.new)
        }
        .listStyle(.sidebar)
        .frame(width: 180)
    }

    @ViewBuilder private var detail: some View {
        switch sel ?? .new {
        case .host(let id):
            // Look up fresh — `registry.hosts` mutates while open (rename, hue, removeHost).
            if let h = registry.host(id: id) {
                HostDetailView(host: h, onRemove: { onRemove(id); sel = .new })
                    .id(id)   // reset @State on selection change
            }
        case .new:
            newHostForm
        }
    }

    // MARK: New-host form

    @State private var label = ""
    @State private var connection = ""

    private var target: ForkHost.SSHTarget? { .init(parsing: connection) }
    private var newID: ForkHost.ID? { target.map(ForkHost.id(for:)) }
    private var dupe: Bool { newID.map { registry.host(id: $0) != nil } ?? false }
    /// Live preview of the slot `resolveAutoSlots` will land on — updates as the user types.
    private var previewSlot: Int {
        ForkHost.autoSlot(for: newID ?? "", avoiding: registry.takenSlots)
    }

    private var newHostForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Host").font(.headline)
            TextField("Connection", text: $connection, prompt: Text("user@host"))
                .textFieldStyle(.roundedBorder).onSubmit(add)
            TextField("Label", text: $label, prompt: Text("optional"))
                .textFieldStyle(.roundedBorder).onSubmit(add)
            HStack(spacing: 10) {
                HostDot(slot: previewSlot, size: 18)
                Text("Auto-assigned color (change after adding)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if dupe { Text("Already added.").font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Add", action: add).disabled(target == nil || dupe)
            }
        }
    }

    private func add() {
        guard let t = target, let id = newID, !dupe else { return }
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        registry.addHost(.init(id: id, label: name.isEmpty ? t.host : name, transport: .ssh(t)))
        sel = .host(id); label = ""; connection = ""
    }
}
#endif
