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

    // (The GHOSTTY_FORK_NO_SIDEBAR / NO_ZMX / NO_PICKER bisect toggles were removed — they
    // dated from early bring-up; GHOSTTY_FORK=0 disables the whole fork and GHOSTTY_FORK_ZMX
    // still overrides zmx resolution.)

    /// Seam #1 — called from `AppDelegate.applicationWillFinishLaunching` (a near-frozen
    /// upstream function, unlike `applicationDidFinishLaunching` which churns every release
    /// and used to host this seam). Nothing here needs config or windows; `ForkNotify`'s
    /// delegate wrap is deferred to the main queue, which AppKit doesn't drain until after
    /// `applicationDidFinishLaunching` returns, so it still lands after upstream's
    /// `center.delegate = self`.
    static func install(ghostty: Ghostty.App) {
        guard enabled else { return }
        // GUI launches inherit launchd's bare PATH (/usr/bin:/bin:/usr/sbin:/sbin). Anything
        // the fork spawns that resolves helpers by *name* — ssh ProxyCommand wrappers in
        // ~/.ssh/config above all — fails with "command not found" unless a ControlMaster
        // socket already happens to exist, which reads as "host unreachable" / instantly-dead
        // panes on a cold morning. Apply last launch's cached login PATH now (instant, before
        // the zmx probe below and any surface spawn), then refresh it in the background.
        exportLoginShellPATH()
        // Force `localZmx` resolution now. `static let` is swift_once-serialized — a
        // detached "warm-up" can't beat main to the once-barrier, so we take the hit
        // here (before any window draws) rather than mid-`newWindow`.
        logger.info("fork enabled — zmx: \(ZmxAdapter.localZmx, privacy: .public)")
        ForkNotify.shared.install()
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
        ) { _ in MainActor.assumeIsolated {
            // ⌘Q never sends windowWillClose (AppKit terminates without closing windows),
            // so the focused pane's departure must be exit-stamped here — otherwise it
            // persists with its *arrival* time and reads hours-stale after relaunch.
            SessionRegistry.shared.flushPaneExit()
            SessionRegistry.shared.saveNow()
        } }
    }

    /// Inherited entries first — the control plane's `ssh`/`sh`/`nc` keep resolving to the
    /// same system binaries they always have — then login-shell entries appended for
    /// everything launchd's PATH lacks (ProxyCommand wrappers, zmx, hover tools). First
    /// occurrence wins; empty and relative segments are dropped (a relative PATH entry
    /// resolves against whatever cwd a child happens to have).
    static func mergedPATH(login: String, current: String) -> String {
        var seen = Set<String>()
        return (current.split(separator: ":") + login.split(separator: ":"))
            .map(String.init)
            .filter { $0.hasPrefix("/") && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    /// UserDefaults key holding the last successful login-shell PATH probe.
    private static let cachedLoginPATHKey = "forkCachedLoginPATH"

    /// Two-phase: apply the cached PATH synchronously (instant — launch must never block on
    /// a login shell), then refresh the cache via a background probe with a generous bound.
    /// The old single-phase design (inline 2s probe) failed both ways on real machines: rc
    /// inits measured at 2-4s mean it burned its full bound at every launch *and* came back
    /// empty, silently leaving the export absent — the "cold morning unreachable" failure
    /// this function exists to prevent.
    private static func exportLoginShellPATH() {
        let launchdPATH = ProcessInfo.processInfo.environment["PATH"] ?? ""
        if let cached = UserDefaults.standard.string(forKey: cachedLoginPATHKey), cached.contains("/") {
            setenv("PATH", mergedPATH(login: cached, current: launchdPATH), 1)
        }
        DispatchQueue.global(qos: .utility).async {
            guard let login = loginShellPATH(timeout: 15), login.contains("/") else { return }
            let merged = mergedPATH(login: login, current: launchdPATH)
            // setenv on main: children snapshot env at spawn, so anything launched before
            // the refresh lands just keeps the cached view (good enough — it was last
            // launch's answer).
            DispatchQueue.main.async {
                setenv("PATH", merged, 1)
                UserDefaults.standard.set(login, forKey: cachedLoginPATHKey)
                logger.info("fork PATH: \(merged, privacy: .public)")
            }
        }
    }

    /// Bounded probe of the user's login shell: run `cmd` under `$SHELL -lic`, return raw
    /// stdout once it hits EOF (the child's exit closes it), or nil after `timeout`. `cmd`
    /// must be a compile-time literal — this is deliberately NOT a third place where runtime
    /// strings meet a shell (CLAUDE.md §Security boundary). Callers: the background PATH
    /// refresh above (generous bound, off-main) and `ZmxAdapter.localZmx`'s last-resort
    /// lookup (2s, on main before the first window draws) — for the latter a hung .zshrc
    /// must not wedge launch: stdout drains via a handler (rc chatter bigger than the pipe
    /// buffer can't deadlock the child into the timeout), the wait is bounded, and
    /// interactive zsh ignores SIGTERM, so on timeout the probe's process group is
    /// SIGKILLed and we give up.
    static func loginShellOutput(_ cmd: String, timeout: TimeInterval = 2) -> String? {
        let p = Process(), pipe = Pipe(), done = DispatchSemaphore(value: 0)
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-lic", cmd]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        let lock = NSLock()
        var out = Data()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            // EOF (not exit) is the completion signal: it can only arrive after every write
            // end closed, so `out` is complete by construction — no exit-vs-last-chunk race.
            if chunk.isEmpty { h.readabilityHandler = nil; done.signal(); return }
            lock.lock(); out.append(chunk); lock.unlock()
        }
        guard (try? p.run()) != nil else {
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            pipe.fileHandleForReading.readabilityHandler = nil
            Darwin.kill(-p.processIdentifier, SIGKILL)
            return nil
        }
        lock.lock(); defer { lock.unlock() }
        return String(decoding: out, as: UTF8.self)
    }

    /// The marker prefix keeps rc-file chatter (nvm init, direnv, fortune) from being
    /// mistaken for the answer.
    private static func loginShellPATH(timeout: TimeInterval) -> String? {
        loginShellOutput("printf '__FORKPATH__%s\\n' \"$PATH\"", timeout: timeout)?
            .split(separator: "\n").last(where: { $0.hasPrefix("__FORKPATH__") })
            .map { String($0.dropFirst("__FORKPATH__".count)) }
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
