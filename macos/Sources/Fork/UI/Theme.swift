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

/// Organic almost-circle — two low-amplitude sine harmonics perturb the radius so each seed
/// gets its own stable pebble silhouette. Seeded (not random-per-render) on purpose: rows
/// re-render on every probe tick and a shimmering dot reads as activity. Harmonics are
/// integer multiples of the angle, so the outline closes without a seam.
struct Pebble: InsettableShape {
    var seed: Int
    var insetAmount: CGFloat = 0
    func inset(by amount: CGFloat) -> Pebble {
        var c = self; c.insetAmount += amount; return c
    }
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard r.width > 0, r.height > 0 else { return Path() }
        let p1 = Double(seed) * 1.7, p2 = Double(seed) * 2.9
        let n = 10
        let pts = (0..<n).map { i -> CGPoint in
            let t = Double(i) / Double(n) * 2 * .pi
            let wobble = 0.96 + 0.065 * sin(2 * t + p1) + 0.045 * sin(3 * t + p2)
            return CGPoint(x: r.midX + cos(t) * r.width / 2 * wobble,
                           y: r.midY + sin(t) * r.height / 2 * wobble)
        }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { .init(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        var path = Path()
        path.move(to: mid(pts[n - 1], pts[0]))
        for i in 0..<n {
            path.addQuadCurve(to: mid(pts[i], pts[(i + 1) % n]), control: pts[i])
        }
        path.closeSubpath()
        return path
    }
}

extension Pebble {
    /// Tag pebbles are seeded from the tag hue — the swatch picked in TagEditView is the
    /// exact silhouette the sidebar row wears. Keep the hue→seed mapping here only.
    init(tagHue: Double) { self.init(seed: Int(tagHue * 97)) }
}

/// Hand-cut card corners — four slightly different radii (quad curves, a touch softer than
/// arcs) so the card chrome reads as cut by hand rather than die-stamped.
struct HandCut: Shape {
    var tl: CGFloat = 8, tr: CGFloat = 4, br: CGFloat = 9, bl: CGFloat = 5
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: .init(x: r.minX + tl, y: r.minY))
        p.addLine(to: .init(x: r.maxX - tr, y: r.minY))
        p.addQuadCurve(to: .init(x: r.maxX, y: r.minY + tr), control: .init(x: r.maxX, y: r.minY))
        p.addLine(to: .init(x: r.maxX, y: r.maxY - br))
        p.addQuadCurve(to: .init(x: r.maxX - br, y: r.maxY), control: .init(x: r.maxX, y: r.maxY))
        p.addLine(to: .init(x: r.minX + bl, y: r.maxY))
        p.addQuadCurve(to: .init(x: r.minX, y: r.maxY - bl), control: .init(x: r.minX, y: r.maxY))
        p.addLine(to: .init(x: r.minX, y: r.minY + tl))
        p.addQuadCurve(to: .init(x: r.minX + tl, y: r.minY), control: .init(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Shared card chrome (focus-mode tab cards, host-section cards).
struct ForkCard: ViewModifier {
    var fill: Color? = nil
    var hPad: CGFloat = 6
    func body(content: Content) -> some View {
        content
            .padding(6)
            .background(fill ?? .clear, in: HandCut())
            .overlay(HandCut()
                .stroke(Theme.cardBorder, lineWidth: 0.5))
            .padding(.horizontal, hPad)
    }
}
#endif
