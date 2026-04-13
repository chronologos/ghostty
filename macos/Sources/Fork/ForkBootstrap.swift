#if os(macOS)
import AppKit
import os

/// Entry point for the zmx-sidebar fork. All fork code lives under `macos/Sources/Fork/`;
/// upstream files carry exactly two `// [fork]` seam lines that call into here.
/// See `do_not_commit/ghostty-fork/SPEC.md`.
enum ForkBootstrap {
    static let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "fork")

    /// Master switch. Debug builds: opt-in via `GHOSTTY_FORK=1`. `fork-release.sh` passes
    /// `-DGHOSTTY_FORK_DEFAULT` so release builds are opt-out via `GHOSTTY_FORK=0`.
    static let enabled: Bool = {
        #if GHOSTTY_FORK_DEFAULT
        return ProcessInfo.processInfo.environment["GHOSTTY_FORK"] != "0"
        #else
        return ProcessInfo.processInfo.environment["GHOSTTY_FORK"] == "1"
        #endif
    }()

    /// Debug toggles for bisecting layout/zmx issues.
    static let noSidebar: Bool = ProcessInfo.processInfo.environment["GHOSTTY_FORK_NO_SIDEBAR"] == "1"
    static let noZmx: Bool = ProcessInfo.processInfo.environment["GHOSTTY_FORK_NO_ZMX"] == "1"
    static let noPicker: Bool = ProcessInfo.processInfo.environment["GHOSTTY_FORK_NO_PICKER"] == "1"

    /// Seam #1 — called from `AppDelegate.applicationDidFinishLaunching` after config load.
    /// PR1: no-op beyond logging. PR2: loads `SessionRegistry` from `fork.json`.
    static func install(ghostty: Ghostty.App) {
        guard enabled else { return }
        logger.info("fork enabled")
        // Warm `localZmx` off the main thread — its login-shell probe can take seconds.
        Task.detached(priority: .utility) {
            logger.info("zmx resolved: \(ZmxAdapter.localZmx, privacy: .public)")
        }
        let clay = NSColor(red: 0xD9/255, green: 0x77/255, blue: 0x57/255, alpha: 1)
        NSApp.applicationIconImage = ColorizedGhosttyIcon(
            screenColors: [.systemOrange, clay],
            ghostColor: .white,
            frame: .aluminum
        ).makeImage(in: .main)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in SessionRegistry.shared.saveNow() }
    }

    /// Seam #2 — called from `TerminalController.newWindow` before it constructs a controller.
    /// Returning non-nil short-circuits upstream window creation.
    static func intercept(
        _ ghostty: Ghostty.App,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration?,
        withParent parent: NSWindow?
    ) -> TerminalController? {
        guard enabled else { return nil }
        return ForkWindowController.newWindow(ghostty)
    }
}
#endif
