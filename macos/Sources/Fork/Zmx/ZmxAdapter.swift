#if os(macOS)
import Foundation

/// Only place in the fork that knows zmx's CLI shape or builds shell strings (SPEC §4).
/// PR2: `.local` only. ssh/et wrapping lands in PR3.
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

    /// `zmx list --short` → unprefixed names for this host. Runs out-of-band via `Process`
    /// (argv, no shell). PR2: local only; remote returns [].
    static func list(host: ForkHost, timeout: TimeInterval = 5) async -> [String] {
        guard host.transport.isLocal else { return [] }
        guard let out = try? await run(argv: ["zmx", "list", "--short"], timeout: timeout) else { return [] }
        let prefix = "\(host.id)-"
        return out.split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    static func kill(host: ForkHost, ref: SessionRef) async throws {
        guard host.transport.isLocal else { return }
        _ = try await run(argv: ["zmx", "kill", wireName(ref)], timeout: 5)
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
    /// Produce the single shell string libghostty's `command` field needs.
    /// SECURITY: only place untrusted-ish data meets a shell. Layer 1 quotes argv;
    /// remote layer 2 (ssh/et) lands in PR3.
    func wrap(_ argv: [String]) -> String {
        switch self {
        case .local:
            return shq(argv)
        case .ssh(let t), .et(let t):
            precondition(t.isValid, "SSHTarget must be validated before wrap")
            let bin = { if case .et = self { return "et" } else { return "ssh" } }()
            return shq([bin, "-t", "--", t.connectionString]) + " " + shq(shq(argv))
        }
    }
}
#endif
