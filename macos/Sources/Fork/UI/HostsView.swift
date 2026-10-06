#if os(macOS)
import SwiftUI

/// Master-detail "Hosts" sheet — list on the left (existing + "Add Host…"), detail on the
/// right (`HostDetailView` for an existing host, the new-host form otherwise). Replaces
/// `NewHostView` + the right-click-only "Manage Host…" entry point.
struct HostsView: View {
    @Environment(\.forkTokens) private var tokens

    enum Sel: Hashable { case host(ForkHost.ID), new }

    @EnvironmentObject private var registry: SessionRegistry
    @State private var sel: Sel
    /// `controller.removeHost`, not `registry.removeHost` — the latter would leak `liveTabs`/
    /// `progressSubs` and leave `surfaceTree` rendering the removed host's panes.
    let onRemove: (ForkHost.ID) -> Void
    let onDone: () -> Void
    /// Handed to `HostDetailView`. Injected only by offscreen renders.
    let lister: ZmxAdapter.Lister

    static let size = CGSize(width: 680, height: 560)

    init(select: ForkHost.ID? = nil, lister: @escaping ZmxAdapter.Lister = ZmxAdapter.liveLister,
         onRemove: @escaping (ForkHost.ID) -> Void, onDone: @escaping () -> Void) {
        self._sel = State(initialValue: select.map(Sel.host) ?? .new)
        self.lister = lister
        self.onRemove = onRemove; self.onDone = onDone
    }

    var body: some View {
        Panel(title: "Hosts") {
            HStack(spacing: 0) {
                master
                tokens.rule.frame(width: 1)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
            }
            PanelRule()
            HStack {
                // Hidden — Done already saves (no discard semantics here), but `.cancelAction`
                // is what makes Esc dismiss the panel.
                Button("", action: onDone).keyboardShortcut(.cancelAction).hidden()
                Spacer()
                Button("Done") { onDone() }
                    .buttonStyle(PanelButtonStyle(kind: .primary, chord: "⏎"))
                    .keyboardShortcut(.defaultAction)
            }.padding(10)
        }
        .frame(width: Self.size.width, height: Self.size.height)   // the one size `showHostsSheet` reads
    }

    /// Drawn, not a `List(.sidebar)`: that brings its own material, selection pill and accent.
    private var master: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(registry.hosts) { h in
                    masterRow(.host(h.id)) {
                        HostDot(host: h, size: 8)
                        Text(h.label).lineLimit(1)
                    }
                }
                PanelRule().padding(.vertical, 4)
                masterRow(.new) { Text("+ ADD HOST").kerning(0.6) }
            }
            .padding(6)
            .background(OverlayScroller())
        }
        .frame(width: 180)
    }

    private func masterRow<C: View>(_ target: Sel, @ViewBuilder _ content: () -> C) -> some View {
        Button { sel = target } label: {
            HStack(spacing: 8) { content() }
                .foregroundStyle(sel == target ? tokens.bright : tokens.text)
                .forkFont(12, sel == target ? .bold : .regular)
                .padding(.horizontal, 8).frame(height: 26)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelRow(selected: sel == target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var detail: some View {
        switch sel {
        case .host(let id):
            // Look up fresh — `registry.hosts` mutates while open (rename, hue, removeHost).
            if let h = registry.host(id: id) {
                HostDetailView(host: h, lister: lister, onRemove: { onRemove(id); sel = .new })
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
        VStack(alignment: .leading, spacing: 12) {
            Text("ADD HOST").kerning(1).foregroundStyle(tokens.bright).forkFont(12, .bold)
            TextField("", text: $connection, prompt: Text("user@host").foregroundColor(tokens.inactive))
                .panelField().onSubmit(add)
            TextField("", text: $label, prompt: Text("label (optional)").foregroundColor(tokens.inactive))
                .panelField().onSubmit(add)
            HStack(spacing: 10) {
                HostDot(slot: previewSlot, size: 14)
                Text("Auto-assigned color (change after adding)")
                    .foregroundStyle(tokens.inactive).forkFont(10)
            }
            if dupe { Text("Already added.").foregroundStyle(Theme.error).forkFont(10) }
            HStack {
                Spacer()
                Button("Add", action: add).buttonStyle(PanelButtonStyle()).disabled(target == nil || dupe)
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
