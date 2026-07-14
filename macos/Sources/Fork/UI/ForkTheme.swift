#if os(macOS)
import AppKit
import SwiftUI
import GhosttyKit

/// The terminal-derived half of the fork's palette, as a *value*.
///
/// These are injected through `\.forkTokens` rather than read off a static, so a view that
/// uses one has declared a dependency SwiftUI can invalidate. That is the whole point: with
/// statics, a reader that forgets to subscribe still compiles, and SwiftUI — having seen no
/// dependency — skips its `body` on a reload and leaves the previous theme's colors on
/// screen. Here, forgetting is a compile error.
struct ForkTokens: Equatable {
    var text: Color
    var textSecondary: Color
    var textTertiary: Color
    var hover: Color
    var chipBg: Color
    var cardBorder: Color
    var selectedRow: Color
    var hostCardBg: Color

    /// The un-themed ramp — used until a config lands, and for any theme whose own colors
    /// can't produce a legible one (see ``ForkTheme/hostRamp(from:)``). Lives here rather than
    /// on `ForkHost` because it is a rendering decision: `ForkHost` owns the slot *space*
    /// (`wheelHues`, `N`), which is persistence, and shouldn't import SwiftUI to hold a color.
    static let wheel: [Color] = ForkHost.wheelHues.map {
        Color(hue: $0, saturation: 0.45, brightness: 0.7)
    }

    /// Slot → color for host dots and tab-title accents, `ForkHost.N` entries.
    ///
    /// A ramp rather than a formula because `ForkHost.accentSlot` is persisted *by index*:
    /// the slot is the host's identity and must keep meaning across a retheme, so only what
    /// each slot renders as may change. Its length is therefore pinned to `ForkHost.N`.
    var hostRamp: [Color]

    /// System semantics — the pre-theming appearance. Used until a config lands, and whenever
    /// ``ForkTheme/resolve(fg:bg:appearanceIsDark:increaseContrast:)`` declines a theme.
    ///
    /// Not merely a placeholder: it is the *correct* rendering whenever the terminal's colors
    /// can't be trusted over this backdrop, so it has to look finished, not degraded.
    static let fallback = ForkTokens(
        text: .primary,
        textSecondary: .secondary,
        textTertiary: Color(nsColor: .tertiaryLabelColor),
        // The historical literals — see the alpha note in `resolve`.
        hover: Color.primary.opacity(0.06),
        chipBg: Color.primary.opacity(0.08),
        cardBorder: Color.secondary.opacity(0.15),
        selectedRow: Theme.appearanceAdaptive(light: NSColor(Theme.clay).withAlphaComponent(0.20),
                                              dark: NSColor(Theme.clay).withAlphaComponent(0.14)),
        hostCardBg: Theme.appearanceAdaptive(light: .controlBackgroundColor.withAlphaComponent(0.6),
                                             dark: .black.withAlphaComponent(0.18)),
        hostRamp: Self.wheel)

    // MARK: Derived roles
    /// Slot → color. `i` can't be out of range: `ForkHost.init(from:)` clamps `accentSlot` to
    /// the slot space at decode, which is the single guard against a hand-edited fork.json.
    /// The normalization is belt-and-braces for the sign Swift's `%` would otherwise keep.
    func hostColor(_ i: Int) -> Color { hostRamp[((i % hostRamp.count) + hostRamp.count) % hostRamp.count] }

    /// Host tint (the A half of the slot pair), falling back to de-emphasized text for
    /// "no host". The dot is the only bicolor render; text/stroke/rail use A alone.
    func hostAccent(_ h: ForkHost?) -> Color {
        guard let h else { return textSecondary }
        return hostColor(ForkHost.pair(h.slot).a)
    }

    /// Spine heat — recency as a fade on the de-emphasized text color. `nil` is *ancient*
    /// (the opposite default from `Theme.doze`, which treats never-touched as awake).
    func spineHeat(_ d: Date?) -> Color {
        let age = d.map { Date().timeIntervalSince($0) } ?? .infinity
        return age < 300 ? textSecondary
             : age < 3600 ? textSecondary.opacity(0.6)
             : textSecondary.opacity(0.35)
    }
}

