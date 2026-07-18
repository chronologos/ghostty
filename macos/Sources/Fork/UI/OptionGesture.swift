#if os(macOS)
import SwiftUI

/// ⌥ recognizer for the sidebar, extracted from `SidebarView` (it was ~105 lines of gesture
/// state interleaved with row rendering): a *solo* ⌥ held 0.5s opens the **peek** — it arms
/// `revealAll` (re-expand every read CC status line for a fleet-wide glance) and, via
/// `onPeek`, the controller's `CheatsheetView` overlay. ⌥⌥ — two clean taps within 0.4s,
/// committed on the second *release* — fires `onSweep` (mark-all-read). Any key or mouse
/// event while ⌥ is down is a chord (readline ⌥b/⌥f, accented input, ⌘⌥N, ⌥-click/⌥-drag in
/// the terminal), not a tap or a peek — it disqualifies the in-flight press for both.
///
/// Both peek surfaces hang off this one recognizer on purpose. The cheatsheet used to run
/// its own ⌘-hold `flagsChanged` monitor on the controller; moving it to ⌥ would have put
/// two recognizers on one gesture with *different* disqualifier rules (that one saw no
/// mouse events and never re-checked the hardware at fire time), which is a drift bug
/// waiting to happen. `setPeek` is the single writer for both.
///
/// Owns its NSEvent local monitor (not the controller's `navMonitor`) so the gesture state
/// stays view-local `@State` and doesn't churn the registry's `objectWillChange` →
/// debounce-save on every modifier tap. The monitor's lifetime is the sidebar's SwiftUI
/// graph, which outlives a ⌘⇧B collapse (`toggleSidebar` only sets `isHidden` on the
/// hosting view; it never unmounts it) — so the overlay still opens with the sidebar shut.
struct OptionGestureRecognizer: ViewModifier {
    /// The window whose events count — local monitors are app-wide, and ⌥⌥ in a sheet /
    /// QuickTerminal / another window must not sweep this sidebar's read-state. A closure
    /// (not a captured value) because the window can be nil at attach time.
    let window: () -> NSWindow?
    @Binding var revealAll: Bool
    /// Mirrors every `revealAll` transition out to the controller-owned cheatsheet overlay.
    let onPeek: (Bool) -> Void
    let onSweep: () -> Void

    @State private var optionHeld = false
    @State private var lastOptionPress: Date?
    @State private var flagsMonitor: Any?
    /// Armed only by a *solo* hold — the 0.5s delay plus the key/mouse disqualifier keep
    /// readline Meta chords (⌥b/⌥f) and ⌥-clicks from flashing the reveal mid-typing.
    @State private var revealArm: Timer?
    /// Second ⌥ tap landed inside the 0.4s window — the sweep fires when it's released
    /// cleanly (no hold, no chord), so "tap, then hold to peek" never reads as ⌥⌥.
    @State private var sweepOnRelease = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                flagsMonitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
                ) { ev in
                    handleOptionEvent(ev)
                }
            }
            .onDisappear {
                flagsMonitor.map(NSEvent.removeMonitor); flagsMonitor = nil
                disarm(); optionHeld = false; lastOptionPress = nil
            }
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didResignActiveNotification)) { _ in
                    optionHeld = false
                    disarm()
                }
            .onReceive(NotificationCenter.default.publisher(
                for: NSWindow.didResignKeyNotification)) { note in
                    // An ⌥ release delivered to a sheet / QuickTerminal / another window never
                    // reaches `handleOptionEvent` (window guard) — losing key is the disarm.
                    guard (note.object as? NSWindow) === window() else { return }
                    optionHeld = false
                    disarm()
                }
    }

    private func handleOptionEvent(_ ev: NSEvent) -> NSEvent? {
        // Local monitors are app-wide; QuickTerminal bypasses the fork seam, so ⌥⌥ in its
        // window would otherwise sweep our read-state.
        guard ev.window === window() else { return ev }
        if ev.type != .flagsChanged {
            if ev.modifierFlags.contains(.option) {
                lastOptionPress = nil
                disarm()
            }
            return ev
        }
        let flags = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let held = flags.contains(.option)
        // "Solo" = no chord modifiers — ⌘⌥1-9 host jumps and other ⌘/⇧/⌃ chords must
        // neither count as taps nor flash the reveal. Caps Lock / fn are not chords and
        // must not kill the gesture.
        let solo = held && flags.isDisjoint(with: [.command, .shift, .control])
        if solo, !optionHeld {
            let now = Date()
            // A second press inside the 0.4s window is a *candidate* sweep — committed on
            // release, so it can still turn into a hold (peek) or be disqualified.
            sweepOnRelease = lastOptionPress.map { now.timeIntervalSince($0) < 0.4 } ?? false
            lastOptionPress = now
            // Solo-hold peek arms after a beat; instant would still flash open in the gap
            // before a chord's keyDown lands. Re-check the hardware state at fire time — a
            // release swallowed by a tracking loop or delivered to another window must not
            // latch it on.
            revealArm = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                if NSEvent.modifierFlags.contains(.option) { setPeek(true) }
            }
        }
        if held, !solo, optionHeld {
            // A chord modifier joined an already-held ⌥ (⌥ first, then ⌘ for ⌘⌥N): that's a
            // chord in progress, not a peek — disarm the pending/active reveal and abandon
            // the half-completed tap so a slow chord can't flash the sidebar open.
            lastOptionPress = nil
            disarm()
        }
        if !held {
            // Tap-tap commits here — unless the press became a hold (the peek fired: you
            // were retrying the glance, not asking to sweep) or was disqualified above.
            let commitSweep = sweepOnRelease && !revealAll
            disarm()
            if commitSweep {
                onSweep()
                lastOptionPress = nil   // a third tap shouldn't chain into another sweep
            }
        }
        if held != optionHeld { optionHeld = held }
        return ev
    }

    /// Cancel a pending solo-hold peek, drop an active one, and abandon a half-completed ⌥⌥.
    private func disarm() {
        revealArm?.invalidate(); revealArm = nil
        sweepOnRelease = false
        setPeek(false)
    }

    /// The one writer of peek state — `revealAll` (sidebar status text) and the cheatsheet
    /// overlay open and close as a unit. Edge-triggered, so `onPeek` isn't spammed by the
    /// `disarm()` calls that land on every non-peek ⌥ release.
    private func setPeek(_ on: Bool) {
        guard revealAll != on else { return }
        revealAll = on
        onPeek(on)
    }
}
#endif
