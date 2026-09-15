#if os(macOS)
import SwiftUI
import Testing
@testable import Ghostty

/// Afterglow/doze carry two deliberate divergences a "unify through ramp()" refactor would
/// silently flip: opposite nil conventions (doze(nil) = awake, afterglow(nil) = no glow) and
/// different keys — doze fades by *age*, afterglow by *rank* in the visit order (an age
/// bucket lit every row passed while cycling through a fleet). Bucket interiors only — exact
/// boundaries would race the wall-clock read inside the functions.
@MainActor
struct ThemeRecencyTests {
    private let cutoff: TimeInterval = 16 * 3600
    private func ago(_ s: TimeInterval) -> Date { Date(timeIntervalSinceNow: -s) }

    @Test func nilConventions() {
        #expect(Theme.doze(nil, cutoff: cutoff) == 1)
        #expect(Theme.afterglow(rank: nil) == .clear)
    }

    @Test func dozeBuckets() {
        #expect(Theme.doze(ago(60), cutoff: cutoff) == 1)
        #expect(Theme.doze(ago(2 * 3600), cutoff: cutoff) == 0.82)
        #expect(Theme.doze(ago(20 * 3600), cutoff: cutoff) == 0.55)
    }

    @Test func afterglowFadesByRankThenStops() {
        let steps = (0..<3).map { Theme.afterglow(rank: $0) }
        #expect(steps.allSatisfy { $0 != .clear })
        // Each step of the trail is its own strength.
        #expect(steps[0] != steps[1] && steps[1] != steps[2] && steps[0] != steps[2])
        #expect(Theme.afterglow(rank: 3) == .clear)
    }

    // MARK: Trail ranking (`SessionRegistry.trail`)

    private typealias Key = SessionRegistry.PaneTrailKey
    private let tabA = TabModel.ID(), tabB = TabModel.ID()
    private func key(_ t: TabModel.ID, _ p: String) -> Key { Key(tab: t, pane: p) }

    /// Newest first, the pane you're in left out, three deep.
    @Test func trailRanksByVisitOrder() {
        let now = Date()
        let stamps: [(key: Key, at: Date)] = [
            (key(tabA, "old"), now.addingTimeInterval(-600)),
            (key(tabA, "here"), now.addingTimeInterval(-1)),
            (key(tabB, "prev"), now.addingTimeInterval(-30)),
            (key(tabB, "older"), now.addingTimeInterval(-1200)),
            (key(tabA, "prev2"), now.addingTimeInterval(-90)),
        ]
        let ranks = SessionRegistry.trail(stamps, excluding: key(tabA, "here"), now: now)
        #expect(ranks == [key(tabB, "prev"): 0, key(tabA, "prev2"): 1, key(tabA, "old"): 2])
    }

    /// The saturation case the rank exists for: everything touched in the last minute —
    /// an age bucket would light all of it; the trail still names exactly three, in order.
    @Test func trailDoesNotSaturateWhenCycling() {
        let now = Date()
        let stamps = (0..<9).map { (key: key(tabA, "p\($0)"), at: now.addingTimeInterval(-Double($0) * 5)) }
        let ranks = SessionRegistry.trail(stamps, excluding: nil, now: now)
        #expect(ranks.count == 3)
        #expect(ranks[key(tabA, "p0")] == 0 && ranks[key(tabA, "p2")] == 2)
    }

    /// Same pane name in two tabs is two panes; and a visit past the window is history —
    /// the last panes before lunch don't still glow after it.
    @Test func trailKeysByTabAndExpires() {
        let now = Date()
        let stamps: [(key: Key, at: Date)] = [
            (key(tabA, "acr"), now.addingTimeInterval(-10)),
            (key(tabB, "acr"), now.addingTimeInterval(-20)),
            (key(tabA, "lunch"), now.addingTimeInterval(-SessionRegistry.trailWindow - 60)),
        ]
        let ranks = SessionRegistry.trail(stamps, excluding: nil, now: now)
        #expect(ranks == [key(tabA, "acr"): 0, key(tabB, "acr"): 1])
    }

    /// Line two drops a CC name that only repeats line one — but only a real repeat.
    @Test func ccNameEchoesTitle() {
        #expect(SidebarView.echoes("API-SERVER", title: "api_server"))
        #expect(SidebarView.echoes("build", title: "BUILD"))
        #expect(!SidebarView.echoes("WEB-WORKER", title: "worker"))
        #expect(!SidebarView.echoes("--", title: "··"), "names that fold to nothing never match")
        #expect(!SidebarView.echoes("", title: ""))
    }

    @Test func focusCutoffGuard() {
        // Unset (UserDefaults 0) falls back to 16h — the same guard focusTabs uses.
        #expect(SessionRegistry.focusCutoffSeconds(hours: 0) == 16 * 3600)
        #expect(SessionRegistry.focusCutoffSeconds(hours: 4) == 4 * 3600)
    }
}
#endif