private struct ForkTokensKey: EnvironmentKey {
    static let defaultValue = ForkTokens.fallback
}

extension EnvironmentValues {
    /// Terminal-derived colors; unthemed outside ``ForkThemed``.
    var forkTokens: ForkTokens {
        get { self[ForkTokensKey.self] }
        set { self[ForkTokensKey.self] = newValue }
    }
}

/// The single subscription point. Wrap every fork-owned SwiftUI hosting root in this; nothing
/// below it observes ``ForkTheme`` directly.
///
/// It resolves the palette here, rather than in ``ForkTheme``, because two of the three inputs
/// are properties of *this view's* window, not of the app: `colorScheme` is the hosting view's
/// own `NSAppearance` — the thing that actually colors the material behind the sidebar — and
/// `colorSchemeContrast` is Increase Contrast. Reading them as environment values means
/// SwiftUI re-runs this body when either moves, so no `NSApp` KVO or workspace notification is
/// needed, and the polarity test can't be answered with some other window's appearance.
struct ForkThemed<Content: View>: View {
    @ObservedObject private var theme = ForkTheme.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    private let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    var body: some View {
        content.environment(\.forkTokens, theme.source.flatMap {
            ForkTheme.resolve(fg: $0.fg, bg: $0.bg, palette: $0.palette,
                              appearanceIsDark: colorScheme == .dark,
                              increaseContrast: contrast == .increased)
        } ?? .fallback)
    }
}

/// Publishes the terminal's `foreground`/`background` as libghostty reports them.
///
/// libghostty hands Swift an *already-resolved* config: it picks the `light:`/`dark:` half of
/// `theme` before these are readable here, then emits a config_change. So this never sees a
/// theme *name* — only the colors of whichever half is active, and a scheme flip arrives as an
/// ordinary reload.
@MainActor
final class ForkTheme: ObservableObject {
    static let shared = ForkTheme()

    /// Both colors or neither — see ``resolve(fg:bg:appearanceIsDark:increaseContrast:)``.
    /// `palette` is ANSI 0–15; the host ramp uses only the chromatic entries.
    struct Source: Equatable { let fg: NSColor, bg: NSColor, palette: [NSColor] }

    /// `nil` until a config lands, or if either key can't be read.
    @Published private(set) var source: Source?

    private init() {}

