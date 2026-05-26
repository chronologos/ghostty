#if os(macOS)
import SwiftUI
import Testing
@testable import Ghostty

/// Afterglow/doze carry two deliberate divergences a "unify through ramp()" refactor would
/// silently flip: opposite nil conventions (doze(nil) = awake, afterglow(nil) = no glow) and
/// afterglow's tighter 5m/15m breakpoints. Bucket interiors only — exact boundaries would
/// race the wall-clock read inside the functions.
@MainActor
struct ThemeRecencyTests {
    private let cutoff: TimeInterval = 16 * 3600
    private func ago(_ s: TimeInterval) -> Date { Date(timeIntervalSinceNow: -s) }

    @Test func nilConventions() {
        #expect(Theme.doze(nil, cutoff: cutoff) == 1)
        #expect(Theme.afterglow(nil) == .clear)
    }

    @Test func dozeBuckets() {
        #expect(Theme.doze(ago(60), cutoff: cutoff) == 1)
        #expect(Theme.doze(ago(2 * 3600), cutoff: cutoff) == 0.82)
        #expect(Theme.doze(ago(20 * 3600), cutoff: cutoff) == 0.55)
    }

    @Test func afterglowBuckets() {
        #expect(Theme.afterglow(ago(60)) != .clear)
        #expect(Theme.afterglow(ago(10 * 60)) != .clear)
        #expect(Theme.afterglow(ago(20 * 60)) == .clear)
    }

    @Test func focusCutoffGuard() {
        // Unset (UserDefaults 0) falls back to 16h — the same guard focusTabs uses.
        #expect(SessionRegistry.focusCutoffSeconds(hours: 0) == 16 * 3600)
        #expect(SessionRegistry.focusCutoffSeconds(hours: 4) == 4 * 3600)
    }
}
#endif
