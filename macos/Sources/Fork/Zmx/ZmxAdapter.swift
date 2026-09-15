#if os(macOS)
import Foundation

/// Only place in the fork that knows zmx's CLI shape or builds shell strings (SPEC §4).
enum ZmxAdapter {
    /// Absolute local path to `zmx`. Spotlight/Dock launches inherit launchd's minimal
    /// PATH, and Ghostty runs commands via `bash --noprofile --norc`, so bare `zmx` fails.
    /// Resolved once: env override → current PATH (usually already enriched by
    /// `ForkBootstrap.prepareEnvironment`'s cached login-PATH export) → common install dirs →
    /// bare `zmx`. (A login-shell probe used to sit last: it blocked main for up to 2s inside
    /// this swift_once on exactly the launches where it was least likely to answer in time.
    /// The bare-name fallback no longer self-heals within the launch — the env is frozen at
    /// `ghostty_init`, so the background PATH refresh only feeds the next launch's cache.)
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
        ForkBootstrap.logger.warning("zmx not resolved; falling back to PATH lookup")
        return "zmx"
    }()

    /// Remote hosts use bare `zmx` (resolved by the remote shell's PATH).
    private static func zmx(on host: ForkHost) -> String {
        host.transport.isLocal ? localZmx : "zmx"
    }

    /// zmx's default tracked-env list (cfg.zig `tracked_envs` — `ZMX_TRACK_ENV` *replaces*
    /// it, so the defaults are repeated) plus the two variables CC's progress reporting
    /// gates on.
    static let trackedEnv = "DISPLAY,SSH_AUTH_SOCK,SSH_AGENT_PID,SSH_CONNECTION,WINDOWID,XAUTHORITY,"
        + "KITTY_LISTEN_ON,KITTY_PID,KITTY_WINDOW_ID,TERM_PROGRAM,TERM_PROGRAM_VERSION"

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
        // zmx starts a *new* session in the attaching client's cwd (and ignores it when the
        // session already exists), so "start where I am" is just "run the client there":
        // locally libghostty chdirs the child; remotely `wrap` prepends a `cd`.
        if host.transport.isLocal { c.workingDirectory = cwd }
        let argv = [zmx(on: host), "attach", wireName(ref)] + (initialCmd ?? [])
        c.command = host.transport.wrap(argv, cwd: host.transport.isLocal ? nil : cwd)
        return c
    }

    struct ListEntry: Hashable {
        var name: String
        var clients: Int
        var created: Date
        var external: Bool
        var pid: Int32?
        /// Decoded `ghostty_name` label — the display alias, source of truth for
        /// `paneLabels`. nil = no label (or an unlabeled/old daemon). See `AliasCodec`.
        var alias: String? = nil
        /// The daemon's view of the session's working directory, decoded to a plain
        /// absolute path (`decodeCwd`). zmx ≥0.8 tracks it live from OSC 7; older daemons
        /// report the static creation dir. This is the *only* cwd source for a plain shell
        /// on an ssh host — Ghostty drops OSC 7 whose host isn't the Mac, so `surface.pwd`
        /// is always nil there. Remote-controlled text: display / `{cwd}` only.
        var cwd: String? = nil
        /// Host part of the OSC 7 URI, when present. Differs from the session's own host
        /// when the shell has ssh'd somewhere else (OSC 7 crosses ssh).
        var cwdHost: String? = nil
        /// The command the session was created with (`zmx attach name cmd…` / `zmx run`).
        var cmd: String? = nil
        /// `zmx run` task bookkeeping: when the last task finished, and how.
        var ended: Date? = nil
        var exitCode: Int? = nil
    }

    /// A session whose socket exists but whose daemon didn't answer `zmx list`'s 1s probe
    /// (`err=Timeout|Unexpected|InfoSizeMismatch`, `status=unreachable`). zmx is explicit
    /// that such a daemon may just be busy — the session, and any agent in it, is very
    /// likely still alive. Dropping these rows made a wedged session indistinguishable from
    /// a dead one: kill verification could never see the one case it exists for, the Hosts
    /// sheet showed a failed Kill as success, and the CC probe read it as "agent exited".
    struct Unresponsive: Hashable {
        var name: String
        var external: Bool
        var err: String
    }

    struct ListResult {
        var managed: [ListEntry] = []
        var external: [ListEntry] = []
        var unresponsive: [Unresponsive] = []

        /// `SessionRef.key`s of everything the host still *has* — answered or not.
        func presentKeys(hostID: ForkHost.ID) -> Set<String> {
            Set((managed + external).map {
                SessionRef(hostID: hostID, name: $0.name, external: $0.external).key
            } + unresponsive.map {
                SessionRef(hostID: hostID, name: $0.name, external: $0.external).key
            })
        }
    }

    /// Why a `zmx list` produced no answer — so the UI can stop blaming ssh for a slow zmx.
    enum ListFailure: Error, Equatable {
        /// Wall-clock timeout. With ssh up this is usually zmx itself: `list` probes every
        /// socket serially at 1s each, so a handful of wedged daemons exceeds the budget.
        case timeout
        /// ssh exited 255 — the transport, not zmx.
        case transport(String)
        /// `zmx` isn't on the (non-interactive) PATH over there.
        case zmxMissing
        case other(String)

        var summary: String {
            switch self {
            case .timeout: "zmx list timed out (slow link, or sessions not responding)"
            case .transport(let m): m.isEmpty ? "ssh couldn't connect" : "ssh: \(m)"
            case .zmxMissing: "zmx not found on PATH there"
            case .other(let m): m.isEmpty ? "zmx list failed" : m
            }
        }
    }

    /// `zmx list` partitioned into fork-managed and external. `nil` means the *query* failed
    /// (host unreachable, ssh refused, zmx missing) — callers must not render that as an
    /// empty-but-healthy host; an empty `ListResult` means the query worked and found nothing.
    static func list(host: ForkHost, timeout: TimeInterval = 5) async -> ListResult? {
        try? await listResult(host: host, timeout: timeout).get()
    }

    /// `list()` with the failure reason kept. Also refuses to read an *unrecognized* row
    /// format as "no sessions": a remote zmx old enough to print different field names
    /// parses to zero rows, which is exactly the empty-but-healthy state the contract above
    /// says a broken query must never produce.
    static func listResult(host: ForkHost, timeout: TimeInterval = 5) async -> Result<ListResult, ListFailure> {
        let argv = host.transport.controlArgv([zmx(on: host), "list"])
        do {
            let out = try await run(argv: argv, timeout: timeout)
            let r = partition(out, hostID: host.id)
            let rows = out.split(separator: "\n").filter { $0.contains("\t") && $0.contains("=") }
            if !rows.isEmpty, r.managed.isEmpty, r.external.isEmpty, r.unresponsive.isEmpty,
               !rows.allSatisfy({ $0.contains("status=cleaning up") }) {
                return .failure(.other("zmx there prints an unrecognized list format (version mismatch?)"))
            }
            return .success(r)
        } catch let e as CommandError {
            return .failure(classify(e, remote: !host.transport.isLocal))
        } catch {
            return .failure(.timeout)
        }
    }

    /// Pure, for tests. ssh reserves 255 for its own failures; 127 is the shell's (or
    /// `env`'s) "command not found".
    static func classify(_ e: CommandError, remote: Bool) -> ListFailure {
        if remote, e.status == 255 { return .transport(e.stderr) }
        if e.status == 127 { return .zmxMissing }
        return .other(e.stderr)
    }

    /// Pure half of `list()` (separated for tests): full k=v lines → fork-managed
    /// (prefix-stripped) / external. Dead-socket lines (`err=…`) are dropped, as are names
    /// `zmx` itself would parse as options (leading `-`) — those can never become a safe
    /// `SessionRef`.
    ///
    /// **Row forgery.** zmx enforces the label charset only in its CLI: a `LabelSet` sent
    /// straight to the daemon socket stores value bytes verbatim, and a value containing
    /// `\n` prints as an extra, fully attacker-composed *row* — one that can claim any
    /// session name (bypassing first-key-wins, which only orders fields within a row).
    /// A name seen twice in one listing is therefore never trusted twice: the first row
    /// wins and later rows for the same session key are dropped. (The root fix belongs in
    /// zmx: daemon-side label validation + separator escaping in `list`.)
    static func partition(_ output: String, hostID: ForkHost.ID) -> ListResult {
        let prefix = "\(hostID)-"
        var r = ListResult()
        var seen = Set<String>()
        /// Shared by both row kinds: prefix-strip → safety rule → first-row-wins.
        func admit(_ wire: String) -> (name: String, external: Bool)? {
            var name = wire, external = true
            if name.hasPrefix(prefix), isValidIdent(String(name.dropFirst(prefix.count))) {
                name = String(name.dropFirst(prefix.count)); external = false
            }
            guard isSafeExternalName(name),
                  seen.insert(external ? "@\(name)" : name).inserted else { return nil }
            return (name, external)
        }
        for line in output.split(separator: "\n") {
            guard let row = parseRow(line: line) else { continue }
            guard case .entry(var e) = row else {
                if case .unresponsive(let wire, let err) = row, let a = admit(wire) {
                    r.unresponsive.append(.init(name: a.name, external: a.external, err: err))
                }
                continue
            }
            // Only a name the fork could have created itself (managed charset) is trusted
            // as managed: the wire prefix alone is forgeable by anyone on the host, and a
            // forged name with shell-hostile characters must not become a non-external
            // `SessionRef` (downstream code assumes managed ⇒ `isValid` — derived-name
            // seeding, `Persistence.scrub`'s rule choice). Forged-prefix names that fail
            // the charset stay external under their full wire name.
            // The safety rule is checked AFTER the prefix strip so `h1--foo` can't smuggle a
            // dash-leading managed name through; it applies to both partitions. The seen-key
            // is the one `SessionRef.key` would use (`@` for external) — first row wins.
            guard let a = admit(e.name) else { continue }
            e.name = a.name; e.external = a.external
            if e.external { r.external.append(e) } else { r.managed.append(e) }
        }
        return r
    }

    /// One `zmx list` row (zmx `util.zig writeSessionLine`), today:
    /// `[→ |  ]name=…\tpid=…\tclients=…\tcreated=…[\tcwd=…][\tcmd=…][\tended=…[\texit_code=…]][\tlabels…]`.
    /// `created` is unix seconds (zmx's own struct comment says ns; the code stores
    /// seconds). Session labels (`zmx set`) are appended last as extra `k=v` fields. Two
    /// precedence rules fall out of that order:
    /// - **Built-ins are first-occurrence-wins.** zmx reserves only a few label keys, so a
    ///   label named `clients` or `err` is settable — but it prints *after* the real field
    ///   and can't shadow it into corrupting a row.
    /// - **`ghostty_name` is last-occurrence-wins.** `cwd=` and `cmd=` print *before* the
    ///   labels and are free text (an OSC 7 path; the command line a hover command built
    ///   from `{cwd}`), so a tab inside one of them followed by `ghostty_name=…` would
    ///   otherwise beat the real label.
    /// A row for a daemon that didn't answer (`name=…\terr=…\tstatus=…`) carries no
    /// `pid`/`clients`/`created`; it is recognized by that absence, not by `err=` alone —
    /// a separate `err=` check would let a *label* named `err` hide a live session.
    /// `status=cleaning up` means zmx just deleted a definitively dead socket: gone.
    enum Row: Equatable {
        case entry(ListEntry)
        case unresponsive(wire: String, err: String)
    }

    static func parseRow(line: Substring) -> Row? {
        var kv: [Substring: Substring] = [:]
        for tok in line.drop(while: { $0 == " " || $0 == "→" }).split(separator: "\t") {
            guard let eq = tok.firstIndex(of: "=") else { continue }
            let k = tok[..<eq], v = tok[tok.index(after: eq)...]
            if k == AliasCodec.keySub || kv[k] == nil { kv[k] = v }
        }
        guard let name = kv["name"] else { return nil }
        guard let clients = kv["clients"].flatMap({ Int($0) }),
              let created = kv["created"].flatMap({ TimeInterval($0) })
        else {
            guard kv["pid"] == nil, let err = kv["err"], kv["status"] != "cleaning up" else { return nil }
            return .unresponsive(wire: String(name), err: stripControl(String(err), max: 32))
        }
        let cwd = kv["cwd"].flatMap(decodeCwd)
        return .entry(.init(
            name: String(name), clients: clients,
            created: Date(timeIntervalSince1970: created), external: true,
            pid: kv["pid"].flatMap { Int32($0) },
            alias: AliasCodec.alias(from: kv[AliasCodec.keySub]),
            cwd: cwd?.path, cwdHost: cwd?.host,
            cmd: kv["cmd"].map { stripControl(String($0), max: 256) }.flatMap { $0.isEmpty ? nil : $0 },
            ended: kv["ended"].flatMap { TimeInterval($0) }.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
            exitCode: kv["exit_code"].flatMap { Int($0) }))
    }

    /// The answered-row half of `parseRow` (what most callers and tests want).
    static func parse(line: Substring) -> ListEntry? {
        if case .entry(let e) = parseRow(line: line) { return e }
        return nil
    }

    /// `cwd=` value → plain absolute path (+ the URI's host). zmx keeps the OSC 7 *URI*:
    /// `file://host/percent-encoded` for a fresh session, or whatever the shell emits
    /// verbatim — Ghostty's own shell integration sends `kitty-shell-cwd://host/raw-path`,
    /// which by that scheme's definition is NOT percent-encoded. A pre-0.8 daemon behind a
    /// new client prints a bare path. zmx truncates the field at 256 bytes, so a value that
    /// long may be cut mid-path (or mid-`%XX`): discard it rather than show a wrong place.
    static func decodeCwd(_ raw: Substring) -> (host: String?, path: String)? {
        guard !raw.isEmpty, raw.utf8.count < 256 else { return nil }
        func clean(_ p: String) -> String? {
            let c = stripControl(p, max: 1024)
            return c.hasPrefix("/") ? c : nil
        }
        if raw.hasPrefix("/") { return clean(String(raw)).map { (nil, $0) } }
        guard let sep = raw.range(of: "://") else { return nil }
        let scheme = raw[..<sep.lowerBound], rest = raw[sep.upperBound...]
        guard scheme == "file" || scheme == "kitty-shell-cwd",
              let slash = rest.firstIndex(of: "/") else { return nil }
        let host = stripControl(String(rest[..<slash]), max: 255)
        let rawPath = String(rest[slash...])
        guard let path = clean(scheme == "file" ? (rawPath.removingPercentEncoding ?? "") : rawPath)
        else { return nil }
        return (host.isEmpty ? nil : host, path)
    }

    /// Shell command for a detached-placeholder surface: says what state the session is in,
    /// waits for ⏎, then runs `zmx attach` for the same ref via the host's transport,
    /// re-prompting in place each time the attach exits. `alias` leads when there is one
    /// (it's the name the sidebar shows; the id demotes to the dim line). `ccName` is the
    /// cached `tab.ccNames[ref.key]` — printed dim so a cold-restored pane whose session is
    /// gone still says what it used to be.
    ///
    /// **Why it probes.** Every way a zmx client ends looks the same from here — the shell
    /// `exit`ed, the ssh link dropped, the client detached, the session was killed from
    /// another Mac: `zmx attach` returns `.detach` and exits 0 on all of them. So "press ⏎
    /// to reattach" used to be shown even when there was nothing to reattach *to*, and ⏎
    /// then silently created a brand-new session under the old name. Before each prompt the
    /// script asks the host (`zmx list` over the non-interactive control transport) and
    /// prints one of three lines: still running / ended (⏎ starts fresh) / can't reach.
    /// The full `list` rather than `--short`: a daemon that didn't answer is printed as an
    /// `err=` row there and omitted from `--short`, and "busy" must not read as "ended".
    static func detachedScript(host: ForkHost, ref: SessionRef, alias: String? = nil,
                               ccName: String? = nil) -> String {
        // `attach` is already a fully shq'd command line (each token single-quoted),
        // so it's interpolated *unquoted* into the loop body — wrapping it again would make
        // it one word. shq is total (POSIX `'` → `'\''`); see TransportTests.wrapSshInjection.
        let attach = host.transport.wrap([zmx(on: host), "attach", wireName(ref)])
        let probe = shq(host.transport.controlArgv([zmx(on: host), "list"]))
        // `name=<wire>\t` — every row kind (answered or `err=`) starts its fields with it.
        let needle = shq("name=\(wireName(ref))\t")
        // External `ref.name` is raw remote `zmx list` output (validation is bypassed for
        // externals — Persistence.swift scrub) and reaches the local pty via `printf %s`.
        // `alias`/`ccName` round-trip through hand-editable fork.json, so they get the same
        // control-stripping before they are printed to the local terminal.
        let id = stripControl(ref.name, max: 128)
        let shown = alias.map { stripControl($0, max: 96) }.flatMap { $0.isEmpty || $0 == id ? nil : $0 }
        let msg = "session \(shown ?? id)"
        let idLine = shown == nil ? "" : "; printf '\\033[2m  id: %s\\033[0m\\n' \(shq(id))"
        let was = ccName.map { "; " + wasLine($0) } ?? ""
        let where_ = shq(stripControl(host.label, max: 64))
        // Loop in place rather than `exec`: when the attach dies (ssh dropped over the next
        // sleep, or ⏎ pressed before the network was back) its error text stays on screen
        // and the same pty re-prompts — no surface churn, nothing flashes and vanishes.
        // `while read` ends on ^D/EOF, so a dead stdin can't spin; sh exiting just lands
        // back on `makeDetachedPlaceholder`. The attach may die mid-TUI, so before
        // re-prompting: cooked termios, primary screen, kitty-kbd stack cleared (over-pop
        // = reset), cursor on, mouse/bracketed-paste off, SGR reset, and OSC 9;4;0 so the
        // sidebar rail settles now instead of on upstream's 15s auto-nil. Ghostty has no
        // DECSTR, and RIS would wipe the very error line this loop exists to keep. (zmx
        // itself writes RIS on every exit *after* it connected — that's a clean detach, where
        // there's no error text to lose; `tidy` is for the ssh-drop / killed-client exits
        // where zmx's own restore never ran.)
        let tidy = "\\033[?1049l\\033[<99u\\033[?25h\\033[?1000l\\033[?1002l\\033[?1003l\\033[?1006l\\033[?2004l\\033[0m\\033]9;4;0\\007"
        // `/bin/sh`, not `sh`: this is the *local* pty's own command (libghostty runs it as
        // `bash -c "exec -l …"`), and the placeholder is the pane of last resort — it must
        // come up even when the pane's PATH is broken, which is exactly when it's needed.
        return shq(["/bin/sh", "-c", """
            state() { \
            if out=$(\(probe) 2>/dev/null); then \
            if printf '%s\\n' "$out" | grep -qF -- \(needle); \
            then printf '\\033[2m  detached — still running on %s · ⏎ reattaches, ⌘⇧W closes\\033[0m\\n' \(where_); \
            else printf '\\033[2m  session ended — ⏎ starts a fresh shell under this name, ⌘⇧W closes\\033[0m\\n'; fi; \
            else printf "\\033[2m  can't reach %s — ⏎ retries, ⌘⇧W closes\\033[0m\\n" \(where_); fi; }; \
            printf '%s\\n' \(shq(msg))\(idLine)\(was); state; \
            while read _; do \(attach); rc=$?; stty sane 2>/dev/null; \
            printf '\(tidy)\\n\\033[2m  exited (%s)\\033[0m\\n' "$rc"; state; done
            """])
    }

    /// The dim "was: <cc name>" line, shared by the placeholder and the restore banner.
    private static func wasLine(_ ccName: String) -> String {
        "printf '\\033[2m  was: %s\\033[0m\\n' \(shq(stripControl(ccName, max: 96)))"
    }

    /// `initialCmd` for a cold-restored leaf with a cached CC name. `zmx attach` only runs
    /// the trailing argv when *creating* the session, so an existing session ignores this and
    /// a fresh one shows the banner above its first prompt. (zmx ≥0.8 replays the window
    /// title on re-attach, but only onto a *live* daemon — a session that died took its
    /// title and labels with it, so the cached CC name is the only surviving hint.)
    /// `-l`: zmx's own sessions are login shells; a restored one shouldn't come up with a
    /// bare PATH just because it went through this banner.
    static func restoreCmd(ccName: String) -> [String] {
        ["sh", "-c", "\(wasLine(ccName)); printf '\\n'; exec ${SHELL:-/bin/sh} -l"]
    }

    /// The `k=v` token for `zmx set`. The value is always inside zmx's label charset
    /// (`AliasCodec.encode`), so it's inert under both `controlArgv` branches; empty =
    /// remove the label. Pure, for tests.
    static func aliasKV(_ alias: String?) -> String {
        "\(AliasCodec.key)=\(alias.map(AliasCodec.encode) ?? "")"
    }

    /// What a `zmx set` told us. Since zmx 0.7.0 the CLI waits (1s) for the daemon's Ack and
    /// exits non-zero otherwise, so the three cases are distinguishable:
    enum SetResult: Equatable {
        /// Exit 0 with nothing on stdout: the daemon Ack'd — the write landed, and this
        /// daemon is *proven* label-capable.
        case acked
        /// Permanent for this session: "does not support labels (daemon too old?)", or a
        /// pre-label *client* that fell through to printing its help text (exit 0 + stdout).
        /// Retrying is pointless — each attempt costs an ssh handshake plus zmx's 1s wait.
        case unsupported
        /// Anything else — host blip, ssh `MaxStartups`, busy daemon, session not created
        /// yet. Worth a bounded retry.
        case transient
    }

    /// Write the display alias onto the session as the `ghostty_name` label (nil clears
    /// it). Callers don't await success — they fire this and feed the result back into
    /// `AliasSync` (`noteLanded` / `noteFailed`); the local `paneLabels` cache keeps
    /// carrying the name either way.
    @discardableResult
    static func setAlias(host: ForkHost, ref: SessionRef, to alias: String?) async -> SetResult {
        let kv = aliasKV(alias)
        let argv = host.transport.controlArgv([zmx(on: host), "set", wireName(ref), kv])
        do {
            let out = try await run(argv: argv, timeout: 5)
            return classifySet(stdout: out, error: nil)
        } catch {
            ForkBootstrap.logger.debug(
                "zmx set \(kv, privacy: .public) on \(host.label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return classifySet(stdout: "", error: error)
        }
    }

    /// Pure half of `setAlias`, for tests.
    static func classifySet(stdout: String, error: Error?) -> SetResult {
        if let e = error as? CommandError {
            return e.stderr.contains("does not support labels") ? .unsupported : .transient
        }
        if error != nil { return .transient }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .acked : .unsupported
    }

    /// How a `zmx kill` came out — exit status alone can't say.
    enum KillOutcome: Equatable {
        /// zmx printed `killed session <name>`: it blocked until the daemon hung up, so
        /// the session is gone and the name is free.
        case killed
        /// Nothing to kill — the shell already exited, or another client got there first.
        /// (Exit 1 `SessionNotFound` since 0.8.0; exit 0 + "does not exist" before.) The
        /// goal state holds, so this is not an error.
        case alreadyGone
        /// Exit 0 without the confirmation line. zmx's kill dispatch still falls through
        /// to exit 0 when a listed session's kill failed (it prints "failed to kill…" on
        /// stderr, which a success path doesn't reliably capture). Callers verify with a
        /// follow-up `list`.
        case unconfirmed
    }

    /// Throws `CommandError` for a real failure and `CancellationError` for a timeout —
    /// and a *timed-out* kill means "sent, not confirmed": by the time zmx blocks waiting
    /// for the hang-up, the Kill message is already in the daemon's socket, so a busy
    /// daemon may still act on it later.
    @discardableResult
    static func kill(host: ForkHost, ref: SessionRef) async throws -> KillOutcome {
        let argv = host.transport.controlArgv([zmx(on: host), "kill", wireName(ref)])
        do {
            let out = try await run(argv: argv, timeout: 5)
            return out.contains("killed session") ? .killed : .unconfirmed
        } catch let e as CommandError where e.stderr.contains("SessionNotFound")
            || e.stderr.contains("does not exist") {
            return .alreadyGone
        }
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
    /// child's exit, that wait never returned and — because `pollLoop` awaits every host
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
    ///
    /// `cwd` (remote only; local panes get `workingDirectory`): start the client — and so a
    /// *newly created* session — in that directory. It is remote-controlled text (OSC 7 as
    /// reported by that same host's zmx daemon), so it must be absolute and travels as one
    /// `shq`'d positional argument to a fixed `sh -c` script, never interpolated into it.
    /// A directory that has since vanished just leaves the shell in its default place.
    func wrap(_ argv: [String], cwd: String? = nil) -> String {
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
            // `ZMX_NO_DETACH_KEY`: see `ForkBootstrap.scrubZmxEnvironment` (this is its
            // remote half — the variable is read by the attach *client*).
            // `ZMX_TRACK_ENV`: zmx ≥0.8 records these from each attaching client and hands
            // the leader's values to `zmx print-env` — so a shell in a *pre-existing*
            // session (frozen env, no TERM_PROGRAM, a dead SSH_AUTH_SOCK) can pick them up
            // with `eval "$(zmx print-env -s .)"` in its precmd hook. It only records; it
            // never changes a running process's environment, so the prefix above stays.
            let env = ["env", "TERM_PROGRAM=ghostty", "TERM_PROGRAM_VERSION=1.2.0",
                       "ZMX_NO_DETACH_KEY=1", "ZMX_TRACK_ENV=\(ZmxAdapter.trackedEnv)"]
            var remote = env + argv
            if let cwd, cwd.hasPrefix("/") {
                remote = ["sh", "-c", #"cd "$1" 2>/dev/null; shift; exec "$@""#, "_", cwd] + remote
            }
            return shq(["ssh", "-t"] + Self.paneSSHOptions + ["--", t.connectionString])
                + " " + shq(shq(remote))
        }
    }

    /// Liveness for the *interactive* ssh. Without these a link that died silently (laptop
    /// sleep, NAT expiry) leaves the pane frozen for minutes while everything else reads
    /// healthy — control commands open fresh connections and succeed, and the remote side
    /// hasn't noticed either, so `clients=1` persists. With them a dead link surfaces as
    /// the placeholder within ~45s, and a reattach to a black-holed host fails in 15s
    /// instead of sitting out the OS TCP timeout. Command-line `-o` beats `ssh_config`.
    static let paneSSHOptions = ["-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                                 "-o", "ConnectTimeout=15"]

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
