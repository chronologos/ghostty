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
        // Force `localZmx` resolution now. `static let` is swift_once-serialized — a
        // detached "warm-up" can't beat main to the once-barrier, so we take the hit
        // here (before any window draws) rather than mid-`newWindow`.
        logger.info("fork enabled — zmx: \(ZmxAdapter.localZmx, privacy: .public)")
        let violet = NSColor(red: 0x7C/255, green: 0x5C/255, blue: 0xD3/255, alpha: 1)
        let icon = ColorizedGhosttyIcon(
            screenColors: [.systemPurple, violet],
            ghostColor: .white,
            frame: .aluminum
        ).makeImage(in: .main)
        NSApp.applicationIconImage = icon.flatMap { degauss($0, px: 6) } ?? icon
        // Flush pending debounced fork.json writes at quit — `$objectWillChange.debounce(500ms)`
        // means rename/tag/tab-switch made within the last half-second would otherwise be lost.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { SessionRegistry.shared.saveNow() } }
    }

    /// Chromatic-aberration "degauss" — split RGB, offset R/B by ±px, recombine. Channels
    /// are orthogonal so per-component max ≡ add; alpha stays correct via max(a,a,a)=a.
    private static func degauss(_ img: NSImage, px: CGFloat) -> NSImage? {
        guard let tiff = img.tiffRepresentation, let src = CIImage(data: tiff) else { return nil }
        func channel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, dx: CGFloat, dy: CGFloat) -> CIImage {
            src.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            ]).transformed(by: .init(translationX: dx, y: dy))
        }
        let composed = channel(0, 0, 1, dx: px, dy: -px)
            .applyingFilter("CIMaximumCompositing",
                            parameters: [kCIInputBackgroundImageKey: channel(0, 1, 0, dx: 0, dy: 0)])
            .applyingFilter("CIMaximumCompositing",
                            parameters: [kCIInputBackgroundImageKey: channel(1, 0, 0, dx: -px, dy: px)])
            .cropped(to: src.extent)
        let out = NSImage(size: img.size)
        out.addRepresentation(NSCIImageRep(ciImage: composed))
        return out
    }

    /// Seam #2 — called from `TerminalController.newWindow` before it constructs a controller.
    /// Returning non-nil short-circuits upstream window creation.
    ///
    /// `parent` is intentionally ignored: upstream uses it for native NSWindow tab-grouping,
    /// but the fork is single-window (sidebar tabs), so there is no second window to group.
    static func intercept(
        _ ghostty: Ghostty.App,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration?,
        withParent parent: NSWindow?
    ) -> TerminalController? {
        guard enabled else { return nil }
        // Shortcuts/AppleScript/Finder-open carry cwd/command in baseConfig. The fork is
        // zmx-native, so translate to a NewSessionIntent (cwd/cmd become the initial state of
        // a fresh zmx session) instead of passing the raw config to libghostty.
        let intent: NewSessionIntent? = baseConfig.flatMap { cfg in
            guard cfg.workingDirectory != nil || cfg.command != nil else { return nil }
            return NewSessionIntent(
                hostID: ForkHost.local.id,
                name: nil,
                cwd: cfg.workingDirectory,
                // AppleScript hands `command` over as a single shell-line string
                // (`vim "/tmp/with space.txt"`). Naive split-on-space mangles
                // quoted args; `sh -c` gives the user the shell semantics they
                // typed. Each argv element is shq'd downstream so the line itself
                // never touches an outer shell unquoted.
                cmd: cfg.command.map { ["/bin/sh", "-c", $0] }
            )
        }
        return ForkWindowController.newWindow(ghostty, intent: intent)
    }
}
#endif
