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

    /// Only a shell nobody named gives up its title for its path.
    @Test func plainLineIsForUnnamedShellsOnly() {
        func line(_ label: String?, _ name: String, renaming: Bool = false, place: String? = "~/src") -> String? {
            SidebarView.plainLine(label: label, name: name, renaming: renaming, place: place)
        }
        #expect(line(nil, "deputy-wbd5") == "~/src" && line(nil, "shell-k7w") == "~/src")
        #expect(line("api-prod", "api-prod") == nil, "a typed name is its own alias, and keeps its title")
        #expect(line("notes", "shell-k7w") == nil, "renamed since")
        #expect(line(nil, "deputy") == nil)
        #expect(line(nil, "shell-k7w", place: nil) == nil, "nothing to show instead")
        #expect(line(nil, "shell-k7w", renaming: true) == nil)
    }

    @Test func focusCutoffGuard() {
        // Unset (UserDefaults 0) falls back to 16h — the same guard focusTabs uses.
        #expect(SessionRegistry.focusCutoffSeconds(hours: 0) == 16 * 3600)
        #expect(SessionRegistry.focusCutoffSeconds(hours: 4) == 4 * 3600)
    }

    /// The tag square's parts: inside the square, a hairline apart, and together covering all of
    /// it but the hairlines — so no count leaves a hole or paints one tag over another.
    @Test func tagCellsTileTheSquare() {
        let side = TagMark.side, square = CGRect(x: 0, y: 0, width: side, height: side)
        for n in 1...TagMark.limit {
            let cells = (0..<n).map { TagMark.cell($0, of: n) }
            for (i, c) in cells.enumerated() {
                #expect(square.contains(c) && c.width >= 4 && c.height >= 4, "\(n) tags, part \(i)")
                for d in cells[(i + 1)...] {
                    #expect(!c.insetBy(dx: -0.5, dy: -0.5).intersects(d.insetBy(dx: -0.49, dy: -0.49)),
                            "\(n) tags: parts closer than a point")
                }
            }
            let hairlines = n == 1 ? 0 : n == 2 ? side : n == 3 ? side + 4 : 2 * side - 1
            #expect(cells.reduce(0) { $0 + $1.width * $1.height } == side * side - hairlines, "\(n) tags")
            #expect(TagMark.cell(n, of: n).width == 0, "the +N starts from nothing")
        }
    }
}
#endif
