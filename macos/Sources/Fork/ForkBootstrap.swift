#if os(macOS)
import AppKit
import os

/// Entry point for the zmx-sidebar fork. All fork code lives under `macos/Sources/Fork/`;
/// upstream files carry exactly two `// [fork]` seam lines that call into here.
/// See `do_not_commit/ghostty-fork/SPEC.md`.
enum ForkBootstrap {
    static let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "fork")

    /// Master switch. PR1: opt-in via env var so upstream behavior is the default.
    static let enabled: Bool = ProcessInfo.processInfo.environment["GHOSTTY_FORK"] == "1"

    /// Seam #1 — called from `AppDelegate.applicationDidFinishLaunching` after config load.
    /// PR1: no-op beyond logging. PR2: loads `SessionRegistry` from `fork.json`.
    static func install(ghostty: Ghostty.App) {
        guard enabled else { return }
        logger.info("fork enabled (PR1 scaffold)")
    }

    /// Seam #2 — called from `TerminalController.newWindow` before it constructs a controller.
    /// Returning non-nil short-circuits upstream window creation.
    /// PR1: always nil. PR2: returns a `ForkWindowController` (which is-a `TerminalController`).
    static func intercept(
        _ ghostty: Ghostty.App,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration?,
        withParent parent: NSWindow?
    ) -> TerminalController? {
        guard enabled else { return nil }
        return nil
    }
}
#endif
