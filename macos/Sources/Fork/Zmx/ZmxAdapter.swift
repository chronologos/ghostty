#if os(macOS)
import Foundation

/// Only place in the fork that knows zmx's CLI shape or builds shell strings (SPEC §4).
enum ZmxAdapter {
    /// On-the-wire name. `SessionRef.name` is always stored unprefixed.
    static func wireName(_ ref: SessionRef) -> String { "\(ref.hostID)-\(ref.name)" }

    /// SurfaceConfiguration whose pty child is `zmx attach <wireName> [cmd...]`, wrapped by transport.
    static func surfaceConfig(
        host: ForkHost,
        ref: SessionRef,
        initialCmd: [String]? = nil,
        cwd: String? = nil
    ) -> Ghostty.SurfaceConfiguration {
        var c = Ghostty.SurfaceConfiguration()
        if host.transport.isLocal { c.workingDirectory = cwd }
        let argv = ["zmx", "attach", wireName(ref)] + (initialCmd ?? [])
        c.command = host.transport.wrap(argv)
        return c
    }

    /// `zmx list --short` → unprefixed names for this host. Runs out-of-band via `Process`.
    static func list(host: ForkHost, timeout: TimeInterval = 5) async -> [String] {
        let argv = host.transport.controlArgv(["zmx", "list", "--short"])
        guard let out = try? await run(argv: argv, timeout: timeout) else { return [] }
        let prefix = "\(host.id)-"
        return out.split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    static func kill(host: ForkHost, ref: SessionRef) async throws {
        let argv = host.transport.controlArgv(["zmx", "kill", wireName(ref)])
        _ = try await run(argv: argv, timeout: 5)
    }

    // MARK: -

    private static func run(argv: [String], timeout: TimeInterval) async throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return String(decoding: data, as: UTF8.self)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                p.terminate()
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
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
