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
                                             dark: .black.withAlphaComponent(0.18)))

    // MARK: Derived roles
    /// Host tint, falling back to de-emphasized text for "no host".
    func hostAccent(_ h: ForkHost?) -> Color { h?.accent ?? textSecondary }

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
            ForkTheme.resolve(fg: $0.fg, bg: $0.bg,
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
    struct Source: Equatable { let fg: NSColor, bg: NSColor }

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
            config.forkColor("background").map { Source(fg: fg, bg: $0) }
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
    static func resolve(fg: NSColor?, bg: NSColor?,
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
            hostCardBg: Color(nsColor: bg).opacity(isLight ? 0.6 : 0.18))
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
}
#endif
