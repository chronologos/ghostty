#if os(macOS)
import SwiftUI

/// Detail pane for `HostsView`: rename · accent · live zmx session list with kill.
/// No own chrome (padding/width/Done) — `HostsView` provides that. Edits save eagerly on
/// change — there is no Cancel.
struct HostDetailView: View {
    @Environment(\.forkTokens) private var tokens

    let host: ForkHost
    let onRemove: () -> Void

    @EnvironmentObject private var registry: SessionRegistry
    @State private var label: String
    @State private var slot: Int
    @State private var sessions = ZmxAdapter.ListResult()
    @State private var loading = true
    @State private var failure: ZmxAdapter.ListFailure?
    private var unreachable: Bool { failure != nil }
    @State private var killError: String?

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
                    .foregroundStyle(tokens.textSecondary)
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
                Text("Sessions").font(.subheadline).foregroundStyle(tokens.textSecondary)
                Spacer()
                Button { Task { await reload() } } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.borderless).disabled(loading)
            }
            // Absence of a sparkle must not read as "verified no agent": CC info only
            // exists for hosts the poll currently covers (toggle on + ≥1 sidebar tab).
            if !loading, !unreachable,
               registry.ccLive[host.id] == nil || !registry.tabs.contains(where: { $0.hostID == host.id }) {
                Text("CC status unknown for this host (not currently polled)")
                    .font(.caption2).foregroundStyle(tokens.textSecondary)
            }
            sessionList.frame(maxHeight: .infinity)

            if let killError {
                Text(killError).font(.caption).foregroundStyle(Theme.error).lineLimit(2)
            }

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
            HStack { ProgressView().controlSize(.small); Text("Listing…").foregroundStyle(tokens.textSecondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if unreachable {
            // Distinct from "No sessions": the query failed, so the sessions are very likely
            // still alive — saying "none" here is how people conclude their work is gone.
            // …and say which half failed: a zmx that's slow to list (a few sessions not
            // answering its 1s probe each) and an ssh that can't connect are fixed in
            // different places.
            Text("No list from \(host.label) — \(failure?.summary ?? "unknown error"). Then ⟳")
                .multilineTextAlignment(.center)
                .foregroundStyle(tokens.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sessions.managed.isEmpty && sessions.external.isEmpty && sessions.unresponsive.isEmpty {
            Text("No sessions").foregroundStyle(tokens.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(sessions.managed, id: \.name) { sessionRow($0) }
                ForEach(sessions.external, id: \.name) { sessionRow($0) }
                // Present but not answering. Listed so a failed Kill can't look like a
                // successful one (the row used to just vanish) and so there *is* a Kill
                // button for a session that's wedged.
                ForEach(sessions.unresponsive, id: \.self) { u in
                    HStack {
                        UnresponsiveSessionLabel(entry: u)
                        Spacer()
                        killButton(name: u.name, external: u.external)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func sessionRow(_ e: ZmxAdapter.ListEntry) -> some View {
        HStack {
            // Alias + demoted id (or id alone); Kill still keys on the id (`e.name`).
            VStack(alignment: .leading, spacing: 0) { SessionNameLabel(entry: e) }
            Spacer()
            SessionMetaLabel(entry: e,
                             inSidebar: registry.isInSidebar(e.name, external: e.external, on: host.id),
                             ccInfo: registry.ccInfo(for: e, on: host.id))
            killButton(name: e.name, external: e.external)
        }
    }

    private func killButton(name: String, external: Bool) -> some View {
        Button("Kill") {
            // No optimistic removal: a kill that fails (host briefly unreachable, daemon
            // not answering) must not leave the row missing while the session keeps
            // running — re-list and let reality drive the UI.
            Task {
                let ref = SessionRef(hostID: host.id, name: name, external: external)
                var recheck = false
                do {
                    // Already gone counts as done — the goal state holds.
                    recheck = try await ZmxAdapter.kill(host: host, ref: ref) == .unconfirmed
                    killError = nil
                } catch is CancellationError {
                    // The Kill message is already in the daemon's socket by the time zmx
                    // blocks waiting for the hang-up, so a busy daemon may still act on it.
                    killError = "Kill sent to \(name) but not confirmed (timed out) — it may still exit. Re-checking…"
                    recheck = true
                } catch {
                    killError = "Couldn't kill \(name) — \(String(describing: error))"
                }
                await reload()
                guard recheck else { return }
                try? await Task.sleep(for: .seconds(4))
                await reload()
                let still = sessions.presentKeys(hostID: host.id).contains(ref.key)
                killError = still ? "\(name) is still there — the kill didn't land (daemon not responding?)" : nil
            }
        }
        .buttonStyle(.borderless).foregroundStyle(Theme.error)
    }

    private func reload() async {
        loading = true
        switch await ZmxAdapter.listResult(host: host) {
        case .success(let r): failure = nil; sessions = r
        case .failure(let f): failure = f; sessions = .init()
        }
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
    @Environment(\.forkTokens) private var tokens

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
                            .stroke(s == slot ? tokens.text : .clear, lineWidth: Theme.ringWidth))
                        .onTapGesture { slot = s }
                }
            }
        }
    }
}
#endif
