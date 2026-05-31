#if os(macOS)
import SwiftUI

/// ⌥ recognizer for the sidebar, extracted from `SidebarView` (it was ~105 lines of gesture
/// state interleaved with row rendering): a *solo* ⌥ held 0.5s arms `revealAll` (re-expand
/// every read CC status line for a fleet-wide glance); ⌥⌥ — two clean taps within 0.4s,
/// committed on the second *release* — fires `onSweep` (mark-all-read). Any key or mouse
/// event while ⌥ is down is a chord (readline ⌥b/⌥f, accented input, ⌘⌥N, ⌥-click/⌥-drag in
/// the terminal), not a tap or a peek — it disqualifies the in-flight press for both.
///
/// Owns its NSEvent local monitor (not the controller's `navMonitor`) so the gesture state
/// stays view-local `@State` and doesn't churn the registry's `objectWillChange` →
/// debounce-save on every modifier tap.
struct OptionGestureRecognizer: ViewModifier {
    /// The window whose events count — local monitors are app-wide, and ⌥⌥ in a sheet /
    /// QuickTerminal / another window must not sweep this sidebar's read-state. A closure
    /// (not a captured value) because the window can be nil at attach time.
    let window: () -> NSWindow?
    @Binding var revealAll: Bool
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
            // Solo-hold reveal arms after a beat (the cheatsheet's ⌘-hold idiom); instant
            // would still flash open in the gap before a chord's keyDown lands. Re-check
            // the hardware state at fire time — a release swallowed by a tracking loop or
            // delivered to another window must not latch it on.
            revealArm = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                if NSEvent.modifierFlags.contains(.option) { revealAll = true }
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

    /// Cancel a pending solo-hold reveal, drop an active one, and abandon a half-completed ⌥⌥.
    private func disarm() {
        revealArm?.invalidate(); revealArm = nil
        sweepOnRelease = false
        if revealAll { revealAll = false }
    }
}
#endif