    /// Seed and follow reloads. Called from `ForkBootstrap.install`; call exactly once
    /// (a second call would double-register).
    func start(_ config: Ghostty.Config) {
        adopt(config)
        NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidChange, object: nil, queue: .main
        ) { [weak self] note in MainActor.assumeIsolated {
            // A non-nil object scopes the post to one SurfaceView. The sidebar is window
            // chrome and owns no surface, so only the app-wide post applies — same guard as
            // `AppDelegate.ghosttyConfigDidChange`.
            guard note.object == nil,
                  let cfg = note.userInfo?[
                    SwiftUI.Notification.Name.GhosttyConfigChangeKey] as? Ghostty.Config
            else { return }
            self?.adopt(cfg)
        } }
    }

    private func adopt(_ config: Ghostty.Config) {
        let new = config.forkColor("foreground").flatMap { fg in
            config.forkColor("background").map {
                Source(fg: fg, bg: $0, palette: config.forkPalette() ?? [])
            }
        }
        // `.ghosttyConfigDidChange` fires for *any* reload. Without this, changing a keybind
        // re-renders every sidebar row mid-animation for no visual reason.
        guard new != source else { return }
        source = new
    }

    /// The whole derivation, pure — no `ghostty_config_t`, no live `NSApp`, so it unit-tests.
    ///
    /// Returns `nil` for "don't theme; use system semantics". Three ways that happens:
    ///
    /// 1. **Either key unreadable.** Both land or neither does — a half-applied theme (themed
    ///    text over an unthemed surface) is a worse failure than staying one reload behind.
    /// 2. **Increase Contrast is on.** A user who asked the OS for maximum contrast is asking
    ///    us not to art-direct their chrome; system label colors are what respond to that
    ///    setting, and a frozen `fg.opacity(0.3)` is what doesn't.
    /// 3. **The background's polarity disagrees with the appearance.** The sidebar's backdrop
    ///    is `.ultraThinMaterial`, whose scrim comes from the window's `NSAppearance` — so a
    ///    foreground borrowed from a background of the *other* polarity would be painted onto
    ///    a surface it was never guaranteed to contrast against.
    ///
    ///    Whether that can happen depends on `macos-titlebar-style`. Under the default
    ///    (`transparent`) and `tabs`, upstream forces the window's appearance from the
    ///    background's own luminance — `TransparentTitlebarTerminalWindow.syncAppearance`,
    ///    and documented at `window-theme` — so the two always agree and this never fires.
    ///    Under `native`/`hidden` the window follows `window-theme`, which `system` and
    ///    `ghostty` leave on the macOS setting: a fixed dark theme in macOS Light then really
    ///    does put a light material under a near-white foreground, and this declines.
    ///
    /// `appearanceIsDark` must therefore come from the *view's* appearance, never `NSApp`'s —
    /// those are deliberately decoupled, and ``ForkThemed`` reads `colorScheme` for exactly
    /// this reason.
    static func resolve(fg: NSColor?, bg: NSColor?, palette: [NSColor] = [],
                        appearanceIsDark: Bool, increaseContrast: Bool) -> ForkTokens? {
        guard !increaseContrast, let fg, let bg else { return nil }
        let isLight = bg.isLightColor
        guard isLight == !appearanceIsDark else { return nil }

        let c = Color(nsColor: fg)
        return ForkTokens(
            text: c,
            textSecondary: c.opacity(weight(isLight ? 0.498 : 0.549, fg: fg, isLight: isLight)),
            textTertiary: c.opacity(weight(0.25, fg: fg, isLight: isLight)),
            // Old: `Color.primary.opacity(0.06)` &c. `.primary` is `labelColor`, which carries
            // 0.847 alpha, and `Color.opacity` multiplies — so the literals were never the
            // effective alpha. `fg` is opaque; these are the old *rendered* values.
            hover: c.opacity(0.05),       // 0.847 × 0.06
            chipBg: c.opacity(0.07),      // 0.847 × 0.08
            cardBorder: c.opacity(0.08),  // secondaryLabelColor 0.549 × 0.15 (dark; 0.075 light)
            selectedRow: Color(nsColor: NSColor(Theme.clay)
                .withAlphaComponent(isLight ? 0.20 : 0.14)),
            // The terminal background, washed over the material. Alpha differs by polarity
            // because the material underneath is not neutral: a dark background only has to
            // deepen it, a light one has to lift it much harder to read as raised at all.
            hostCardBg: Color(nsColor: bg).opacity(isLight ? 0.6 : 0.18),
            hostRamp: hostRamp(from: palette))
    }

    /// Slot → color for host dots and tab-title accents, drawn from the theme's own ANSI
    /// colors instead of the fixed hue wheel.
    ///
    /// Each slot keeps its **hue position** and takes the nearest unused chromatic entry. That
    /// ordering is the point: `ForkHost.accentSlot` is persisted by index, so a host's slot is
    /// its identity, and matching by hue is what keeps a host recognizably the color it was
    /// (a green host stays green) instead of being arbitrarily repainted by a retheme.
    ///
    /// The theme only gets to supply the ramp if the *result* survives ``isLegible(_:)`` —
    /// the input can't tell us this. Two real failure modes it catches, neither of which a
    /// count-the-colors check would: a palette whose entries are distinct as hex but identical
    /// to the eye (Broadcast ships `#6D9CBE` and `#6E9CBE`), and a palette whose hues don't
    /// span the wheel, which strands a late slot on a far-off hue and repaints a host you'd
    /// learned. Otherwise the wheel, which is always legible.
    static func hostRamp(from palette: [NSColor]) -> [Color] {
        // 0/8 and 7/15 are the theme's black/grays by convention; only 1–6 and 9–14 carry hue.
        let chromatic = [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14]
            .filter { $0 < palette.count }
            .map { palette[$0] }
            .filter { $0.saturationComponentSafe >= 0.15 }
        var unique: [NSColor] = []
        for c in chromatic where !unique.contains(where: { $0.hexString == c.hexString }) {
            unique.append(c)
        }
        guard unique.count >= ForkHost.N else { return ForkTokens.wheel }

        // Hue hoisted out of the comparator: it costs a colorspace conversion per read.
        var free = unique.map { (hue: $0.hueComponentSafe, color: $0) }
        let picked = ForkHost.wheelHues.map { stop -> NSColor in
            // Non-empty: `free` starts at >= N and this runs exactly N times, removing one.
            // `min(by:)` only replaces on strictly-less, so ties take the lowest palette index
            // and the ramp is deterministic.
            let i = free.indices.min {
                hueDistance(free[$0].hue, stop) < hueDistance(free[$1].hue, stop)
            }!
            return free.remove(at: i).color
        }
        guard isLegible(picked) else { return ForkTokens.wheel }
        return picked.map(Color.init(nsColor:))
    }

    /// Two slots closer than this in CIELab are the same dot to a reader. Set from measurement,
    /// not taste: a theme's own normal/bright pair of the same hue lands around ΔE 8–10 (which
    /// must pass — it's a distinction the theme author made deliberately), while the palettes
    /// that actually break this ship near-identical entries an order of magnitude closer
    /// (Broadcast's `#6D9CBE`/`#6E9CBE` is ΔE 0.28). 5 sits in the empty gap between those two
    /// populations, and is roughly where a difference stops being noticeable at a glance.
    static let minSeparation = 5.0

    /// The largest a slot may drift from its hue position before a host it identifies is,
    /// visibly, a different color than it was.
    static let maxHueDrift = 0.25

    /// Is this ramp fit to identify hosts by? Both halves of what the dot promises: every slot
    /// still reads as the hue it was picked as, and no two slots look alike.
    ///
    /// Checked on the assignment rather than the palette because that's where the promise
    /// lives — a theme can pass any input-shaped check and still produce two identical dots.
    static func isLegible(_ ramp: [NSColor]) -> Bool {
        for (slot, c) in ramp.enumerated()
        where hueDistance(c.hueComponentSafe, ForkHost.wheelHues[slot]) >= maxHueDrift {
            return false
        }
        for i in ramp.indices {
            for j in ramp.indices where j > i && ramp[i].deltaE(to: ramp[j]) < minSeparation {
                return false
            }
        }
        return true
    }

    /// Shortest distance around the hue circle, where 0 and 1 are the same red.
    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b); return min(d, 1 - d)
    }

    /// Alpha that makes `fg` carry the same visual weight a system label would at
    /// `systemAlpha`.
    ///
    /// A system label is pure white (dark mode) or pure black (light); a terminal foreground
    /// stops short of that extreme, so the same alpha lands fainter. Scale by how far this
    /// particular `fg` actually travels toward the extreme — computed per theme rather than
    /// hardcoded, because the correction's *sign* flips with polarity (oat is dimmer than
    /// white; warm charcoal is lighter than black) and its size depends on the theme. A dim
    /// foreground (Solarized's `#839496`) correctly lands near-opaque here.
    ///
    /// Exact only against an idealized #000/#fff backdrop: solving `x·(fg−b) = a·(1−b)` at
    /// `b = 0`/`b = 1` gives the two branches below. The real backdrop is a material at
    /// roughly 0.2–0.3 luminance, so for a dim foreground this under-corrects — the clamps
    /// are the error budget, not decoration.
    static func weight(_ systemAlpha: Double, fg: NSColor, isLight: Bool) -> Double {
        let l = fg.luminance
        let reach = isLight ? 1 - l : l
        return min(1, systemAlpha / max(reach, 0.2))
    }
}

