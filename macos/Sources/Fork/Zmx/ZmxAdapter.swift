#if os(macOS)
import Foundation

/// Only place in the fork that knows zmx's CLI shape or builds shell strings (SPEC §4).
enum ZmxAdapter {
    /// Absolute local path to `zmx`. Spotlight/Dock launches inherit launchd's minimal
    /// PATH, and Ghostty runs commands via `bash --noprofile --norc`, so bare `zmx` fails.
    /// Resolved once: env override → current PATH (usually already enriched by install()'s
    /// login-PATH export) → common install dirs → login-shell probe.
    static let localZmx: String = {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = [env["GHOSTTY_FORK_ZMX"]]
        candidates += (env["PATH"] ?? "").split(separator: ":").map { "\($0)/zmx" }
        candidates += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                       "\(home)/.cargo/bin", "\(home)/bin", "\(home)/.nix-profile/bin",
                       "/run/current-system/sw/bin", "/nix/var/nix/profiles/default/bin",
                       "/opt/local/bin"].map { "\($0)/zmx" }
        if let hit = candidates.compactMap({ $0 }).first(where: fm.isExecutableFile(atPath:)) {
            return hit
        }
        // Last resort: ask the user's login shell (rarely reached now that install() exports
        // the login PATH before forcing this). Bounded inside `loginShellOutput` — a hung
        // .zshrc must not wedge the static-let initializer (and with it, every caller).
        // `-i` sources .zshrc, which may chatter to stdout (nvm/pyenv init, fortune) —
        // `command -v` is the last line.
        if let out = ForkBootstrap.loginShellOutput("command -v zmx")?
            .split(separator: "\n").last.map(String.init),
           (out as NSString).lastPathComponent == "zmx",
           fm.isExecutableFile(atPath: out) {
            return out
        }
        ForkBootstrap.logger.warning("zmx not resolved; falling back to PATH lookup")
        return "zmx"
    }()

    /// Remote hosts use bare `zmx` (resolved by the remote shell's PATH).
    private static func zmx(on host: ForkHost) -> String {
        host.transport.isLocal ? localZmx : "zmx"
    }

    /// On-the-wire name. Managed refs get `{hostID}-` prefix; external refs use raw name.
    static func wireName(_ ref: SessionRef) -> String {
        ref.external ? ref.name : "\(ref.hostID)-\(ref.name)"
    }

    /// Whole-token placeholder substitution for `HoverCommand.cmd`. Output is an argv array
    /// fed to `surfaceConfig(initialCmd:)` (→ `Transport.wrap` → `shq`) or `Process.arguments`
    /// — both treat each element as one word, so an untrusted `cwd` stays inert. Substring
    /// substitution is intentionally not supported (would invite `"-C={cwd}"`-style configs
    /// that are still safe here but train the wrong habit).
    /// `{cwd}` must be an absolute path: it comes from OSC 7 / the CC probe (both
    /// remote-controlled), and a relative or dash-leading value handed to a local tool
    /// (`open`, `lazygit -p`) would be parsed as an option or resolve somewhere surprising.
    static func expand(_ argv: [String], host: ForkHost, ref: SessionRef, cwd: String?) -> [String] {
        let hostStr = switch host.transport {
        case .local: host.label
        case .ssh(let t): t.connectionString
        }
        let safeCwd = (cwd?.hasPrefix("/") ?? false) ? cwd! : "."
        return argv.map {
            switch $0 {
            case "{cwd}": safeCwd
            case "{ref}": ref.name
            case "{host}": hostStr
            default: $0
            }
        }
    }

    /// "Smart jump" initial command (⌘⏎ in the session picker): start the new session's
    /// shell in the directory the user's zsh-z frecency database considers the best match
    /// for `name`. The jump runs *inside* the session, on the session's host — remote
    /// sessions resolve against the remote host's z database, and there's no pre-creation
    /// resolution round-trip. No match / plugin absent → the cd silently doesn't happen
    /// and the shell starts in its default directory.
    ///
    /// Shell-string builder rules (CLAUDE.md §Security): `name` must pass the managed
    /// charset (refuse to build otherwise) AND is `shq`'d — both layers, same as every
    /// other dynamic token that meets a shell.
    static func smartJumpCmd(name: String) -> [String]? {
        guard isValidIdent(name) else { return nil }
        // `zshz` is a zsh *function* (plugin), not a binary — only an interactive zsh that
        // sourced the user's .zshrc has it. The inner wrapper cd's via the function, then
        // execs a clean login shell that inherits the cwd.
        let jump = "zshz -- \(shq(name)) 2>/dev/null; exec zsh -l"
        // Outer `sh` guard: a host without zsh must degrade to a normal session in the
        // default directory (the documented fallback), not a dead pane from a failed exec.
        // `shq(jump)` nests the already-quoted name correctly (POSIX close-escape-reopen).
        return ["sh", "-c",
                "command -v zsh >/dev/null 2>&1 && exec zsh -ilc \(shq(jump)); exec \"${SHELL:-sh}\" -l"]
    }

    /// SurfaceConfiguration whose pty child is `zmx attach <wireName> [cmd...]`, wrapped by transport.
    static func surfaceConfig(
        host: ForkHost,
        ref: SessionRef,
        initialCmd: [String]? = nil,
        cwd: String? = nil
    ) -> Ghostty.SurfaceConfiguration {
        var c = Ghostty.SurfaceConfiguration()
        if host.transport.isLocal { c.workingDirectory = cwd }
        let argv = [zmx(on: host), "attach", wireName(ref)] + (initialCmd ?? [])
        c.command = host.transport.wrap(argv)
        return c
    }

    struct ListEntry: Hashable {
        var name: String
        var clients: Int
        var created: Date
        var external: Bool
        var pid: Int32?
    }

    struct ListResult {
        var managed: [ListEntry] = []
        var external: [ListEntry] = []
    }

    /// `zmx list` partitioned into fork-managed and external. `nil` means the *query* failed
    /// (host unreachable, ssh refused, zmx missing) — callers must not render that as an
    /// empty-but-healthy host; an empty `ListResult` means the query worked and found nothing.
    static func list(host: ForkHost, timeout: TimeInterval = 5) async -> ListResult? {
        let argv = host.transport.controlArgv([zmx(on: host), "list"])
        guard let out = try? await run(argv: argv, timeout: timeout) else { return nil }
        return partition(out, hostID: host.id)
    }

    /// Pure half of `list()` (separated for tests): full k=v lines → fork-managed
    /// (prefix-stripped) / external. Dead-socket lines (`err=…`) are dropped, as are names
    /// `zmx` itself would parse as options (leading `-`) — those can never become a safe
    /// `SessionRef`.
    static func partition(_ output: String, hostID: ForkHost.ID) -> ListResult {
        let prefix = "\(hostID)-"
        var r = ListResult()
        for line in output.split(separator: "\n") {
            guard var e = parse(line: line) else { continue }
            // Only a name the fork could have created itself (managed charset) is trusted
            // as managed: the wire prefix alone is forgeable by anyone on the host, and a
            // forged name with shell-hostile characters must not become a non-external
            // `SessionRef` (downstream code assumes managed ⇒ `isValid` — derived-name
            // seeding, `Persistence.scrub`'s rule choice). Forged-prefix names that fail
            // the charset stay external under their full wire name.
            if e.name.hasPrefix(prefix), isValidIdent(String(e.name.dropFirst(prefix.count))) {
                e.name = String(e.name.dropFirst(prefix.count))
                e.external = false
            }
            // Checked AFTER the prefix strip so `h1--foo` can't smuggle a dash-leading
            // managed name through; applies to both partitions.
            guard isSafeExternalName(e.name) else { continue }
            if e.external { r.external.append(e) } else { r.managed.append(e) }
        }
        return r
    }

    /// zmx util.zig:539 — `[→ |  ]name=…\tpid=…\tclients=…\tcreated=…[\t…]`.
    /// `created` is unix seconds (the `ns` comment at main.zig:359 is stale).
    static func parse(line: Substring) -> ListEntry? {
        var kv: [Substring: Substring] = [:]
        for tok in line.drop(while: { $0 == " " || $0 == "→" }).split(separator: "\t") {
            guard let eq = tok.firstIndex(of: "=") else { continue }
            kv[tok[..<eq]] = tok[tok.index(after: eq)...]
        }
        guard kv["err"] == nil,
              let name = kv["name"],
              let clients = kv["clients"].flatMap({ Int($0) }),
              let created = kv["created"].flatMap({ TimeInterval($0) })
        else { return nil }
        return .init(name: String(name), clients: clients,
                     created: Date(timeIntervalSince1970: created), external: true,
                     pid: kv["pid"].flatMap { Int32($0) })
    }

    /// Shell command for a detached-placeholder surface: shows a prompt, waits for ⏎,
    /// then execs `zmx attach` for the same ref via the host's transport. `ccName` is the
    /// cached `tab.ccNames[ref.key]` — printed dim on a second line so a cold-restored
    /// pane whose session is gone still says what it used to be.
    static func detachedScript(host: ForkHost, ref: SessionRef, ccName: String? = nil) -> String {
        // `attach` is already a fully shq'd command line (each token single-quoted),
        // so it's interpolated *unquoted* after `exec` — wrapping it again would make
        // it one word. shq is total (POSIX `'` → `'\''`); see TransportTests.wrapSshInjection.
        let attach = host.transport.wrap([zmx(on: host), "attach", wireName(ref)])
        // External `ref.name` is raw remote `zmx list` output (validation is bypassed for
        // externals — Persistence.swift scrub) and reaches the local pty via `printf %s`.
        // `ccName` round-trips through hand-editable fork.json, so it gets the same
        // control-stripping before it is printed to the local terminal.
        let msg = "session \(stripControl(ref.name, max: 128)) — press ⏎ to reattach, ⌘⇧W to close"
        let was = ccName.map { "; printf '\\033[2m  was: %s\\033[0m\\n' \(shq(stripControl($0, max: 96)))" } ?? ""
        return shq(["sh", "-c", "printf '%s\\n' \(shq(msg))\(was); read _; exec \(attach)"])
    }

    /// `initialCmd` for a cold-restored leaf with a cached CC name. `zmx attach` only runs
    /// the trailing argv when *creating* the session, so an existing session ignores this and
    /// a fresh one shows the banner above its first prompt.
    static func restoreCmd(ccName: String) -> [String] {
        ["sh", "-c", "printf '\\033[2m  was: %s\\033[0m\\n\\n' \(shq(stripControl(ccName, max: 96))); exec ${SHELL:-/bin/sh}"]
    }

    static func kill(host: ForkHost, ref: SessionRef) async throws {
        let argv = host.transport.controlArgv([zmx(on: host), "kill", wireName(ref)])
        _ = try await run(argv: argv, timeout: 5)
    }

    static func history(host: ForkHost, ref: SessionRef) async throws -> String {
        let argv = host.transport.controlArgv([zmx(on: host), "history", wireName(ref)])
        return try await run(argv: argv, timeout: 10)
    }

    // MARK: -

    /// A control command that ran but exited non-zero — distinct from a timeout
    /// (`CancellationError`). Carries the tail of stderr so "ssh: connect refused" /
    /// "no such session" reach a log line or an alert instead of reading as success.
    struct CommandError: Error, CustomStringConvertible {
        let status: Int32
        let stderr: String
        var description: String { "exit \(status)" + (stderr.isEmpty ? "" : " — \(stderr)") }
    }

    /// Wall-clock-bounded, fully event-driven: stdout/stderr arrive via readability
    /// handlers, exit via the termination handler, deadlines via timers — all serialized on
    /// one queue, so no thread ever blocks. The previous shape parked a GCD thread in
    /// `readDataToEndOfFile` + `waitUntilExit`; when Foundation lost track of a SIGKILLed
    /// child's exit, that wait never returned and — because `ccPollLoop` awaits every host
    /// task — CC polling and the reachability cue froze for *all* hosts.
    ///
    /// Completion rules:
    /// - stdout EOF **and** exit status seen → success (status 0) or `CommandError`.
    ///   A failed control command must not read as "ran fine, empty output" — that's how
    ///   kills silently don't kill and unreachable hosts render as "no sessions". A
    ///   *failure* additionally gives stderr the same `grace` to land so the error isn't
    ///   an empty string; success never waits on stderr (ControlMaster mux masters and
    ///   ProxyCommand helpers hold it open long after the client exits).
    /// - exit seen but stdout EOF missing after `grace` → resolve by status with whatever
    ///   stdout accumulated: a grandchild holding the write-end (the same mux/helper class)
    ///   must not stall the result — and is left alone, a surviving master is often the point.
    /// - stdout EOF seen but exit unobserved after `grace` (Foundation losing a child's
    ///   termination is a real, observed failure mode) → SIGKILL the group (with no status
    ///   we can't tell a wanted survivor from a hung child) and throw `CommandError`
    ///   ("exit status unobserved") — never fake success, never hang.
    /// - `timeout` first → resolve from whichever leg did arrive; with neither, SIGKILL the
    ///   child's process group (`Process` gives the child its own pgid, so `-pid` reaches
    ///   grandchildren too) and throw `CancellationError`.
    static func run(argv: [String], timeout: TimeInterval) async throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        /// Mutable state, touched only on `q`.
        final class RunState: @unchecked Sendable {
            var out = Data()
            var err = Data()
            var stdoutEOF = false
            var stderrEOF = false
            var status: Int32?
            var done = false
            var graceArmed = false
            var cancelled = false
            var abort: (() -> Void)?
        }
        let q = DispatchQueue(label: "fork.zmx.run")
        let box = RunState()
        let grace: TimeInterval = 1.5

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                q.async {
                    /// Resolve exactly once; tear down the handlers so the Pipe↔handler and
                    /// Process↔handler retain cycles break even when a leg never reported.
                    /// Nil-ing `abort` also means a task cancellation that lands after we've
                    /// already resolved can't SIGKILL survivors (a freshly established
                    /// ControlMaster master, say) we just returned success around.
                    func settle(_ r: Result<String, Error>) {
                        guard !box.done else { return }
                        box.done = true
                        box.abort = nil
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        p.terminationHandler = nil
                        cont.resume(with: r)
                        // The deadline closure keeps `box` alive until `timeout` even after an
                        // early settle; drop the buffers so a finished ⌘⇧K history call doesn't
                        // hold a duplicate multi-MB copy for the rest of its window.
                        box.out = Data()
                        box.err = Data()
                    }
                    /// Only while the exit is unobserved — after a clean exit the survivors
                    /// are wanted (a freshly established ControlMaster master, say), not strays.
                    func kill() {
                        if box.status == nil, p.processIdentifier > 0 {
                            Darwin.kill(-p.processIdentifier, SIGKILL)
                        }
                    }
                    func finishFromState() {
                        switch box.status {
                        case .some(0):
                            settle(.success(String(decoding: box.out, as: UTF8.self)))
                        case .some(let st):
                            // stderr is remote-controlled bytes (whatever ssh / zmx / the
                            // remote shell emits) and ends up in os_log lines and alert
                            // text — strip terminal escapes at the source.
                            let msg = stripControl(
                                String(decoding: box.err.suffix(512), as: UTF8.self)
                                    .trimmingCharacters(in: .whitespacesAndNewlines),
                                max: 512)
                            settle(.failure(CommandError(status: st, stderr: msg)))
                        case .none:
                            // Output arrived and the pipes closed, but the exit never reached
                            // us. The command *probably* ran fine — but "probably" isn't good
                            // enough for kill verification or list()'s nil-vs-empty contract,
                            // so report failure (callers degrade to keep-last-known / a logged
                            // error) rather than fake the one outcome this file exists to
                            // never fake.
                            ForkBootstrap.logger.warning(
                                "control command exit unobserved (\(argv.first ?? "", privacy: .public))")
                            settle(.failure(CommandError(status: -1, stderr: "exit status unobserved")))
                        }
                    }
                    func maybeSettle() {
                        guard !box.done else { return }
                        // A failure also waits for stderr EOF (bounded by the same grace) so
                        // CommandError doesn't race the err pipe to an empty message; success
                        // never waits on stderr.
                        if box.stdoutEOF, let st = box.status, st == 0 || box.stderrEOF {
                            finishFromState(); return
                        }
                        if box.stdoutEOF || box.status != nil, !box.graceArmed {
                            box.graceArmed = true
                            q.asyncAfter(deadline: .now() + grace) {
                                guard !box.done else { return }
                                kill()
                                finishFromState()
                            }
                        }
                    }

                    box.abort = {
                        kill()
                        settle(.failure(CancellationError()))
                    }
                    if box.cancelled { box.abort?(); return }

                    // Accumulation caps: a runaway/hostile child can write at pipe speed for
                    // the whole timeout window — without a ceiling, `zmx history` over a
                    // pathological buffer (or a compromised remote streaming garbage) grows
                    // these Data buffers without bound. Past the cap we keep *draining* (so
                    // the child can't block on a full pipe and wedge into the deadline) but
                    // stop retaining. 8 MiB stdout covers any legitimate history; stderr is
                    // diagnostics only.
                    let outCap = 8 << 20, errCap = 256 << 10
                    outPipe.fileHandleForReading.readabilityHandler = { h in
                        let chunk = h.availableData
                        // Detach on the handler's own queue — deferring the nil to `q`
                        // would let an EOF'd handle re-fire in a tight loop until it lands.
                        if chunk.isEmpty { h.readabilityHandler = nil }
                        q.async {
                            if chunk.isEmpty { box.stdoutEOF = true; maybeSettle() }
                            else if box.out.count < outCap { box.out.append(chunk) }
                        }
                    }
                    errPipe.fileHandleForReading.readabilityHandler = { h in
                        let chunk = h.availableData
                        if chunk.isEmpty { h.readabilityHandler = nil }
                        q.async {
                            if chunk.isEmpty { box.stderrEOF = true; maybeSettle() }
                            else if box.err.count < errCap { box.err.append(chunk) }
                        }
                    }
                    p.terminationHandler = { t in
                        let st = t.terminationStatus
                        q.async { box.status = st; maybeSettle() }
                    }

                    do { try p.run() } catch {
                        settle(.failure(error))
                        return
                    }
                    // Close our copy of the write-ends now: the child has its dups, and with
                    // ours gone the readability handlers see EOF as soon as the child's
                    // copies close (a grandchild that inherits one is what `grace` is for).
                    try? outPipe.fileHandleForWriting.close()
                    try? errPipe.fileHandleForWriting.close()

                    // Hard deadline. The closure holds the pipes until it fires even when
                    // the command finished long before — bounded by `timeout`, so at most a
                    // handful of fds linger for a few seconds; not worth a cancelable token.
                    q.asyncAfter(deadline: .now() + timeout) {
                        guard !box.done else { return }
                        kill()
                        // If a leg did arrive (a status moments ago, or output whose exit got
                        // lost), report that rather than discarding it as a bare timeout.
                        if box.stdoutEOF || box.status != nil { finishFromState() }
                        else { settle(.failure(CancellationError())) }
                    }
                }
            }
        } onCancel: {
            q.async {
                box.cancelled = true
                box.abort?()
            }
        }
    }
}

