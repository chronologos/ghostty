#if os(macOS)
import AppKit
import os

/// Entry point for the zmx-sidebar fork. All fork code lives under `macos/Sources/Fork/`;
/// upstream files carry exactly three `// [fork]` seam lines that call into here.
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
        // The environment itself was set up by `prepareEnvironment` (seam #3, before
        // `ghostty_init`); from here on it is read-only. This only refreshes the cache the
        // *next* launch will apply.
        refreshLoginPATHCache()
        // Force `localZmx` resolution now (a few `stat`s — it no longer shells out), so the
        // resolved path is in the log next to the PATH it was resolved against.
        logger.info("fork enabled — zmx: \(ZmxAdapter.localZmx, privacy: .public)")
        ForkNotify.shared.install()
        // Seed the sidebar's colors from the terminal theme before any window draws, and
        // follow reloads from here on. `install` is nonisolated but only ever runs from
        // `applicationWillFinishLaunching`, which is main — same assumption as the
        // willTerminate handler below; if that ever changes this traps rather than degrading.
        MainActor.assumeIsolated { ForkTheme.shared.start(ghostty.config) }
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

    /// Seam #3 — called from `main.swift` *before* `ghostty_init`. Every process-environment
    /// mutation the fork makes lives here and nowhere else.
    ///
    /// Why this can't wait for `install`: since the Zig 0.16 port, `ghostty_init` snapshots
    /// the C `environ` array as a slice (pointer + length — `main_c.zig`, `global.syncEnviron`)
    /// and builds every surface's env from that snapshot. A `setenv` after the snapshot that
    /// adds a variable reallocs the array, and one that grows a value reallocs the string, so
    /// the snapshot dangles: `createMap` reads freed memory, fails, and `Surface.zig` falls
    /// back to an *empty* env ("error getting env map for surface err=error.OutOfMemory").
    /// Panes then run with `PATH=<app>/Contents/MacOS` and nothing else — `zmx attach`
    /// survives (absolute path), while ssh panes and the detached placeholder die at exec.
    /// Whether the freed memory still happens to read back intact is up to the allocator,
    /// which is how this stayed latent until an OS update. So: mutate first, snapshot second,
    /// and never `setenv`/`unsetenv` again for the life of the process.
    static func prepareEnvironment() {
        guard enabled else { return }
        // GUI launches inherit launchd's bare PATH (/usr/bin:/bin:/usr/sbin:/sbin). Anything
        // the fork spawns that resolves helpers by *name* — ssh ProxyCommand wrappers in
        // ~/.ssh/config above all — fails with "command not found" unless a ControlMaster
        // socket already happens to exist, which reads as "host unreachable" / instantly-dead
        // panes on a cold morning. Apply last launch's cached login PATH now (instant, before
        // the zmx probe in `install` and any surface spawn); `install` refreshes the cache
        // in the background.
        exportCachedLoginPATH()
        scrubZmxEnvironment()
    }

    /// zmx reads three variables from the *client's* environment that change what the
    /// fork's own commands mean, and every pane / `Process` child inherits the app's:
    /// - `ZMX_SESSION` (injected into every shell inside a session) turns `zmx attach X`
    ///   into "switch the session I'm in to X": it never attaches, exits 0, and yanks the
    ///   *launching* pane's client onto the new name. Running the app binary from a fork
    ///   pane (the normal dev loop) would make every new local pane die into its
    ///   placeholder while hijacking the pane it was launched from.
    /// - `ZMX_SESSION_PREFIX` is prepended to every name, so listed names no longer start
    ///   with `{hostID}-` and the fork's own sessions file as external.
    /// - `ZMX_NO_DETACH_KEY` (set here, not scrubbed): ctrl+\ is zmx's in-band detach key,
    ///   which in a fork pane blanks it into the placeholder and makes SIGQUIT undeliverable
    ///   to the program inside. The fork owns detach (⌘W), so the key is only ever a
    ///   misfire. Read per attach by the client; older zmx ignores it. Remote attaches get
    ///   it through `Transport.wrap`'s env prefix.
    private static func scrubZmxEnvironment() {
        unsetenv("ZMX_SESSION")
        unsetenv("ZMX_SESSION_PREFIX")
        setenv("ZMX_NO_DETACH_KEY", "1", 1)
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
    ///
    /// Phase 1, pre-`ghostty_init` (see `prepareEnvironment`).
    private static func exportCachedLoginPATH() {
        let launchdPATH = ProcessInfo.processInfo.environment["PATH"] ?? ""
        if let cached = UserDefaults.standard.string(forKey: cachedLoginPATHKey), cached.contains("/") {
            setenv("PATH", mergedPATH(login: cached, current: launchdPATH), 1)
        }
    }

    /// Phase 2, from `install`: cache-only. The refreshed PATH used to be `setenv`'d live as
    /// well; that is exactly the post-snapshot mutation `prepareEnvironment` rules out (and
    /// panes stopped seeing it once libghostty began snapshotting `environ`), so a changed
    /// login PATH now takes effect at the next launch.
    private static func refreshLoginPATHCache() {
        let applied = ProcessInfo.processInfo.environment["PATH"] ?? ""
        DispatchQueue.global(qos: .utility).async {
            guard let login = loginShellPATH(timeout: 15), login.contains("/") else { return }
            let stale = UserDefaults.standard.string(forKey: cachedLoginPATHKey) != login
            UserDefaults.standard.set(login, forKey: cachedLoginPATHKey)
            logger.info("fork PATH: \(applied, privacy: .public)")
            if stale {
                logger.notice("login-shell PATH changed — applies at next launch: \(login, privacy: .public)")
            }
        }
    }

    /// Bounded probe of the user's login shell: run `cmd` under `$SHELL -lic`, return raw
    /// stdout once it hits EOF (the child's exit closes it), or nil after `timeout`. `cmd`
    /// must be a compile-time literal — this is deliberately NOT a third place where runtime
    /// strings meet a shell (CLAUDE.md §Security boundary). Caller: the background PATH
    /// refresh above (generous bound, off-main). A hung .zshrc must not leak a process:
    /// stdout drains via a handler (rc chatter bigger than the pipe
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
