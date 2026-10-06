#if os(macOS)
import AppKit
import SwiftUI

// The parts every fork surface outside the sidebar is built from — palette, pickers, Hosts,
// confirms, cheatsheet, popovers — so the look lives in one place and a new surface can't
// drift. Same rules as the sidebar: flat, opaque, cut corners, words rather than symbols,
// and nothing on screen that has to be explained.

// MARK: Type

private struct ForkFontFamilyKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The terminal's face, as far as the fork can read it (`Ghostty.Config.forkFontFamily`).
    /// Set by ``ForkThemed`` beside the tokens, for the same reason: a reload has to reach
    /// every view that drew with the old one.
    var forkFontFamily: String? {
        get { self[ForkFontFamilyKey.self] }
        set { self[ForkFontFamilyKey.self] = newValue }
    }
}

/// User's configured terminal face (so fork chrome reads as part of the grid, not a bolt-on
/// SwiftUI panel); falls back to system mono. `fixedSize` so Dynamic Type doesn't reflow.
func forkMono(_ size: CGFloat, _ weight: Font.Weight = .regular, _ family: String?) -> Font {
    if let family, !family.isEmpty {
        return .custom(family, fixedSize: size).weight(weight)
    }
    return .system(size: size, weight: weight, design: .monospaced)
}

private struct ForkFont: ViewModifier {
    @Environment(\.forkFontFamily) private var family
    let size: CGFloat
    let weight: Font.Weight
    func body(content: Content) -> some View { content.font(forkMono(size, weight, family)) }
}

extension View {
    /// `forkMono` without threading the family through every initializer. Returns `some View`,
    /// so `Text`-only modifiers (`kerning`, `+`) go before it.
    func forkFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        modifier(ForkFont(size: size, weight: weight))
    }
}

// MARK: Frame

/// What everything the fork floats over the terminal wears: a cut-corner frame on the
/// terminal's own ground, under a title strip (NAME · hatch · the chord that opens it) — a host
/// module's strip, one size up.
struct Panel<Content: View>: View {
    @Environment(\.forkTokens) private var tokens
    let title: String
    var chord: String?
    @ViewBuilder let content: Content

    static var cut: CGFloat { 10 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title.uppercased()).kerning(1).lineLimit(1)
                    .forkFont(11, .bold).layoutPriority(1)
                Hatch().stroke(tokens.text, lineWidth: 1)
                    .frame(minWidth: 0, maxWidth: .infinity).frame(height: 8).clipped()
                if let chord { Text(chord).forkFont(10, .semibold) }
            }
            .foregroundStyle(tokens.text)
            .padding(.horizontal, 12).frame(height: 26)
            tokens.text.frame(height: 1)
            content
        }
        .background(tokens.ground)
        .clipShape(Chamfer(cut: Self.cut))
        .overlay(Chamfer(cut: Self.cut).strokeBorder(tokens.text, lineWidth: 1))
    }
}

/// A quiet full-width hairline between a panel's sections.
struct PanelRule: View {
    @Environment(\.forkTokens) private var tokens
    var body: some View { tokens.rule.frame(height: 1) }
}

// MARK: Controls

/// Cut-corner key. `primary` is inverse video (what ⏎ does), `destructive` is red line and
/// label — never a red *fill*: the thing you might regret must not be the loudest thing there.
/// A `ButtonStyle`, not a view, so a `keyboardShortcut` on the button keeps working.
struct PanelButtonStyle: ButtonStyle {
    enum Kind { case plain, primary, destructive }
    var kind: Kind = .plain
    /// The key that presses it, shown on the cap. Display only — bind it separately.
    var chord: String?
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        Face(kind: kind, chord: chord, compact: compact, configuration: configuration)
    }

    private struct Face: View {
        @Environment(\.forkTokens) private var tokens
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false
        let kind: Kind
        let chord: String?
        let compact: Bool
        let configuration: Configuration

        var body: some View {
            let hue = kind == .destructive ? Theme.error : tokens.text
            let inverse = kind == .primary && enabled
            HStack(spacing: 8) {
                configuration.label.textCase(.uppercase).forkFont(compact ? 10 : 11, .bold)
                if let chord { Text(chord).forkFont(compact ? 9 : 10) }
            }
            .lineLimit(1)
            .foregroundStyle(!enabled ? tokens.inactive : inverse ? tokens.ground : hue)
            .padding(.horizontal, compact ? 6 : 10).frame(height: compact ? 18 : 24)
            .background(inverse ? tokens.text : configuration.isPressed ? tokens.rule : tokens.ground,
                        in: Chamfer(cut: compact ? 4 : 5))
            // A compact destructive key repeats down a list (Kill per session): red labels in
            // quiet frames, or the column of red boxes is the loudest thing on the panel.
            .overlay(Chamfer(cut: compact ? 4 : 5).strokeBorder(
                !enabled ? tokens.rule
                    : kind == .destructive && compact ? (hovered ? hue : tokens.rule)
                    : hovered ? tokens.bright : hue, lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
        }
    }
}

private struct PanelFieldChrome: ViewModifier {
    @Environment(\.forkTokens) private var tokens
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain).forkFont(13).foregroundStyle(tokens.bright).tint(tokens.text)
            .padding(.horizontal, 8).frame(height: 26)
            .overlay(Rectangle().strokeBorder(tokens.rule, lineWidth: 1))
    }
}

