#if os(macOS)
import SwiftUI

struct TagEditView: View {
    @Environment(\.forkTokens) private var tokens

    @State var text: String
    @State var hue: Double
    let onCommit: (PaneTag?) -> Void

    private static let hues: [Double] = [0.0, 0.08, 0.14, 0.3, 0.5, 0.6, 0.75, 0.88]

    init(seed: PaneTag?, onCommit: @escaping (PaneTag?) -> Void) {
        _text = State(initialValue: seed?.text ?? "")
        _hue = State(initialValue: seed?.hue ?? Self.hues[0])
        self.onCommit = onCommit
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("tag", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !trimmed.isEmpty { onCommit(PaneTag(text: trimmed, hue: hue)) } }
            HStack(spacing: 6) {
                ForEach(Self.hues, id: \.self) { h in
                    let pebble = Pebble(tagHue: h)
                    pebble
                        .fill(Theme.tag(h))
                        .frame(width: 18, height: 18)
                        .overlay(pebble.strokeBorder(tokens.text, lineWidth: hue == h ? Theme.ringWidth : 0))
                        .onTapGesture { hue = h }
                }
            }
            HStack {
                Button("Clear") { onCommit(nil) }
                Spacer()
                Button("Set") { onCommit(PaneTag(text: trimmed, hue: hue)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 200)
    }
}
#endif
