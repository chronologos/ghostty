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
        /// `'active'|'idle'|'blocked'` — classifier output, watch-gated (see `probeScript`).
        var tempo: String?
        /// Human-readable "what it wants from you" when `tempo == "blocked"`.
        var needs: String?
        /// Live one-line activity summary the agent maintains for itself: current tool +
        /// description while working, a "what I accomplished" line when done, the open
        /// question when blocked. Newer CC builds only — always optional.
        var detail: String?
        /// Per-session control UDS path on the pane's host. Used by `rename`.
        var sock: String?

        var isBlocked: Bool { tempo == "blocked" }
        /// The triage answer for a *blocked* pane — what CC wants from you. `needs` first:
        /// it's the classifier's precise ask, and older CC builds write it without `detail`.
        var attention: String? { needs ?? waitingFor ?? detail }

        // `updatedAt` excluded so `mergeCC`'s `!=` guard isn't defeated by heartbeat-only
        // ticks (which would publish every 3s). The hover-peek age line reads
        // `SessionRegistry.ccUpdatedAt` (non-@Published, refreshed every tick) inside the
        // pane row's 60s clock instead — `ccLive[].updatedAt` is stale by design.
        // `detail` IS included: it changes per tool call, so an actively-working session now
        // publishes roughly every poll tick — that's the cost of a live activity subtitle,
        // and it's bounded by the poll cadence, not by how fast the agent works.
        static func == (l: Self, r: Self) -> Bool {
            l.name == r.name && l.status == r.status && l.cwd == r.cwd && l.waitingFor == r.waitingFor
                && l.tempo == r.tempo && l.needs == r.needs && l.detail == r.detail && l.sock == r.sock
        }
        func hash(into h: inout Hasher) {
            h.combine(name); h.combine(status); h.combine(cwd); h.combine(waitingFor)
            h.combine(tempo); h.combine(needs); h.combine(detail); h.combine(sock)
        }
    }

    /// Result keyed by `SessionRef.key` (the @-prefixed form), so a managed `acr` and an
    /// external `acr` on the same host don't collide. `nil` on probe failure (caller keeps
    /// last-known-good); `[:]` on success-with-no-matches. Same `sh -c` path for local and
    /// remote — `controlArgv` is the identity for `.local`, ssh-wrap for `.ssh`.
    static func probe(host: ForkHost, entries: [ZmxAdapter.ListEntry]) async -> [String: Info]? {
        // Transport failure is already short-circuited by the caller (`ccPollLoop` skips the
        // probe when `list()` returns nil); zero entries just means there's nothing to match
        // against — keep last-known rather than wiping.
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
        var tempo: String?
        var needs: String?
        var detail: String?
        var messagingSocketPath: String?
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
                             waitingFor: clean(r.waitingFor, 256),
                             tempo: clean(r.tempo, 32), needs: clean(r.needs, 256),
                             detail: clean(r.detail, 512),
                             sock: clean(r.messagingSocketPath, 1024)))
    }

    private struct RenameMsg: Encodable { let type = "control", action = "rename", name: String }

    /// `printf <json> | nc -w 1 -U -- <sock>` script. Both dynamic parts are `shq`'d (sock
    /// is remote-decoded, untrusted); `--` blocks getopt option injection from a leading-`-`
    /// sock. `-w 1` (1s idle timeout) for portable EOF-exit — macOS /usr/bin/nc has no `-N`
    /// (parses it as `--apple-tcp-adp-wtimo`, eats `U` as its arg, exits 1); Linux nc may
    /// otherwise hold the connection. Needs `nc -U` on the target host (BusyBox/GNU-
    /// traditional lack it).
    static func renameScript(sock: String, to name: String) -> String? {
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        guard let data = try? enc.encode(RenameMsg(name: name)),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "printf '%s\\n' \(shq(json)) | nc -w 1 -U -- \(shq(sock))"
    }

    static func rename(host: ForkHost, sock: String, to name: String) async {
        guard let script = renameScript(sock: sock, to: name) else {
            ForkBootstrap.logger.warning("CC rename: couldn't build control message")
            return
        }
        // `; true` — `nc -w 1`'s idle-timeout exit code is variant-dependent, and a non-zero
        // there is the *normal* delivery path; only transport-level failures (ssh refused,
        // sh missing) should reach the log line below.
        let argv = host.transport.controlArgv(["sh", "-c", script + "; true"])
        do { _ = try await ZmxAdapter.run(argv: argv, timeout: 5) } catch {
            // Sidebar label and CC name silently diverging is confusing enough to deserve
            // at least a log line (no `nc -U` on the host, dead socket, unreachable).
            ForkBootstrap.logger.warning(
                "CC rename failed on \(host.label, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Constant — no interpolation. `controlArgv` handles ssh quoting (CLAUDE.md §Security).
    /// `\036` (RS) delimits ps-output from JSON blobs; `;` not `&&` so a torn read on one
    /// file doesn't swallow the next separator. `$HOME` survives Dock launch (launchd sets it);
    /// a zshrc-only `CLAUDE_CONFIG_DIR` is still invisible — see CLAUDE.md §Known limitations.
    /// The `: >` heartbeat touch flips the agent's "being watched" gate so it writes the
    /// `tempo`/`needs` classifier fields; without it those keys are absent (everything else
    /// lands regardless).
    private static let probeScript = """
        ps -A -o pid=,ppid= 2>/dev/null
        printf '\\036'
        d=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions
        : > "$d/.fleetview-heartbeat" 2>/dev/null
        for f in "$d"/[0-9]*.json; do
          [ -f "$f" ] || continue
          cat "$f"; printf '\\036'
        done
        true
        """
    // The trailing `true`: `ZmxAdapter.run` now treats a non-zero exit as failure, but this
    // script is *designed* to tolerate per-file failures (torn reads, vanished pid files) —
    // its robustness is in the parser, so only transport-level failure should look like one.
}
#endif
