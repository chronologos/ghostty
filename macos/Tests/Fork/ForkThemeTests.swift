#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// `ForkTheme.resolve` is the whole terminal-color derivation with the `ghostty_config_t`, the
/// live `NSApp`, and the `NSAppearance` stack factored out — so the decisions it encodes are
/// testable without a running app. There is no UI-test harness for Fork views, so this is the
/// only automated coverage these rules get.
///
/// Note there is deliberately no test that every view reads its colors through
/// `\.forkTokens`: they are unreachable any other way, so the compiler is the check.
@MainActor
struct ForkThemeTests {
    /// A warm near-black / warm near-white pair — neither is #000/#fff, which is exactly the
    /// case the weight math exists for.
    private let darkBG = NSColor(srgbRed: 0x19/255, green: 0x19/255, blue: 0x18/255, alpha: 1)
    private let darkFG = NSColor(srgbRed: 0xe8/255, green: 0xe6/255, blue: 0xdc/255, alpha: 1)
    private let lightBG = NSColor(srgbRed: 0xfa/255, green: 0xf9/255, blue: 0xf5/255, alpha: 1)
    private let lightFG = NSColor(srgbRed: 0x3d/255, green: 0x3d/255, blue: 0x3a/255, alpha: 1)
    /// Solarized Dark's foreground — a deliberately dim gray, i.e. the low-contrast case.
    private let dimFG = NSColor(srgbRed: 0x83/255, green: 0x94/255, blue: 0x96/255, alpha: 1)

    private func resolve(fg: NSColor, bg: NSColor, dark: Bool, contrast: Bool = false) -> ForkTokens? {
        ForkTheme.resolve(fg: fg, bg: bg, appearanceIsDark: dark, increaseContrast: contrast)
    }

    // MARK: The accept path

    @Test func acceptsWhenBackgroundPolarityMatchesTheAppearance() {
        #expect(resolve(fg: darkFG, bg: darkBG, dark: true) != nil)
        #expect(resolve(fg: lightFG, bg: lightBG, dark: false) != nil)
    }

    @Test func acceptedTokensCarryTheTerminalForeground() {
        #expect(resolve(fg: darkFG, bg: darkBG, dark: true)?.text == Color(nsColor: darkFG))
    }

    // MARK: The decline paths — each returns nil, meaning "use system semantics"

    /// The bug this rule exists for: under `macos-titlebar-style = native`/`hidden`, the
    /// window follows `window-theme`, and `system`/`ghostty` leave that on the macOS setting.
    /// A fixed dark theme in macOS Light then puts a light material under the sidebar, and
    /// borrowing the theme's near-white foreground would paint white text onto it.
    ///
    /// `appearanceIsDark` is the *view's* appearance (`ForkThemed` reads `colorScheme`), never
    /// `NSApp`'s — under the default `transparent` titlebar style upstream forces the window's
    /// appearance from the background's own luminance, so the two deliberately disagree and
    /// testing `NSApp`'s would decline exactly the configs that should theme.
    @Test func declinesWhenBackgroundPolarityFightsTheAppearance() {
        #expect(resolve(fg: darkFG, bg: darkBG, dark: false) == nil)  // dark theme, light window
        #expect(resolve(fg: lightFG, bg: lightBG, dark: true) == nil) // light theme, dark window
    }

    /// A user who asked the OS for maximum contrast is asking us not to art-direct their
    /// chrome — system label colors track that setting, a frozen `fg.opacity(0.3)` does not.
    @Test func declinesUnderIncreaseContrast() {
        #expect(resolve(fg: darkFG, bg: darkBG, dark: true, contrast: true) == nil)
        #expect(resolve(fg: lightFG, bg: lightBG, dark: false, contrast: true) == nil)
    }

    /// Both keys land or neither does — a half-applied theme is worse than staying a reload
    /// behind, and it's the half that can strand unreadable text.
    @Test func declinesOnAHalfReadConfig() {
        #expect(ForkTheme.resolve(fg: darkFG, bg: nil, appearanceIsDark: true, increaseContrast: false) == nil)
        #expect(ForkTheme.resolve(fg: nil, bg: darkBG, appearanceIsDark: true, increaseContrast: false) == nil)
        #expect(ForkTheme.resolve(fg: nil, bg: nil, appearanceIsDark: true, increaseContrast: false) == nil)
    }

    /// Polarity is the *background's* job — the foreground never votes. A theme whose fg and
    /// bg are the same polarity is the user's own bug, and we still take it: the rule is about
    /// matching the surface we're drawn on, not second-guessing their theme.
    @Test func polarityIgnoresTheForeground() {
        #expect(resolve(fg: darkFG, bg: lightBG, dark: false) != nil)
        #expect(resolve(fg: lightFG, bg: darkBG, dark: true) != nil)
    }

    // MARK: weight()

    /// The correction's sign flips with polarity: oat is *dimmer* than the white label it
    /// replaces (needs more alpha), warm charcoal is *lighter* than the black one (also more).
    /// Both must exceed the system alpha they're matching — an earlier draft hardcoded one
    /// constant tuned for dark, which pushed light-mode text the wrong way.
    @Test func weightExceedsTheSystemAlphaInBothPolarities() {
        #expect(ForkTheme.weight(0.549, fg: darkFG, isLight: false) > 0.549)
        #expect(ForkTheme.weight(0.498, fg: lightFG, isLight: true) > 0.498)
    }

    /// A dim foreground has to work harder to carry the same weight than a bright one.
    @Test func dimmerForegroundEarnsMoreAlpha() {
        let oat = ForkTheme.weight(0.549, fg: darkFG, isLight: false)
        let dim = ForkTheme.weight(0.549, fg: dimFG, isLight: false)
        #expect(dim > oat)
    }

    /// Never exceeds opacity, whatever the theme — including the degenerate fg≈bg case that
    /// would otherwise divide toward infinity.
    @Test func weightIsClampedToOpaque() {
        let onBg = NSColor(srgbRed: 0.02, green: 0.02, blue: 0.02, alpha: 1)  // reach ≈ 0.02
        #expect(ForkTheme.weight(0.549, fg: onBg, isLight: false) == 1)
        #expect(ForkTheme.weight(0.25, fg: darkFG, isLight: false) <= 1)
    }

    /// Tertiary stays lighter than secondary for every theme — the text hierarchy can't
    /// invert no matter how the per-theme correction lands.
    @Test func textHierarchyCannotInvert() {
        for (fg, isLight) in [(darkFG, false), (lightFG, true), (dimFG, false)] {
            #expect(ForkTheme.weight(0.25, fg: fg, isLight: isLight)
                    < ForkTheme.weight(isLight ? 0.498 : 0.549, fg: fg, isLight: isLight))
        }
    }

    // MARK: Constants

    /// The accent is deliberately NOT theme-derived — it must survive any reload. Pinning the
    /// literal so a later "just wire clay to palette[1]" has to delete a test that says why
    /// not (slot 1 is semantically *red*; it only reads as clay in one unusual theme).
    @Test func clayStaysABrandConstant() {
        #expect(Theme.clay == Color(red: 0xD9/255, green: 0x77/255, blue: 0x57/255))
    }

    /// The fallback must be system semantics, not a themed guess — it's what every decline
    /// path above lands on, so it has to be a finished look rather than a degraded one.
    @Test func fallbackIsSystemSemantics() {
        #expect(ForkTokens.fallback.text == .primary)
        #expect(ForkTokens.fallback.textSecondary == .secondary)
    }
}
#endif
