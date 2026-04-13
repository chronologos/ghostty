#if os(macOS)
import SwiftUI

/// Host management sheet: rename · accent color · live zmx session list with kill.
struct HostDetailView: View {
    let host: ForkHost
    let onDone: () -> Void

    @EnvironmentObject private var registry: SessionRegistry
    @State private var label: String
    @State private var hue: Double?
    @State private var sessions = ZmxAdapter.ListResult()
    @State private var loading = true

    init(host: ForkHost, onDone: @escaping () -> Void) {
        self.host = host
        self.onDone = onDone
        self._label = State(initialValue: host.label)
        self._hue = State(initialValue: host.accentHue)
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
    }
}

/// Preset hue swatch row. `nil` = auto (hash-derived).
struct HuePicker: View {
    @Binding var hue: Double?
    private let presets: [Double] = [0.02, 0.08, 0.14, 0.28, 0.42, 0.55, 0.68, 0.80, 0.92]

    var body: some View {
        HStack(spacing: 6) {
            swatch(nil, label: "auto")
            ForEach(presets, id: \.self) { swatch($0) }
        }
    }

    private func swatch(_ h: Double?, label: String? = nil) -> some View {
        let selected = h == hue
        let color = h.map { Color(hue: $0, saturation: 0.45, brightness: 0.7) } ?? Color.secondary
        return Circle()
            .fill(h == nil ? AnyShapeStyle(.secondary.opacity(0.3)) : AnyShapeStyle(color))
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(selected ? Color.primary : .clear, lineWidth: 1.5))
            .help(label ?? "")
            .onTapGesture { hue = h }
    }
}
#endif
