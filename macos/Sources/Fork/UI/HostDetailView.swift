#if os(macOS)
import SwiftUI

/// Detail pane for `HostsView`: rename · accent · live zmx session list with kill.
/// No own chrome (padding/width/Done) — `HostsView` provides that. Edits save eagerly on
/// change — there is no Cancel.
struct HostDetailView: View {
    let host: ForkHost
    let onRemove: () -> Void

    @EnvironmentObject private var registry: SessionRegistry
    @State private var label: String
    @State private var slot: Int
    @State private var sessions = ZmxAdapter.ListResult()
    @State private var loading = true

    init(host: ForkHost, onRemove: @escaping () -> Void) {
        self.host = host; self.onRemove = onRemove
        self._label = State(initialValue: host.label)
        self._slot = State(initialValue: host.slot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(host.label).font(.headline)
                Spacer()
                Text(host.transport.displayConnection).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            TextField("Label", text: $label).textFieldStyle(.roundedBorder)
            // Collapsed by default — the 10×10 grid is ~236pt and would squash `sessionList`
            // to nothing; sessions are the primary content here.
            DisclosureGroup {
                SlotPicker(slot: $slot, hostID: host.id).padding(.top, 6)
            } label: {
                HStack(spacing: 8) { HostDot(slot: slot, size: 14); Text("Color") }
            }

            Divider()

            HStack {
                Text("Sessions").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await reload() } } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.borderless).disabled(loading)
            }
            sessionList.frame(maxHeight: .infinity)

            if host.id != ForkHost.local.id {
                Button("Remove Host", role: .destructive, action: onRemove)
            }
        }
        .task { await reload() }
        // Eager saves — `.onDisappear` never fires when `endSheet` releases the panel, and
        // ⏎/focus-loss both miss the click-Done-while-still-editing path. Per-change is the
        // only hook that covers every exit; the registry publish per keystroke is measured
        // cheap (sidebar body re-eval, n≤20 hosts) and fork.json writes stay 500ms-debounced.
        .onChange(of: label) { _ in save() }
        .onChange(of: slot) { _ in save() }
    }

    @ViewBuilder private var sessionList: some View {
        if loading {
            HStack { ProgressView().controlSize(.small); Text("Listing…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sessions.managed.isEmpty && sessions.external.isEmpty {
            Text("No sessions").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(sessions.managed, id: \.name) { sessionRow($0) }
                ForEach(sessions.external, id: \.name) { sessionRow($0) }
            }
            .listStyle(.plain)
        }
    }

    private func sessionRow(_ e: ZmxAdapter.ListEntry) -> some View {
        HStack {
            Text(e.name).font(.system(size: 12, design: .monospaced))
            Spacer()
            SessionMetaLabel(entry: e)
            Button("Kill") {
                if e.external { sessions.external.removeAll { $0.name == e.name } }
                else { sessions.managed.removeAll { $0.name == e.name } }
                Task {
                    let ref = SessionRef(hostID: host.id, name: e.name, external: e.external)
                    try? await ZmxAdapter.kill(host: host, ref: ref)
                }
            }
            .buttonStyle(.borderless).foregroundStyle(.red)
        }
    }

    private func reload() async {
        loading = true
        sessions = await ZmxAdapter.list(host: host)
        loading = false
    }

    private func save() {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if name != host.label && !name.isEmpty { registry.renameHost(host.id, to: name) }
        if slot != host.accentSlot { registry.setAccentSlot(host.id, slot) }
    }
}

/// N×N grid (solids on the diagonal) + "Auto" chip. Auto's `own` reads the *stored* slot
/// so a swatch tap before Auto doesn't subtract the wrong one.
struct SlotPicker: View {
    @Binding var slot: Int
    let hostID: ForkHost.ID
    @EnvironmentObject private var registry: SessionRegistry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Auto") {
                // Exclude by id, not by subtracting the slot value — `takenSlots` is a Set,
                // so subtracting a value another host also holds would erase its claim.
                let others = Set(registry.hosts.lazy.filter { $0.id != hostID }
                    .compactMap(\.accentSlot))
                slot = ForkHost.autoSlot(for: hostID, avoiding: others)
            }
            .buttonStyle(.link).font(.caption)
            LazyVGrid(columns: Array(repeating: .init(.fixed(20), spacing: 4), count: ForkHost.N),
                      alignment: .leading, spacing: 4) {
                ForEach(0..<ForkHost.slotCount, id: \.self) { s in
                    HostDot(slot: s, size: 18)
                        .overlay(HostDot.outline(slot: s)
                            .stroke(s == slot ? Color.primary : .clear, lineWidth: Theme.ringWidth))
                        .onTapGesture { slot = s }
                }
            }
        }
    }
}
#endif