extension NSColor {
    /// HSB components, converted to sRGB first. `hueComponent` &c. trap on a color whose space
    /// isn't RGB-backed, and these run over whatever the user's theme file contained.
    var hsbSafe: (h: CGFloat, s: CGFloat, b: CGFloat) {
        guard let c = usingColorSpace(.sRGB) else { return (0, 0, 0) }
        var h: CGFloat = 0, sat: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &sat, brightness: &br, alpha: &a)
        return (h, sat, br)
    }
    var hueComponentSafe: Double { Double(hsbSafe.h) }
    var saturationComponentSafe: Double { Double(hsbSafe.s) }

    /// CIELab, D65. Needed because RGB distance is not perceptual distance: two colors a byte
    /// apart in one channel and two that read as different colors are the same size in sRGB.
    var lab: (L: Double, a: Double, b: Double) {
        guard let c = usingColorSpace(.sRGB) else { return (0, 0, 0) }
        func linear(_ v: CGFloat) -> Double {
            let d = Double(v)
            return d <= 0.04045 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4)
        }
        let r = linear(c.redComponent), g = linear(c.greenComponent), b = linear(c.blueComponent)
        // sRGB → XYZ (D65), then normalized by the white point.
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y =  0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : (7.787 * t + 16.0 / 116) }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// CIE76 ΔE. Rule of thumb: ~1 is the just-noticeable difference, ~10 is "clearly a
    /// different color" — which is the bar a host dot has to clear at 7–18pt.
    func deltaE(to other: NSColor) -> Double {
        let a = lab, b = other.lab
        return ((a.L - b.L) * (a.L - b.L) + (a.a - b.a) * (a.a - b.a) + (a.b - b.b) * (a.b - b.b))
            .squareRoot()
    }
}