private struct PanelRowChrome: ViewModifier {
    @Environment(\.forkTokens) private var tokens
    let selected: Bool
    let hovered: Bool
    func body(content: Content) -> some View {
        content.overlay(Chamfer(cut: 5).strokeBorder(
            selected ? tokens.bright : hovered ? tokens.rule : .clear, lineWidth: 1))
    }
}

extension View {
    /// A boxed form field. On a `TextField`, which keeps its own `focused`/`onSubmit`.
    func panelField() -> some View { modifier(PanelFieldChrome()) }

    /// List selection, the sidebar's way: the selected row is the bright cut-corner outline
    /// the focused pane row wears, hover the same outline in the rule color. An outline rather
    /// than inverse video so whatever is *in* the row (lamps, host squares, red) keeps its color.
    func panelRow(selected: Bool, hovered: Bool = false) -> some View {
        modifier(PanelRowChrome(selected: selected, hovered: hovered))
    }
}

/// Force the enclosing `NSScrollView` to overlay (slim, auto-fading) scrollers even when
/// the system preference is "Always". The legacy 15pt gutter eats ~8% of a 200pt sidebar, and
/// insets every panel row's trailing edge from the frame.
/// AppKit resets `scrollerStyle` on `preferredScrollerStyleDidChange` (mouse hot-plug),
/// hence the observer, which goes with the view.
struct OverlayScroller: NSViewRepresentable {
    final class Probe: NSView {
        private var sub: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            sub.map(NotificationCenter.default.removeObserver); sub = nil
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.enclosingScrollView?.scrollerStyle = .overlay }
            sub = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.enclosingScrollView?.scrollerStyle = .overlay }
        }
        deinit { sub.map(NotificationCenter.default.removeObserver) }
    }
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_: NSView, context: Context) {}
}

/// `⏎ attach` — a footer's key legend. A key that does nothing right now goes inactive.
struct KeyHint: View {
    @Environment(\.forkTokens) private var tokens
    let key: String
    let label: String
    var enabled = true
    init(_ key: String, _ label: String, enabled: Bool = true) {
        self.key = key; self.label = label; self.enabled = enabled
    }
    var body: some View {
        HStack(spacing: 4) {
            Text(key).foregroundStyle(enabled ? tokens.text : tokens.inactive).forkFont(10, .bold)
            Text(label.uppercased()).kerning(0.5).foregroundStyle(tokens.inactive).forkFont(9)
        }
        .lineLimit(1).fixedSize()
    }
}

/// The `>` a query field or an action row leads with.
struct PromptMark: View {
    @Environment(\.forkTokens) private var tokens
    var size: CGFloat = 13
    var body: some View { Text(">").foregroundStyle(tokens.inactive).forkFont(size, .bold) }
}

// MARK: Confirm

/// The fork's alert: what is about to happen, to what, and a key per answer. Replaces `NSAlert`,
/// whose chrome can't be restyled.
///
/// The keys are *data*, matched by ``choice(for:modifiers:isRepeat:in:)`` from the presenting
/// panel's one key monitor — not `keyboardShortcut`s. These keys decide whether a session is
/// killed, so they get a rule that can be unit-tested rather than whatever a borderless window
/// with no first responder happens to route; and one rule can refuse auto-repeat for all of
/// them, so nothing held down from before the panel appeared can answer it.
struct ConfirmView: View {
    @Environment(\.forkTokens) private var tokens

    struct Key: Equatable {
        let characters: String
        var modifiers: NSEvent.ModifierFlags = []
        static let `return` = Key(characters: "\r")
        static let escape = Key(characters: "\u{1b}")
    }

    struct Choice: Identifiable {
        let id = UUID()
        let label: String
        /// Shown on the cap.
        let chord: String
        var kind: PanelButtonStyle.Kind = .plain
        let keys: [Key]
        var enabled = true
        let action: () -> Void
    }

    /// Which choice a key press means, if any. `characters` is
    /// `charactersIgnoringModifiers`. Only ⌘⇧⌥⌃ count as modifiers (Caps Lock, fn and the
    /// keypad flag don't make K a different key), case doesn't, and keypad Enter is Return.
    /// A disabled choice doesn't answer; neither does a repeat.
    static func choice(for characters: String?, modifiers: NSEvent.ModifierFlags, isRepeat: Bool,
                       in choices: [Choice]) -> Choice? {
        guard !isRepeat, var c = characters?.lowercased() else { return nil }
        if c == "\u{3}" { c = "\r" }
        let key = Key(characters: c, modifiers: modifiers.intersection([.command, .shift, .option, .control]))
        return choices.first { $0.enabled && $0.keys.contains(key) }
    }

    let title: String
    var chord: String?
    let headline: String
    let detail: String
    let choices: [Choice]

    static let width: CGFloat = 440

    var body: some View {
        Panel(title: title, chord: chord) {
            VStack(alignment: .leading, spacing: 10) {
                Text(headline).foregroundStyle(tokens.bright).forkFont(13, .bold)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail).foregroundStyle(tokens.text).forkFont(11).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ForEach(choices) { c in
                        Button(c.label, action: c.action)
                            .buttonStyle(PanelButtonStyle(kind: c.kind, chord: c.chord))
                            .disabled(!c.enabled)
                    }
                }
                .padding(.top, 4)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: Self.width)
    }
}
#endif
