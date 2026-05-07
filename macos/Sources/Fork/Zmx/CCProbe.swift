#if os(macOS)
import Foundation

/// Maps zmx sessions → the CC session running inside them, by joining `zmx list`'s
/// per-session pid against the `~/.claude/sessions/<pid>.json` registry via a
/// process-tree descendant walk.
enum CCProbe {
    struct Info: Hashable {
        var name: String?
        var status: String?
        var cwd: String?
        var updatedAt: Date?
        var waitingFor: String?

        // `updatedAt` excluded so `mergeCC`'s `!=` guard isn't defeated by heartbeat-only
        // ticks (which would publish every 3s). The age column reads
        // `SessionRegistry.ccUpdatedAt` (non-@Published, refreshed every tick) inside its
        // TimelineView closure instead — `ccLive[].updatedAt` is stale by design.
        static func == (l: Self, r: Self) -> Bool {
            l.name == r.name && l.status == r.status && l.cwd == r.cwd && l.waitingFor == r.waitingFor
        }
        func hash(into h: inout Hasher) { h.combine(name); h.combine(status); h.combine(cwd); h.combine(waitingFor) }
    }

    /// Result keyed by `SessionRef.key` (the @-prefixed form), so a managed `acr` and an
    /// external `acr` on the same host don't collide. `nil` on probe failure (caller keeps
    /// last-known-good); `[:]` on success-with-no-matches. Same `sh -c` path for local and
    /// remote — `controlArgv` is the identity for `.local`, ssh-wrap for `.ssh`.
    static func probe(host: ForkHost, entries: [ZmxAdapter.ListEntry]) async -> [String: Info]? {
        // Can't distinguish "host has no zmx sessions" from "list() swallowed an ssh
        // failure" (ZmxAdapter.list returns `.init()` on both), so treat empty as
        // failure-keep-last-known rather than success-wipe.
        guard !entries.isEmpty else { return nil }
        let argv = host.transport.controlArgv(["/bin/sh", "-c", probeScript])
        guard let out = try? await ZmxAdapter.run(argv: argv,
                                                  timeout: host.transport.isLocal ? 3 : 5)
        else { return nil }
        // RS (0x1e) cannot appear unescaped in JSON text (RFC 8259 §7), so it's a safe
        // separator even though `name`/`cwd`/`detail` are arbitrary strings.
        let parts = out.split(separator: "\u{1e}", omittingEmptySubsequences: false)
        guard let ps = parts.first.map(String.init) else { return nil }
        if ps.isEmpty {
            ForkBootstrap.logger.warning("CCProbe: empty ps output for host \(host.id)")
            return nil
        }
        let cc: [Int32: Info] = parts.dropFirst().reduce(into: [:]) { dict, blob in
            if let r = decode(blob) { dict[r.pid] = r.info }
        }
        return match(entries: entries, hostID: host.id, children: parsePS(ps), cc: cc)
    }

    // MARK: - Pure core (unit-tested)

    /// BFS each entry's pid through `children`; first descendant present in `cc` wins
    /// (shallowest = the foreground process). pid ≤ 0 skipped — launchd's ppid is 0, so a
    /// 0-seed would walk the whole table. Visited-set + depth cap guard malformed input.
    static func match(entries: [ZmxAdapter.ListEntry], hostID: ForkHost.ID,
                      children: [Int32: [Int32]], cc: [Int32: Info]) -> [String: Info] {
        guard !cc.isEmpty else { return [:] }
        var out: [String: Info] = [:]
        for e in entries {
            guard let root = e.pid, root > 0 else { continue }
            var queue = [root], seen: Set<Int32> = [root], depth = 0
            while !queue.isEmpty, depth < 32 {
                if let hit = queue.lazy.compactMap({ cc[$0] }).first {
                    let key = SessionRef(hostID: hostID, name: e.name, external: e.external).key
                    out[key] = hit
                    break
                }
                queue = queue.flatMap { children[$0] ?? [] }.filter { seen.insert($0).inserted }
                depth += 1
            }
        }
        return out
    }

    static func parsePS(_ s: String) -> [Int32: [Int32]] {
        var children: [Int32: [Int32]] = [:]
        for line in s.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 2, let pid = Int32(cols[0]), let ppid = Int32(cols[1]) else { continue }
            children[ppid, default: []].append(pid)
        }
        return children
    }

    // MARK: - Registry IO

    private struct Record: Decodable {
        var pid: Int32
        var kind: String?
        var name: String?
        var status: String?
        var cwd: String?
        var updatedAt: Double?
        var waitingFor: String?
    }

    private static func clean(_ s: String?, _ max: Int) -> String? {
        s.map { stripControl($0, max: max) }
    }

    private static func decode(_ blob: some StringProtocol) -> (pid: Int32, info: Info)? {
        let s = blob.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty,
              let r = try? JSONDecoder().decode(Record.self, from: Data(s.utf8)),
              r.kind == nil || r.kind == "interactive"
        else { return nil }
        return (r.pid, .init(name: clean(r.name, 128),
                             status: clean(r.status, 256), cwd: clean(r.cwd, 1024),
                             updatedAt: r.updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                             waitingFor: clean(r.waitingFor, 256)))
    }

    /// Constant — no interpolation. `controlArgv` handles ssh quoting (CLAUDE.md §Security).
    /// `\036` (RS) delimits ps-output from JSON blobs; `;` not `&&` so a torn read on one
    /// file doesn't swallow the next separator. `$HOME` survives Dock launch (launchd sets it);
    /// a zshrc-only `CLAUDE_CONFIG_DIR` is still invisible — see CLAUDE.md §Known limitations.
    private static let probeScript = """
        ps -A -o pid=,ppid= 2>/dev/null
        printf '\\036'
        d=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions
        for f in "$d"/[0-9]*.json; do
          [ -f "$f" ] || continue
          cat "$f"; printf '\\036'
        done
        """
}
#endif
