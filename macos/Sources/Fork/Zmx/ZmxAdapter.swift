#if os(macOS)
import Foundation

/// Only place in the fork that knows zmx's CLI shape or builds shell strings (SPEC §4).
enum ZmxAdapter {
    /// Absolute local path to `zmx`. Spotlight/Dock launches inherit launchd's minimal
    /// PATH, and Ghostty runs commands via `bash --noprofile --norc`, so bare `zmx` fails.
    /// Resolved once: env override → current PATH → common install dirs → login-shell probe.
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
        // Last resort: ask the user's login shell. Bounded — a hung .zshrc must not
        // wedge the static-let initializer (and with it, every caller).
        let p = Process(), pipe = Pipe(), done = DispatchSemaphore(value: 0)
        p.executableURL = URL(fileURLWithPath: env["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-lic", "command -v zmx"]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in done.signal() }
        if (try? p.run()) != nil {
            if done.wait(timeout: .now() + 2) == .timedOut { p.terminate() }
            let out = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if fm.isExecutableFile(atPath: out) { return out }
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

    /// SurfaceConfiguration whose pty child is `zmx attach <wireName> [cmd...]`, wrapped by transport.
    static func surfaceConfig(
        host: ForkHost,
        ref: SessionRef,
        initialCmd: [String]? = nil,
        cwd: String? = nil
    ) -> Ghostty.SurfaceConfiguration {
        var c = Ghostty.SurfaceConfiguration()
        if host.transport.isLocal { c.workingDirectory = cwd }
        if ForkBootstrap.noZmx { return c }
        let argv = [zmx(on: host), "attach", wireName(ref)] + (initialCmd ?? [])
        c.command = host.transport.wrap(argv)
        return c
    }

    struct ListEntry: Hashable {
        var name: String
        var clients: Int
        var created: Date
        var external: Bool
    }

    struct ListResult {
        var managed: [ListEntry] = []
        var external: [ListEntry] = []
    }

    /// `zmx list` (full k=v form) partitioned into fork-managed (prefix-stripped) and external.
    /// Dead-socket lines (`err=…`) are dropped.
    static func list(host: ForkHost, timeout: TimeInterval = 5) async -> ListResult {
        let argv = host.transport.controlArgv([zmx(on: host), "list"])
        guard let out = try? await run(argv: argv, timeout: timeout) else { return .init() }
        let prefix = "\(host.id)-"
        var r = ListResult()
        for line in out.split(separator: "\n") {
            guard var e = parse(line: line) else { continue }
            if e.name.hasPrefix(prefix) {
                e.name = String(e.name.dropFirst(prefix.count))
                e.external = false
                r.managed.append(e)
            } else {
                r.external.append(e)
            }
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
                     created: Date(timeIntervalSince1970: created), external: true)
    }

    /// Shell command for a detached-placeholder surface: shows a prompt, waits for ⏎,
    /// then execs `zmx attach` for the same ref via the host's transport.
    static func detachedScript(host: ForkHost, ref: SessionRef) -> String {
        // `attach` is already a fully shq'd command line (each token single-quoted),
        // so it's interpolated *unquoted* after `exec` — wrapping it again would make
        // it one word. shq is total (POSIX `'` → `'\''`); see TransportTests.wrapSshInjection.
        let attach = host.transport.wrap([zmx(on: host), "attach", wireName(ref)])
        let msg = "session \(ref.name) — press ⏎ to reattach, ⌘⇧W to close"
        return shq(["sh", "-c", "printf '%s\\n' \(shq(msg)); read _; exec \(attach)"])
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

    private static func run(argv: [String], timeout: TimeInterval) async throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        // `onCancel` + inner `defer` ensure the process is killed on parent-task cancellation
        // *and* on timeout — otherwise the synchronous reader child pins a cooperative thread.
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    // Blocking read on GCD global, not the cooperative pool — under
                    // N-way fanout (⌘⇧K), pool-blocking reads would starve the
                    // timeout sleeper below and defeat the bound it's meant to enforce.
                    await withCheckedContinuation { cont in
                        DispatchQueue.global().async {
                            let data = pipe.fileHandleForReading.readDataToEndOfFile()
                            p.waitUntilExit()
                            cont.resume(returning: String(decoding: data, as: UTF8.self))
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw CancellationError()
                }
                defer { if p.isRunning { p.terminate() } }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } onCancel: {
            p.terminate()
        }
    }
}

extension ForkHost.Transport {
    /// Shell string for libghostty's `command` field — interactive (tty-allocating) path.
    /// SECURITY: only place untrusted-ish data meets a shell. argv is single-quoted (layer 1);
    /// for remote, the joined remote command is single-quoted again (layer 2).
    func wrap(_ argv: [String]) -> String {
        let remote = shq(argv)
        switch self {
        case .local:
            return remote
        case .ssh(let t):
            precondition(t.isValid)
            return shq(["ssh", "-t", "--", t.connectionString]) + " " + shq(remote)
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