extension ForkHost.Transport {
    /// Shell string for libghostty's `command` field — interactive (tty-allocating) path.
    /// SECURITY: only place untrusted-ish data meets a shell. argv is single-quoted (layer 1);
    /// for remote, the joined remote command is single-quoted again (layer 2).
    func wrap(_ argv: [String]) -> String {
        switch self {
        case .local:
            return shq(argv)
        case .ssh(let t):
            precondition(t.isValid)
            // ssh forwards $TERM but not $TERM_PROGRAM*; CC's OSC 9;4 emission gates on
            // those env vars. Prefixing the remote argv
            // sets the *creation* env for zmx-new sessions; existing sessions keep their
            // frozen env until restarted. Version is the minimum CC checks for, not the
            // bundle version — this is a capability flag.
            let env = ["env", "TERM_PROGRAM=ghostty", "TERM_PROGRAM_VERSION=1.2.0"]
            return shq(["ssh", "-t", "--", t.connectionString]) + " " + shq(shq(env + argv))
        }
    }

    /// argv (no shell) for non-interactive control commands (`list`, `kill`) via `Process`.
    func controlArgv(_ argv: [String]) -> [String] {
        switch self {
        case .local:
            return argv
        case .ssh(let t):
            precondition(t.isValid)
            return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", t.connectionString, shq(argv)]
        }
    }
}
#endif
