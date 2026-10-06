#if os(macOS)
import SwiftUI

/// Slack-style shortcut overlay shown after holding a solo ⌥ ≥0.5s — the same peek the
/// sidebar's `OptionGestureRecognizer` uses to reveal read CC status text, so one hold
/// opens both. Static content; the controller toggles the hosting `NSView.isHidden` via
/// `setCheatsheet`, driven by that recognizer's `onPeek`.
struct CheatsheetView: View {
    @Environment(\.forkTokens) private var tokens
    let hoverCommands: [String: HoverCommand]

    private static let rows: [(String, String)] = [
        ("⌘T", "New session"),
        ("⌘D", "Split pane"),
        ("⌘W", "Close pane (Detach / Kill)"),
        ("⌘W ⌘W", "Kill instead of detach"),
        ("⌘⇧T", "New session (full form, any host)"),
        ("⌘K", "Command palette"),
        ("⌘⇧K", "Scrollback search"),
        ("⌘I / ⌘⇧I", "Rename pane / tab"),
        ("⌘⇧[ / ⌘⇧]", "Prev / next tab"),
        ("⌘1–9", "Jump to tab"),
        ("⌘⌥1–9", "Jump to host"),
        ("⌘[ / ⌘]", "Prev / next split"),
        ("⌘⌥A", "Watch pane (notify when finished)"),
        ("⌘⇧R", "Repaint pane"),
        ("⌘⌥P", "Pin / unpin tab"),
        ("⌘⇧B", "Toggle sidebar"),
        ("Drag sidebar edge", "Resize sidebar"),
        ("⌥ hold", "This sheet + reveal read CC status text"),
        ("⌥⌥", "Mark all CC status read"),
        ("Hover pane ⅓s", "Peek — status · dir · zmx name · age"),
        ("Long-press FOCUS", "Focus cutoff & sort options"),
        ("Mouse ⏴ ⏵", "Back / forward in tab history"),
        ("⇧⏎ in picker", "New session at z-jump dir"),
    ]

    var body: some View {
        Panel(title: "Keys", chord: "⌥ hold") {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Self.rows, id: \.0) { k, l in row(k, l) }
                ForEach(hoverCommands.sorted { $0.key < $1.key }, id: \.key) { key, hc in
                    row("⌘K → \(hc.cmd.first ?? key)", hc.cmd.joined(separator: " "))
                }
            }
            .padding(14)
        }
        .fixedSize()
    }

    private func row(_ key: String, _ label: String) -> some View {
        HStack(spacing: 12) {
            Text(key).foregroundStyle(tokens.bright).forkFont(11, .bold)
                .frame(width: 130, alignment: .leading)
            Text(label).foregroundStyle(tokens.text).lineLimit(1).forkFont(11)
        }
    }
}
#endif
