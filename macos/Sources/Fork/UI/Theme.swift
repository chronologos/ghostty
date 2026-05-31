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
    /// Error text / destructive controls in sheets. Same hue as `blocked` today, but a
    /// separate role — "this operation failed" vs "this pane needs you" — so retuning one
    /// can't silently restyle the other.
    static let error = Color.red

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

    // MARK: Afterglow / doze — recency without an age column. Discrete buckets (not a
    // continuous fade) for the same reason Pebble is seeded: rows redraw on every probe
    // tick, and a creeping value reads as activity.
    /// Short-term trail on the row background — "where was I just now". Tighter breakpoints
    /// than `ramp` (5m/15m, not 5m/1h): after an hour this is history, not a trail. Sits
    /// below `selectedRow` (clay 0.20/0.14) so selection still reads as the strongest wash.
    static func afterglow(_ d: Date?) -> Color {
        let a = age(d)
        return a < 300 ? clay.opacity(0.09) : a < 900 ? clay.opacity(0.045) : .clear
    }
    /// Whole-row content opacity for the long tail. `cutoff` is the focus-mode cutoff in
    /// seconds — "asleep" reuses the user's own definition of "too old to care about".
    /// `nil` (never touched) is awake, not ancient — the opposite default from `spineHeat`.
    static func doze(_ d: Date?, cutoff: TimeInterval) -> Double {
        guard let d else { return 1 }
        let a = age(d)
        return a < 3600 ? 1 : a < cutoff ? 0.82 : 0.55
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
    /// Hue is decode-clamped (`PaneTag.init(from:)`) but harden here too: `Int(_:Double)`
    /// traps on NaN/±inf/out-of-range, and a trap here repeats for every tagged row — a
    /// hand-edited fork.json could brick launch.
    init(tagHue: Double) {
        let h = tagHue.isFinite ? min(max(tagHue, 0), 1) : 0
        self.init(seed: Int(h * 97))
    }
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
