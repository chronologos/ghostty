#if os(macOS)
import AppKit
import Testing
@testable import Ghostty

/// The keys that answer a confirm panel. They decide whether a session is detached or killed,
/// and there is no way to press them in a test host — so the rule is a pure function and this
/// is its contract.
@MainActor
struct ConfirmKeyTests {
    /// The ⌘W panel's choices, as `confirmDetachOrKill` + `presentConfirm` build them.
    private func closePanel(killEnabled: Bool = true) -> [ConfirmView.Choice] {
        [
            .init(label: "Detach", chord: "⏎", kind: .primary, keys: [.return]) {},
            .init(label: "Kill", chord: "K · ⌘W", kind: .destructive,
                  keys: [.init(characters: "k"), .init(characters: "w", modifiers: .command)],
                  enabled: killEnabled) {},
            .init(label: "Cancel", chord: "esc", keys: [.escape]) {},
        ]
    }

    private func press(_ chars: String?, _ mods: NSEvent.ModifierFlags = [], isRepeat: Bool = false,
                       in choices: [ConfirmView.Choice]) -> String? {
        ConfirmView.choice(for: chars, modifiers: mods, isRepeat: isRepeat, in: choices)?.label
    }

    @Test func eachKeyMeansItsChoice() {
        let c = closePanel()
        #expect(press("\r", in: c) == "Detach")
        #expect(press("k", in: c) == "Kill")
        #expect(press("w", .command, in: c) == "Kill")
        #expect(press("\u{1b}", in: c) == "Cancel")
    }

    /// A held ⌘W auto-repeats into the panel it just opened; a held ⏎ from the command line
    /// could land there too. Neither may answer.
    @Test func aRepeatNeverAnswers() {
        let c = closePanel()
        for (chars, mods) in [("w", NSEvent.ModifierFlags.command), ("\r", []), ("k", []), ("\u{1b}", [])] {
            #expect(press(chars, mods, isRepeat: true, in: c) == nil)
        }
    }

    /// The modifiers have to match exactly: bare W is not ⌘W, and ⌘K / ⌘⏎ are other chords.
    @Test func modifiersMustMatchExactly() {
        let c = closePanel()
        #expect(press("w", in: c) == nil)
        #expect(press("k", .command, in: c) == nil)
        #expect(press("\r", .command, in: c) == nil)
        #expect(press("w", [.command, .shift], in: c) == nil)
    }

    /// Caps Lock, fn and the keypad flag ride along in `modifierFlags` without making it a
    /// different key; keypad Enter reports its own character.
    @Test func incidentalFlagsAndCaseAreIgnored() {
        let c = closePanel()
        #expect(press("K", .capsLock, in: c) == "Kill")
        #expect(press("W", [.command, .capsLock], in: c) == "Kill")
        #expect(press("\u{3}", .numericPad, in: c) == "Detach")
        #expect(press("\r", .function, in: c) == "Detach")
    }

    /// Nothing to kill: K and ⌘W must fall through, not land on some other choice.
    @Test func aDisabledChoiceDoesNotAnswer() {
        let c = closePanel(killEnabled: false)
        #expect(press("k", in: c) == nil)
        #expect(press("w", .command, in: c) == nil)
        #expect(press("\r", in: c) == "Detach")
    }

    @Test func anythingElseIsNobodysKey() {
        let c = closePanel()
        #expect(press("d", in: c) == nil)
        #expect(press(" ", in: c) == nil)
        #expect(press(nil, in: c) == nil)
    }
}
#endif