extension Ghostty.Config {
    /// Read a `Color`-typed config key.
    ///
    /// Upstream exposes only `background` (as `backgroundColor`), which returns a non-optional
    /// `Color` with a `windowBackgroundColor` fallback — that swallows the read failure the
    /// all-or-nothing rule in `resolve` depends on, and hands back a `Color` where luminance
    /// needs an `NSColor`. `foreground` has no upstream accessor at all.
    ///
    /// Does not generalize: `cursor-color` and `selection-background`/`-foreground` are
    /// `?TerminalColor` unions, and `theme` is a `?Theme` struct. None declare `cval()`, so
    /// `c_get.zig` returns false for all three — surfacing them needs an upstream Zig change,
    /// i.e. a third seam.
    func forkColor(_ key: String) -> NSColor? {
        guard let config = self.config else { return nil }
        var c = ghostty_config_color_s()
        guard ghostty_config_get(config, &c, key, UInt(key.lengthOfBytes(using: .utf8)))
        else { return nil }
        return NSColor(ghostty: c)
    }

    /// The theme's ANSI palette, entries 0–15.
    ///
    /// `Palette` declares `cval()` (`ghostty_config_palette_s`), so this marshals through the
    /// same generic getter as `background` with no upstream change. The C side is a packed
    /// `ghostty_config_color_s colors[256]`, which imports as a homogeneous Swift tuple —
    /// hence the raw-bytes rebind rather than 256 hand-written accessors.
    func forkPalette() -> [NSColor]? {
        guard let config = self.config else { return nil }
        var v = ghostty_config_palette_s()
        let key = "palette"
        guard ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8)))
        else { return nil }
        return withUnsafeBytes(of: &v.colors) { raw in
            raw.bindMemory(to: ghostty_config_color_s.self).prefix(16).map { NSColor(ghostty: $0) }
        }
    }
}
#endif
