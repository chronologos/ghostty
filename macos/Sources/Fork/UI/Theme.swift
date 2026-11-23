#if os(macOS)
import AppKit
import SwiftUI

/// Constant style tokens — each *role* resolves to one value so call sites can't drift.
///
/// Everything here is theme-*independent*. The terminal-derived half of the palette lives in
/// ``ForkTokens`` and arrives through `\.forkTokens`; it is deliberately unreachable from
/// here, so a view can't read a themed color without declaring the dependency that
/// invalidates it.
enum Theme {
    // MARK: Status
    /// Pure red rather than `Color.red`: the system red is tuned to sit in Apple's palette and
    /// shifts with the appearance; a lamp on the terminal's own background wants the flat one.
    static let blocked = Color(red: 1, green: 0, blue: 0)
    /// Error text / destructive controls in sheets. Same hue as `blocked` today, but a
    /// separate role — "this operation failed" vs "this pane needs you" — so retuning one
    /// can't silently restyle the other.
    static let error = Color(red: 1, green: 0, blue: 0)

    // MARK: Sleep — recency without an age column. A discrete bucket (not a
    // continuous fade): rows redraw on every probe
    // tick, and a creeping value reads as activity. Not an alpha: nothing in the
    // sidebar is translucent, so it is carried by a *color role* (`ForkTokens.inactive`).
    // (There was also a short-term trail — the three panes before this one, first as a clay
    // afterglow, then as a corner cut. It never earned its ink; mouse ⏴/⏵ and ⌘K Back walk
    // the same history.)
    private static func age(_ d: Date?) -> TimeInterval { d.map { Date().timeIntervalSince($0) } ?? .infinity }
    /// The long tail: is this pane past caring about? `cutoff` is the focus-mode cutoff in
    /// seconds — "asleep" reuses the user's own definition of "too old to care about".
    /// `nil` (never touched) is awake, not ancient. One step, where the old opacity ramp had
    /// two (rested at an hour, asleep at the cutoff): a flat palette has one "inactive".
    static func asleep(_ d: Date?, cutoff: TimeInterval) -> Bool {
        guard let d else { return false }
        return age(d) >= max(cutoff, 3600)
    }

    // MARK: Tags — one appearance-adaptive formula
    /// Tag pill tint. Nothing here is terminal-derived: the hue is the user's pick and only
    /// the brightness bends, with the *appearance* — so this lives on `Theme`, and a tag
    /// swatch takes no `\.forkTokens` dependency.
    static func tag(_ hue: Double) -> Color {
        appearanceAdaptive(light: NSColor(hue: hue, saturation: 1, brightness: 0.6, alpha: 1),
                           dark: NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1))
    }

    /// Self-adapting `Color` so callers don't need `@Environment(\.colorScheme)` — it resolves
    /// against the view's own `NSAppearance` at render time. The right tool for any role whose
    /// value isn't derived from the terminal; a terminal-derived one belongs in ``ForkTokens``,
    /// where the polarity is already decided.
    static func appearanceAdaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) {
            $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: Hover peek — the in-row expansion that replaced the pane-row tooltip.
    /// The cursor must *rest* on a row this long before it exhales open — casual passes
    /// and scroll-throughs (rows changing under a still cursor) never trigger it.
    static let peekDelay: TimeInterval = 0.35
    /// Row growth when the peek opens — a soft spring with a hint of overshoot, so the
    /// row reads as exhaling rather than snapping.
    static let exhale = Animation.spring(response: 0.32, dampingFraction: 0.78)
    /// Peek close — strictly decaying (no bounce): a row getting out of the way should
    /// never draw the eye on the way out.
    static let settle = Animation.easeOut(duration: 0.18)
}

/// The fork's one frame shape — host modules, panels, focus-mode cards, the selected row, keys,
/// fields: a rectangle with its corners just taken off. One radius at every size, so frames that
/// sit inside each other read as the same part. (It was a 45° cut until it had been lived with.)
/// Lamps, host squares and tags are marks, not frames, and stay square.
extension Shape where Self == RoundedRectangle {
    static var forkFrame: RoundedRectangle { RoundedRectangle(cornerRadius: 3, style: .circular) }
}

/// The line between two panes of one tab: dashed, so it can't be taken for the solid one between
/// tabs. A dash rather than a fainter color: `rule` is already as dark as a dark theme can carry.
struct DashedRule: View {
    @Environment(\.forkTokens) private var tokens
    private struct Line: Shape {
        func path(in r: CGRect) -> Path {
            Path { $0.move(to: .init(x: r.minX, y: r.midY)); $0.addLine(to: .init(x: r.maxX, y: r.midY)) }
        }
    }
    var body: some View {
        Line().stroke(tokens.rule, style: StrokeStyle(lineWidth: 1, dash: [2, 3])).frame(height: 1)
    }
}

/// 45° hatching, the filler between a module's name and its key hint. Stroke it and clip it:
/// the lines deliberately overrun the rect so the pattern meets every edge.
struct Hatch: Shape {
    var pitch: CGFloat = 5
    func path(in r: CGRect) -> Path {
        var p = Path()
        var x = r.minX - r.height
        while x < r.maxX {
            p.move(to: .init(x: x, y: r.maxY))
            p.addLine(to: .init(x: x + r.height, y: r.minY))
            x += pitch
        }
        return p
    }
}

/// Shared card chrome (focus-mode tab cards, host modules): the fork's frame on the
/// sidebar's own ground. `line` nil = the quiet rule color.
struct ForkCard: ViewModifier {
    @Environment(\.forkTokens) private var tokens
    var line: Color? = nil
    var pad: CGFloat = 3
    var hPad: CGFloat = 8
    func body(content: Content) -> some View {
        content
            .padding(pad)
            .overlay(RoundedRectangle.forkFrame.strokeBorder(line ?? tokens.rule, lineWidth: 1))
            .padding(.horizontal, hPad)
    }
}
#endif
