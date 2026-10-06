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
            TextField("", text: $text, prompt: Text("tag").foregroundColor(tokens.inactive))
                .panelField()
                .onSubmit { if !trimmed.isEmpty { onCommit(PaneTag(text: trimmed, hue: hue)) } }
            HStack(spacing: 6) {
                ForEach(Self.hues, id: \.self) { h in
                    Theme.tag(h)
                        .frame(width: 18, height: 18)
                        // Ring outside the swatch, on the ground, so it reads on every hue.
                        .padding(3)
                        .overlay(Rectangle().strokeBorder(hue == h ? tokens.bright : .clear, lineWidth: 1))
                        .onTapGesture { hue = h }
                }
            }
            HStack {
                Button("Clear") { onCommit(nil) }.buttonStyle(PanelButtonStyle())
                Spacer()
                Button("Set") { onCommit(PaneTag(text: trimmed, hue: hue)) }
                    .buttonStyle(PanelButtonStyle(kind: .primary, chord: "⏎"))
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 252)
        // Scaled past the edges so the popover's arrow takes the color too.
        .background(tokens.ground.scaleEffect(1.5))
    }
}
#endif
