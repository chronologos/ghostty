#if os(macOS)
import SwiftUI

/// Semantic style tokens — each *role* resolves to one value so call sites can't drift.
enum Theme {
    /// Fork brand accent — warm terracotta. The ONLY "active/on" tint; system
    /// `Color.accentColor` is *not* used (it's user-theme blue and clashes).
    static let clay = Color(red: 0xD9/255, green: 0x77/255, blue: 0x57/255)

    // MARK: Chrome (all `primary.opacity(x)` literals collapse to these four)
    static let hover      = Color.primary.opacity(0.06)
    static let chipBg     = Color.primary.opacity(0.08)
    static let cardBorder = Color.secondary.opacity(0.15)
    static let selectedRow = adaptive(light: NSColor(clay).withAlphaComponent(0.20),
                                      dark: NSColor(clay).withAlphaComponent(0.14))
    static let hostCardBg  = adaptive(light: .controlBackgroundColor.withAlphaComponent(0.6),
                                      dark: .black.withAlphaComponent(0.18))

    /// Self-adapting `Color` so callers don't need `@Environment(\.colorScheme)`.
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) {
            $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: Status
    static let blocked = Color.red

    // MARK: Host accent — single fallback
    static func hostAccent(_ h: ForkHost?) -> Color { h?.accent ?? .secondary }

    // MARK: Tags — one scheme-adaptive formula
    static func tag(_ hue: Double) -> Color {
        adaptive(light: NSColor(hue: hue, saturation: 0.6, brightness: 0.45, alpha: 1),
                 dark:  NSColor(hue: hue, saturation: 0.6, brightness: 0.55, alpha: 1))
    }

    // MARK: Spine heat / age — both share the same recency→opacity ramp. `Date?` overloads
    // so call sites don't repeat the `Date().timeIntervalSince` shim.
    private static func ramp<T>(_ age: TimeInterval,
                                _ v: @autoclosure () -> T, _ v1: @autoclosure () -> T,
                                _ v2: @autoclosure () -> T) -> T {
        age < 300 ? v() : age < 3600 ? v1() : v2()
    }
    private static func age(_ d: Date?) -> TimeInterval { d.map { Date().timeIntervalSince($0) } ?? .infinity }
    static func spineHeat(_ d: Date?) -> Color {
        ramp(age(d), .secondary, .secondary.opacity(0.6), .secondary.opacity(0.35))
    }
    static func ageStyle(_ d: Date?) -> AnyShapeStyle {
        ramp(age(d), AnyShapeStyle(.primary), AnyShapeStyle(.secondary), AnyShapeStyle(.tertiary))
    }

    // MARK: Swatch selection ring
    static let ringWidth: CGFloat = 1.5
}

/// Shared card chrome (focus-mode tab cards, host-section cards).
struct ForkCard: ViewModifier {
    var fill: Color? = nil
    var hPad: CGFloat = 6
    func body(content: Content) -> some View {
        content
            .padding(6)
            .background(fill ?? .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.cardBorder, lineWidth: 0.5))
            .padding(.horizontal, hPad)
    }
}
#endif
