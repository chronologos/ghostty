#if os(macOS)
import Foundation
import GhosttyKit

/// Force an alt-screen TUI (htop, less, vim, etc.) to repaint by synthesising
/// a SIGWINCH: bump height by one cell, then restore.
///
/// The 60ms gap is load-bearing for two stacked reasons:
///   1. `ghostty_surface_set_size` posts to the IO-thread mailbox, where
///      `termio/Thread.zig` coalesces resizes in a 25ms timer window
///      (`Coalesce.min_ms`). A restore enqueued inside that window overwrites
///      the pending bump and the pty never sees it.
///   2. SIGWINCH is non-queuing — the child must wake and `TIOCGWINSZ` the
///      bumped size before the restore lands, including the zmx client→server
///      hop (and ssh RTT for remote hosts).
/// 60ms clears (1) with margin and gives (2) ~35ms; high-RTT ssh may still
/// lose the race, in which case run it twice.
func forkWigglePane(_ view: Ghostty.SurfaceView) {
    guard let s = view.surface else { return }
    let origin = ghostty_surface_size(s)
    ghostty_surface_set_size(s, origin.width_px, origin.height_px + origin.cell_height_px)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) {
        guard let s2 = view.surface else { return }
        ghostty_surface_set_size(s2, origin.width_px, origin.height_px)
    }
}
#endif
