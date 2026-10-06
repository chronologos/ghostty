#if os(macOS)
import SwiftUI
import Testing
@testable import Ghostty

/// Sleep's one convention a tidy-up would silently flip: nil ("never touched") is awake, not
/// ancient. Bucket interiors only — exact boundaries would race the wall-clock read inside
/// the function.
@MainActor
struct ThemeRecencyTests {
    private let cutoff: TimeInterval = 16 * 3600
    private func ago(_ s: TimeInterval) -> Date { Date(timeIntervalSinceNow: -s) }

    @Test func neverTouchedIsAwake() {
        #expect(!Theme.asleep(nil, cutoff: cutoff))
    }

    @Test func sleepsPastTheCutoffOnly() {
        #expect(!Theme.asleep(ago(60), cutoff: cutoff))
        #expect(!Theme.asleep(ago(2 * 3600), cutoff: cutoff))
        #expect(Theme.asleep(ago(20 * 3600), cutoff: cutoff))
        // A cutoff under an hour can't put a pane you used this hour to sleep.
        #expect(!Theme.asleep(ago(1800), cutoff: 600))
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
