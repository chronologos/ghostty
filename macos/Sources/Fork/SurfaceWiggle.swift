#if os(macOS)
import Foundation
import GhosttyKit

/// Force a TUI (CC, htop, vim, etc.) to repaint by synthesising SIGWINCH:
/// bump height by one cell, restore, then repeat once.
///
/// Why two 200ms cycles instead of one 60ms:
///   1. `ghostty_surface_set_size` posts to the IO-thread mailbox, where
///      `termio/Thread.zig` coalesces resizes in a 25ms window
///      (`Coalesce.min_ms`) — a restore inside that window overwrites the
///      pending bump and the pty never sees it.
///   2. SIGWINCH is non-queuing — the child must wake and `TIOCGWINSZ` the
///      bumped size *before* the restore's `TIOCSWINSZ` lands, including the
///      zmx client→server hop and ssh RTT. If it loses that race it reads the
///      already-restored origin, sees no change, and skips the redraw.
/// 200ms per leg gives ~175ms for (2); the second cycle is the automated
/// "press it twice" so a single lost race doesn't drop the repaint. The
/// half-second of +1-row flicker doubles as visual feedback.
/// In-flight latch: a re-entrant call (held/double-tapped ⌘⇧R) would sample the bumped
/// height as its baseline and its own restore would leave the grid one row taller until
/// the next real resize. One wiggle per surface at a time; the trailing restore clears it.
/// Main-thread only (callers and the asyncAfter queue are both main).
private var wiggling = Set<ObjectIdentifier>()

func forkWigglePane(_ view: Ghostty.SurfaceView) {
    guard let s = view.surface else { return }
    let key = ObjectIdentifier(view)
    guard wiggling.insert(key).inserted else { return }
    let o = ghostty_surface_size(s)
    let w = o.width_px, h = o.height_px, bump = h + o.cell_height_px
    for (ms, height) in [(0, bump), (200, h), (250, bump), (450, h)] {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) {
            // Clear before the surface guard — a pane closed mid-wiggle must still unlatch.
            if ms == 450 { wiggling.remove(key) }
            guard let s = view.surface else { return }
            ghostty_surface_set_size(s, w, height)
        }
    }
}
#endif
