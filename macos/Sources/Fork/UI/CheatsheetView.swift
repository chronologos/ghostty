#if os(macOS)
import SwiftUI

/// Slack-style shortcut overlay shown after holding ⌘ ≥600ms (controller's
/// flagsChanged monitor + debounce). Static content; controller toggles the
/// hosting `NSView.isHidden`.
struct CheatsheetView: View {
    let hoverCommands: [String: HoverCommand]

    private static let rows: [(String, String)] = [
        ("⌘T", "New session"),
        ("⌘D", "Split pane"),
        ("⌘W", "Close pane"),
        ("⌘K", "Command palette"),
        ("⌘⇧K", "Scrollback search"),
        ("⌘I / ⌘⇧I", "Rename pane / tab"),
        ("⌘⇧[ / ⌘⇧]", "Prev / next tab"),
        ("⌘1–9", "Jump to tab"),
        ("⌘⌥1–9", "Jump to host"),
        ("⌘[ / ⌘]", "Prev / next split"),
        ("⌘⌥A", "Watch pane (notify on idle)"),
        ("⌘⇧B", "Toggle sidebar"),
        ("hover + k/r/c/t/p/n/h", "kill / repaint / clear-tag / tag / pin / sync-cc-name / hide"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.rows, id: \.0) { k, l in row(k, l) }
            ForEach(hoverCommands.sorted { $0.key < $1.key }, id: \.key) { key, hc in
                row("hover + \(key)", hc.cmd.joined(separator: " "))
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .shadow(radius: 12)
    }

    private func row(_ key: String, _ label: String) -> some View {
        HStack(spacing: 12) {
            Text(key).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 110, alignment: .leading)
            Text(label).font(.system(size: 11)).lineLimit(1)
        }
    }
}
#endif
