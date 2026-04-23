#if os(macOS)
import Foundation
import GhosttyKit

/// Force an alt-screen TUI (htop, less, vim, etc.) to repaint by synthesising
/// a SIGWINCH. Two `ghostty_surface_set_size` calls 16ms apart — first bumping
/// height by one cell, then restoring. The child's SIGWINCH handler sees two
/// distinct TIOCGWINSZ results and runs a full repaint.
///
/// The 16ms gap is load-bearing: back-to-back `TIOCSWINSZ` calls with the
/// same dims coalesce in the macOS kernel, so SIGWINCH fires once with
/// the final (unchanged) size and the handler's "size didn't change"
/// fast-path skips the repaint.
///
/// Ghostty's own pipeline serves this case for buffer-mode TUIs (replay
/// works), so this is only a remedy for alt-screen guests whose diff
/// stream isn't idempotent. If a zmx-attached alt-screen app ever shows
/// a stale frame after reattach, this is the lever.
func forkWigglePane(_ view: Ghostty.SurfaceView) {
    guard let s = view.surface else { return }
    let origin = ghostty_surface_size(s)
    // height + 1 cell, same width — minimum perturbation the kernel
    // can't coalesce back to a no-op.
    ghostty_surface_set_size(s, origin.width_px, origin.height_px + origin.cell_height_px)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) {
        guard let s2 = view.surface else { return }
        ghostty_surface_set_size(s2, origin.width_px, origin.height_px)
    }
}
#endif
