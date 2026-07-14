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

    // MARK: Host ramp

    /// A realistic ANSI palette: 6 chromatic hues, each with a distinct bright variant.
    private var themePalette: [NSColor] {
        ["#3a3937", "#d97757", "#92a874", "#dba84e", "#6a9bcc", "#b394cc", "#5e9e8f", "#b0aea5",
         "#5c5a55", "#e8956f", "#a8bf88", "#edc06a", "#85b3de", "#c9ade0", "#76b8a7", "#faf9f5"]
            .map(Self.hex)
    }
    private static func hex(_ s: String) -> NSColor {
        let v = Int(s.dropFirst(), radix: 16)!
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                       green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    private func hue(_ c: Color) -> Double {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        NSColor(c).usingColorSpace(.sRGB)!.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Double(h)
    }

    /// The ramp is indexed by `accentSlot`, which is persisted — a length change silently
    /// repaints every existing host, so it is pinned to the slot space, not to the theme.
    @Test func hostRampAlwaysMatchesTheSlotSpace() {
        #expect(ForkTheme.hostRamp(from: themePalette).count == ForkHost.N)
        #expect(ForkTheme.hostRamp(from: []).count == ForkHost.N)
        #expect(ForkTokens.wheel.count == ForkHost.N)
    }

    /// The ramp must actually be the theme's colors. Without this, every other ramp test
    /// passes vacuously on a silent fallback: the wheel trivially satisfies "each slot keeps
    /// its hue" because the wheel *is* the hue stops.
    @Test func aRichThemeActuallyReplacesTheWheel() {
        let ramp = ForkTheme.hostRamp(from: themePalette)
        #expect(ramp != ForkTokens.wheel)
        // Every entry is a real palette color, not an interpolation.
        let themeHexes = Set(themePalette.compactMap { $0.hexString })
        for c in ramp { #expect(themeHexes.contains(NSColor(c).hexString ?? "")) }
    }

    /// The point of matching by hue: a host keeps the color it had. Every slot must land
    /// within a quarter-turn of its wheel hue, or a retheme is repainting hosts at random.
    @Test func everySlotKeepsItsHueFamily() {
        let ramp = ForkTheme.hostRamp(from: themePalette)
        for (slot, stop) in ForkHost.wheelHues.enumerated() {
            let d = abs(hue(ramp[slot]) - stop)
            #expect(min(d, 1 - d) < ForkTheme.maxHueDrift,
                    "slot \(slot) drifted off its hue position")
        }
    }

    /// Hosts must stay distinguishable — the dot's entire job. Measured perceptually, not by
    /// hex: two colors a byte apart are distinct strings and the same dot.
    /// The measured margin: a real theme's tightest pair (its own normal/bright of one hue)
    /// must clear the bar with room, or `minSeparation` is tuned to reject real themes.
    @Test func aRealThemeClearsTheSeparationBarWithMargin() {
        let ramp = ForkTheme.hostRamp(from: themePalette).map { NSColor($0) }
        var worst = Double.infinity
        for i in ramp.indices { for j in ramp.indices where j > i {
            worst = min(worst, ramp[i].deltaE(to: ramp[j]))
        } }
        #expect(worst > ForkTheme.minSeparation * 1.5, "tightest pair \(worst) is too near the bar")
    }

    @Test func rampEntriesAreVisiblyDifferent() {
        let ramp = ForkTheme.hostRamp(from: themePalette).map { NSColor($0) }
        for i in ramp.indices {
            for j in ramp.indices where j > i {
                #expect(ramp[i].deltaE(to: ramp[j]) >= ForkTheme.minSeparation,
                        "slots \(i)/\(j) look alike")
            }
        }
    }

    /// ΔE has to actually measure perception, or the legibility guard is decorative. The
    /// near-duplicate is Broadcast's real pair; the far one is two obviously different colors.
    @Test func deltaESeparatesLookalikesFromRealDifferences() {
        #expect(Self.hex("#6D9CBE").deltaE(to: Self.hex("#6E9CBE")) < 1)
        #expect(Self.hex("#d97757").deltaE(to: Self.hex("#6a9bcc")) > 40)
        #expect(Self.hex("#d97757").deltaE(to: Self.hex("#d97757")) == 0)
    }

    /// A palette that is distinct as *hex* but not to the eye must not ship: it would paint two
    /// hosts the same dot. Broadcast really does ship `#6D9CBE` and `#6E9CBE`.
    @Test func rampDeclinesAThemeWhoseColorsOnlyDifferAsHex() {
        var lookalikes = themePalette
        lookalikes[12] = Self.hex("#6D9CBE")
        lookalikes[4] = Self.hex("#6E9CBE")
        #expect(ForkTheme.hostRamp(from: lookalikes) == ForkTokens.wheel)
    }

    /// A palette with 10+ colors that are individually legible but don't *span* the wheel must
    /// not ship either: some slot ends up far from its hue and a host you'd learned gets
    /// silently repainted. This is real — Wryan turns a yellow host teal.
    ///
    /// The fixture has to clear the count and separation guards to reach the drift one, or it
    /// would pass for the wrong reason: twelve reds, well apart in lightness (so ΔE-distinct
    /// and unique), all at hue ≈ 0 (so no slot past the oranges can be served).
    @Test func rampDeclinesAThemeThatCannotCoverTheWheel() {
        let redsOnly = (0..<16).map { i -> NSColor in
            let v = 0.18 + CGFloat(i % 12) * 0.07
            return NSColor(srgbRed: v, green: v * 0.08, blue: v * 0.08, alpha: 1)
        }
        // Guard the fixture itself: it must fail on drift, not on count or separation.
        let chromatic = [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14].map { redsOnly[$0] }
        #expect(Set(chromatic.compactMap { $0.hexString }).count >= ForkHost.N)
        #expect(chromatic.allSatisfy { $0.saturationComponentSafe >= 0.15 })
        #expect(ForkTheme.hostRamp(from: redsOnly) == ForkTokens.wheel)
    }

    /// The guard is the property: anything accepted satisfies both halves by construction.
    @Test func anyAcceptedRampIsLegible() {
        let ramp = ForkTheme.hostRamp(from: themePalette)
        #expect(ramp != ForkTokens.wheel)
        #expect(ForkTheme.isLegible(ramp.map { NSColor($0) }))
    }

    /// A theme without `N` distinct chromatic colors keeps the wheel. Otherwise a grayscale
    /// palette paints every host the same gray — worse than not theming at all.
    @Test func rampDeclinesAThemeWithoutEnoughDistinctHues() {
        let grays = (0..<16).map { NSColor(srgbRed: CGFloat($0) / 16, green: CGFloat($0) / 16,
                                           blue: CGFloat($0) / 16, alpha: 1) }
        #expect(ForkTheme.hostRamp(from: grays) == ForkTokens.wheel)
        // Bright row identical to normal → only 6 unique, below N.
        let sixHues = (0..<16).map { themePalette[[0, 1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3, 4, 5, 6, 7][$0]] }
        #expect(ForkTheme.hostRamp(from: sixHues) == ForkTokens.wheel)
        #expect(ForkTheme.hostRamp(from: []) == ForkTokens.wheel)
    }

    /// Slots 22/55/99 are live in the author's fork.json. Their `a` halves must keep landing in
    /// the hue family they were picked as — a silent repaint of a host you've learned is the
    /// exact regression the hue-matching exists to prevent.
    @Test func liveHostSlotsKeepTheirIdentity() {
        let ramp = ForkTheme.hostRamp(from: themePalette)
        for slot in [22, 55, 99] {
            let a = ForkHost.pair(slot).a
            let d = abs(hue(ramp[a]) - ForkHost.wheelHues[a])
            #expect(min(d, 1 - d) < 0.2, "slot \(slot) would be repainted out of its family")
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
