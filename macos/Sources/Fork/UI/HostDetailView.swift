#if os(macOS)
import SwiftUI

/// Host management sheet: rename · accent color · live zmx session list with kill.
struct HostDetailView: View {
    let host: ForkHost
    let onDone: () -> Void

    @EnvironmentObject private var registry: SessionRegistry
    @State private var label: String
    @State private var hue: Double?
    @State private var icon: String?
    @State private var sessions = ZmxAdapter.ListResult()
    @State private var loading = true

    init(host: ForkHost, onDone: @escaping () -> Void) {
        self.host = host
        self.onDone = onDone
        self._label = State(initialValue: host.label)
        self._hue = State(initialValue: host.accentHue)
        self._icon = State(initialValue: host.icon)
    }

    private var previewAccent: Color {
        var h = host; h.accentHue = hue; return h.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Manage Host").font(.headline)
                Spacer()
                Text(connectionString).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            TextField("Label", text: $label)

            HuePicker(hue: $hue)
            IconPicker(icon: $icon, tint: previewAccent)

            Divider()

            HStack {
                Text("Sessions").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await reload() } } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.borderless).disabled(loading)
            }
            sessionList.frame(height: 160)

            HStack {
                Button("Cancel") { onDone() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Done") { save(); onDone() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding().frame(width: 420)
        .task { await reload() }
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

    private var connectionString: String {
        switch host.transport {
        case .local: "local"
        case .ssh(let t): t.connectionString
        }
    }

    private func reload() async {
        loading = true
        sessions = await ZmxAdapter.list(host: host)
        loading = false
    }

    private func save() {
        if label != host.label && !label.isEmpty { registry.renameHost(host.id, to: label) }
        if hue != host.accentHue { registry.setAccentHue(host.id, hue) }
        if icon != host.icon { registry.setIcon(host.id, icon) }
    }
}

/// Curated SF Symbol palette. `nil` = no icon (sidebar falls back to the connection dot).
struct IconPicker: View {
    @Binding var icon: String?
    let tint: Color
    private static let presets = ["server.rack", "desktopcomputer", "laptopcomputer", "cloud.fill",
                                  "globe", "bolt.fill", "cpu", "terminal", "network", "house.fill"]

    var body: some View {
        HStack(spacing: 6) {
            cell(nil)
            ForEach(Self.presets, id: \.self) { cell($0) }
        }
    }

    private func cell(_ name: String?) -> some View {
        let selected = name == icon
        return Image(systemName: name ?? "circle.dashed")
            .font(.system(size: 13))
            .foregroundStyle(name == nil ? Color.secondary : tint)
            .frame(width: 22, height: 22)
            .background(selected ? Color.primary.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture { icon = name }
            .help(name ?? "none")
    }
}

/// Preset hue swatch row. `nil` = auto (hash-derived).
struct HuePicker: View {
    @Binding var hue: Double?
    private static let presets: [Double] = [0.02, 0.08, 0.14, 0.28, 0.42, 0.55, 0.68, 0.80, 0.92]

    var body: some View {
        HStack(spacing: 6) {
            swatch(nil)
            ForEach(Self.presets, id: \.self) { swatch($0) }
        }
    }

    private func swatch(_ h: Double?) -> some View {
        let selected = h == hue
        let color = h.map { Color(hue: $0, saturation: 0.45, brightness: 0.7) } ?? Color.secondary
        return Circle()
            .fill(h == nil ? AnyShapeStyle(.secondary.opacity(0.3)) : AnyShapeStyle(color))
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(selected ? Color.primary : .clear, lineWidth: 1.5))
            .help(h == nil ? "auto" : "")
            .onTapGesture { hue = h }
    }
}
#endif
