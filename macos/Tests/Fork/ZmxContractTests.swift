#if os(macOS)
import Foundation
import Testing
@testable import Ghostty

/// The fork ↔ zmx boundary, pinned against what zmx prints and does *today* (0.8.x).
/// Three layers: row/field parsing against fixtures shaped like `writeSessionLine`'s own
/// output; the shell the fork generates, *executed* rather than string-matched; and a small
/// contract suite that drives the real `zmx` binary in an isolated `ZMX_DIR`, so a zmx
/// upgrade that moves the ground shows up at rebase time instead of as a quiet misbehaviour.
struct ZmxListRowTests {
    /// Field order as zmx emits it: name, pid, clients, created, [cwd], [cmd],
    /// [ended, [exit_code]], then labels.
    static let golden = "  name=h1-dev\tpid=123\tclients=2\tcreated=1700000000"
        + "\tcwd=file://mac.local/Users/me/work/a%20b\tcmd=zig build\tended=1700000100\texit_code=3"
        + "\tenv=prod\tghostty_name=my_20api"

    @Test func goldenRowParsesEveryField() throws {
        let e = try #require(ZmxAdapter.parse(line: Self.golden[...]))
        #expect(e.name == "h1-dev" && e.pid == 123 && e.clients == 2)
        #expect(e.created == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(e.cwd == "/Users/me/work/a b" && e.cwdHost == "mac.local")
        #expect(e.cmd == "zig build")
        #expect(e.ended == Date(timeIntervalSince1970: 1_700_000_100) && e.exitCode == 3)
        #expect(e.alias == "my api")
        // `ended=0` is zmx's "no task finished yet", not the epoch.
        #expect(ZmxAdapter.parse(line: "name=a\tpid=1\tclients=0\tcreated=1\tended=0")?.ended == nil)
    }

    @Test func cwdDecoding() {
        // file:// is percent-encoded; kitty-shell-cwd:// (what Ghostty's own shell
        // integration emits) is by definition the raw path — a literal `%41` stays `%41`.
        #expect(ZmxAdapter.decodeCwd("file://h/tmp/%41b")?.path == "/tmp/Ab")
        #expect(ZmxAdapter.decodeCwd("kitty-shell-cwd://h/tmp/%41b")?.path == "/tmp/%41b")
        #expect(ZmxAdapter.decodeCwd("kitty-shell-cwd://h/Users/me")?.host == "h")
        // A pre-0.8 daemon behind a new client prints a bare path; no host.
        #expect(ZmxAdapter.decodeCwd("/Users/me")?.path == "/Users/me")
        #expect(ZmxAdapter.decodeCwd("/Users/me")?.host == nil)
        // zmx truncates the field at 256 bytes — a value that long may be cut mid-path.
        let long = "file://h/" + String(repeating: "x", count: 247)
        #expect(long.utf8.count == 256 && ZmxAdapter.decodeCwd(long[...]) == nil)
        #expect(ZmxAdapter.decodeCwd(long.dropLast()) != nil)
        // Not a path we can use.
        #expect(ZmxAdapter.decodeCwd("") == nil)
        #expect(ZmxAdapter.decodeCwd("relative/dir") == nil)
        #expect(ZmxAdapter.decodeCwd("https://h/x") == nil)
        #expect(ZmxAdapter.decodeCwd("file://hostonly") == nil)
        // Remote-controlled text headed for the sidebar: no terminal escapes.
        #expect(ZmxAdapter.decodeCwd("file://h/tmp/a%1B%5B2Jb")?.path == "/tmp/a[2Jb")
    }

    /// Every error kind zmx prints for a daemon that didn't answer. All mean "may just be
    /// busy" — still there — and must survive parsing as such.
    @Test(arguments: ["Timeout", "Unexpected", "InfoSizeMismatch", "ConnectionRefused"])
    func unansweredDaemonIsARowNotAHole(err: String) {
        let row = ZmxAdapter.parseRow(line: "  name=h1-x\terr=\(err)\tstatus=unreachable")
        #expect(row == .unresponsive(wire: "h1-x", err: err))
        #expect(ZmxAdapter.parse(line: "  name=h1-x\terr=\(err)\tstatus=unreachable") == nil)
    }

    @Test func aLabelNamedErrCannotHideALiveSession() {
        // zmx reserves few label keys, so `zmx set s err=x status=unreachable` is legal. The
        // unresponsive shape is recognized by the *absence* of pid/clients/created.
        let row = ZmxAdapter.parseRow(line: "name=dev\tpid=1\tclients=2\tcreated=1\terr=fake\tstatus=unreachable")
        guard case .entry(let e) = row else { Issue.record("expected an answered row"); return }
        #expect(e.name == "dev" && e.clients == 2)
    }

    @Test func aliasIsLastOccurrenceBuiltinsAreFirst() {
        // `cmd=` prints before the labels and is free text — a hover command built from
        // `{cwd}` can carry a tab. Its tail must not pose as the label…
        let shadow = "name=dev\tpid=1\tclients=0\tcreated=1\tcmd=lazygit -p /x\tghostty_name=Evil\ty\tenv=a\tghostty_name=Real"
        #expect(ZmxAdapter.parse(line: shadow[...])?.alias == "Real")
        // …while built-ins stay first-wins, so a *label* can't rewrite them.
        let evil = "name=dev\tpid=1\tclients=2\tcreated=1700000000\tclients=99\tname=x"
        #expect(ZmxAdapter.parse(line: evil[...])?.clients == 2)
        #expect(ZmxAdapter.parse(line: evil[...])?.name == "dev")
    }

    @Test func partitionKeepsUnresponsiveSessionsUnderTheSameNameRules() {
        let out = """
            name=h1-acr\tpid=1\tclients=1\tcreated=1700000000
            name=h1-busy\terr=Timeout\tstatus=unreachable
            name=theirs\terr=Unexpected\tstatus=unreachable
            name=h1-acr\terr=Timeout\tstatus=unreachable
            name=-rf\terr=Timeout\tstatus=unreachable
            name=h1-gone\terr=ConnectionRefused\tstatus=cleaning up
            """
        let r = ZmxAdapter.partition(out, hostID: "h1")
        #expect(r.managed.map(\.name) == ["acr"])
        // Prefix stripped → managed; foreign → external; a second row for a name already
        // seen is dropped; option-looking names never become refs; "cleaning up" is gone.
        #expect(r.unresponsive == [.init(name: "busy", external: false, err: "Timeout"),
                                   .init(name: "theirs", external: true, err: "Unexpected")])
        #expect(r.presentKeys(hostID: "h1") == ["acr", "busy", "@theirs"])
    }

    /// zmx gives a trailing `*` meaning in `kill`/`wait`/`tail` (prefix match) but not in
    /// `attach`, so a session literally named `dev*` exists, lists, and turns the fork's
    /// Kill button into "kill everything starting with dev". It must never become a ref.
    @Test func starSuffixedNamesNeverBecomeRefs() {
        #expect(!isSafeExternalName("dev*") && !isSafeExternalName("*"))
        #expect(isSafeExternalName("de*v") && isSafeExternalName("dev"))
        let out = """
            name=*\tpid=1\tclients=0\tcreated=1
            name=dev*\tpid=2\tclients=0\tcreated=1
            name=h1-x*\terr=Timeout\tstatus=unreachable
            name=dev\tpid=3\tclients=0\tcreated=1
            """
        let r = ZmxAdapter.partition(out, hostID: "h1")
        #expect(r.external.map(\.name) == ["dev"])
        #expect(r.managed.isEmpty && r.unresponsive.isEmpty)
    }

    @Test func listFailuresAreClassified() {
        let ssh = ZmxAdapter.CommandError(status: 255, stderr: "connect to host h port 22: refused")
        #expect(ZmxAdapter.classify(ssh, remote: true) == .transport("connect to host h port 22: refused"))
        // 255 from a *local* zmx is just zmx.
        #expect(ZmxAdapter.classify(ssh, remote: false) == .other("connect to host h port 22: refused"))
        #expect(ZmxAdapter.classify(.init(status: 127, stderr: "zmx: not found"), remote: true) == .zmxMissing)
        #expect(ZmxAdapter.ListFailure.timeout.summary.contains("timed out"))
    }

    @Test func zmxSetResultsAreTriState() {
        #expect(ZmxAdapter.classifySet(stdout: "", error: nil) == .acked)
        #expect(ZmxAdapter.classifySet(stdout: "\n", error: nil) == .acked)
        // A pre-label *client* falls through to printing its help text and exits 0.
        #expect(ZmxAdapter.classifySet(stdout: "zmx - session persistence…", error: nil) == .unsupported)
        let old = ZmxAdapter.CommandError(status: 1, stderr: "error: session \"x\" does not support labels (daemon too old?)")
        #expect(ZmxAdapter.classifySet(stdout: "", error: old) == .unsupported)
        let gone = ZmxAdapter.CommandError(status: 1, stderr: "error: session \"x\" not found or unresponsive")
        #expect(ZmxAdapter.classifySet(stdout: "", error: gone) == .transient)
        #expect(ZmxAdapter.classifySet(stdout: "", error: CancellationError()) == .transient)
    }

    @Test func whereLineFoldsHomeAndHidesTheForksOwnWrappers() {
        var e = ZmxAdapter.ListEntry(name: "x", clients: 0, created: .distantPast, external: false, pid: 1)
        #expect(SessionNameLabel.whereLine(e) == nil)
        e.cwd = "/Users/me/work/api"
        #expect(SessionNameLabel.whereLine(e) == "~/work/api")
        e.cwd = "/home/deploy/app"; e.cmd = "zig build"
        #expect(SessionNameLabel.whereLine(e) == "~/app  ·  $ zig build")
        e.cwd = "/srv/www"; e.cmd = "sh -c 'printf …; exec zsh -l'"
        #expect(SessionNameLabel.whereLine(e) == "/srv/www")
    }
}

/// The placeholder script, *run* — against a stub `ssh` on PATH — so the three states, the
/// loop, and every quoting level are exercised as the shell sees them.
struct DetachedScriptExecutionTests {
    /// Runs `script` (a full `'/bin/sh' '-c' '…'` command line) with `stdin`, a stub `ssh` that
    /// answers the list probe from `list` (nil = probe fails) and "attaches" by exiting 7.
    private func run(_ script: String, list: String?, stdin: String) throws -> String {
        let dir = URL(fileURLWithPath: "/tmp/zf-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = """
            #!/bin/sh
            case "$*" in
              *BatchMode=yes*) [ -f "\(dir.path)/list" ] || exit 255; cat "\(dir.path)/list"; exit 0 ;;
              *) echo "ATTACHED"; exit 7 ;;
            esac
            """
        try stub.write(to: dir.appendingPathComponent("ssh"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: dir.appendingPathComponent("ssh").path)
        if let list { try list.write(to: dir.appendingPathComponent("list"), atomically: true, encoding: .utf8) }
        let p = Process(), out = Pipe(), inp = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = ["PATH": "\(dir.path):/usr/bin:/bin"]
        p.standardOutput = out; p.standardError = out; p.standardInput = inp
        try p.run()
        inp.fileHandleForWriting.write(Data(stdin.utf8))
        try inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private let host = ForkHost(id: "abcd1234", label: "box", transport: .ssh(.init(user: "me", host: "box")))
    private var ref: SessionRef { SessionRef(hostID: host.id, name: "s") }

    @Test func saysStillRunningWhenTheSessionIsListed() throws {
        let script = ZmxAdapter.detachedScript(host: host, ref: ref, alias: "My Pane", ccName: "fix-auth")
        let out = try run(script, list: "  name=abcd1234-s\tpid=1\tclients=0\tcreated=1\n", stdin: "")
        #expect(out.contains("session My Pane"))
        #expect(out.contains("id: s") && out.contains("was: fix-auth"))
        #expect(out.contains("detached — still running on box"))
        #expect(!out.contains("ATTACHED"))          // no ⏎ was pressed
    }

    @Test func aDaemonThatDidNotAnswerIsStillRunningNotEnded() throws {
        let script = ZmxAdapter.detachedScript(host: host, ref: ref)
        let out = try run(script, list: "name=abcd1234-s\terr=Timeout\tstatus=unreachable\n", stdin: "")
        #expect(out.contains("still running") && !out.contains("session ended"))
    }

    @Test func saysEndedWhenTheHostAnswersWithoutIt() throws {
        let script = ZmxAdapter.detachedScript(host: host, ref: ref)
        // A *longer* name sharing the prefix must not count as this session.
        let out = try run(script, list: "  name=abcd1234-s2\tpid=1\tclients=0\tcreated=1\n", stdin: "")
        #expect(out.contains("session ended — ⏎ starts a fresh shell"))
        // No alias → the id leads and there's no second id line.
        #expect(out.contains("session s") && !out.contains("id: "))
    }

    @Test func saysCantReachWhenTheProbeFails() throws {
        let out = try run(ZmxAdapter.detachedScript(host: host, ref: ref), list: nil, stdin: "")
        #expect(out.contains("can't reach box"))
    }

    @Test func enterAttachesThenReprobesInPlace() throws {
        let script = ZmxAdapter.detachedScript(host: host, ref: ref)
        let out = try run(script, list: "  name=abcd1234-s\tpid=1\tclients=0\tcreated=1\n", stdin: "\n")
        #expect(out.contains("ATTACHED") && out.contains("exited (7)"))
        // State is re-derived after the attach exits — twice in total for one ⏎.
        #expect(out.components(separatedBy: "still running").count == 3)
    }

    @Test func hostileNamesStayInertThroughEveryQuotingLevel() throws {
        let evil = SessionRef(hostID: host.id, name: "a';touch /tmp/zf-pwned;'$(id) `id`", external: true)
        let script = ZmxAdapter.detachedScript(host: host, ref: evil, alias: "x\u{1B}[2J'\"$(id)", ccName: "';id;'")
        let out = try run(script, list: "", stdin: "\n")
        #expect(!FileManager.default.fileExists(atPath: "/tmp/zf-pwned"))
        #expect(out.contains("session x[2J'\"$(id)"))   // printed literally, escape stripped
        #expect(out.contains("ATTACHED"))
        #expect(!out.contains("uid="))
    }
}

/// `Transport.wrap(_:cwd:)`, run through a stub `ssh` that does what sshd does (hand the
/// last argument to a shell) and a stub `zmx` that reports where it was started.
struct RemoteCwdExecutionTests {
    @Test func theNewSessionStartsInThatDirectoryAndNothingElseHappens() throws {
        let root = URL(fileURLWithPath: "/tmp/zf-\(UUID().uuidString.prefix(8))")
        let hostile = "a b'; touch \(root.path)/pwned; '$(id)"
        let dir = root.appendingPathComponent(hostile)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func stub(_ name: String, _ body: String) throws {
            let u = root.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: u, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        }
        try stub("ssh", #"for a; do last=$a; done; exec /bin/sh -c "$last""#)
        try stub("zmx", #"printf 'PWD=%s\nARGS=%s\nDETACH=%s\n' "$(pwd -P)" "$*" "$ZMX_NO_DETACH_KEY""#)
        func run(_ cmd: String) throws -> String {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            p.environment = ["PATH": "\(root.path):/usr/bin:/bin"]
            p.currentDirectoryURL = URL(fileURLWithPath: "/")
            p.standardOutput = out; p.standardError = out
            try p.run()
            let d = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: d, as: UTF8.self)
        }
        let t = ForkHost.Transport.ssh(.init(user: nil, host: "h"))
        let real = (dir.path as NSString).resolvingSymlinksInPath
        let out = try run(t.wrap(["zmx", "attach", "h-x", "vim", "a b"], cwd: dir.path))
        #expect(out.contains("PWD=\(real)\n") || out.contains("PWD=/private\(real)\n"))
        #expect(out.contains("ARGS=attach h-x vim a b\n"))
        #expect(out.contains("DETACH=1"))                       // env prefix reached the client
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("pwned").path))
        // A directory that no longer exists: the client still starts, just not there.
        let gone = try run(t.wrap(["zmx", "attach", "h-x"], cwd: "/nonexistent/zf"))
        #expect(gone.contains("PWD=/\n") && gone.contains("ARGS=attach h-x"))
    }
}

struct AliasSyncAckTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let created = Date(timeIntervalSince1970: 500)

    private func observe(_ s: inout AliasSync, live: String?, cached: String?, seeded: Bool = false,
                         pid: Int32? = 7, dt: TimeInterval = 0, ttl: TimeInterval = 40,
                         fetched: TimeInterval? = nil, proven: String? = nil,
                         created c: Date? = nil) -> AliasSync.Action {
        s.observe(created: c ?? created, pid: pid, live: live, cached: cached, seeded: seeded,
                  id: "acr", budget: true, managed: true, now: t0.addingTimeInterval(dt), ttl: ttl,
                  fetchedAt: fetched.map(t0.addingTimeInterval), proven: proven)
    }

    @Test func anAckReleasesTheMaskOnTheFirstListFetchedAfterIt() {
        var s = AliasSync()
        _ = observe(&s, live: "Old", cached: "Old")
        s.noteSent(sent: "New", wire: "New", at: t0)
        s.noteLanded(at: t0, now: t0.addingTimeInterval(2))
        // A list that was already in flight when the Ack came back still shows the old value.
        #expect(observe(&s, live: "Old", cached: "New", dt: 3, fetched: 1) == .none)
        // One fetched after the Ack is the truth — even if someone else has since changed it.
        #expect(observe(&s, live: "Elsewhere", cached: "New", dt: 6, fetched: 5) == .setCache("Elsewhere"))
    }

    @Test func anAckProvesCapabilityAndClearsTheFailureCount() {
        var s = AliasSync()
        _ = observe(&s, live: nil, cached: nil, seeded: true)      // → push id
        s.noteSent(sent: nil, wire: "acr", at: t0)
        #expect(!s.capable)
        s.noteLanded(at: t0, now: t0)
        #expect(s.capable && s.failures == 0 && s.inFlight == nil)
        // A stale stamp credits nothing.
        var o = AliasSync()
        o.noteSent(sent: "A", wire: "A", at: t0)
        o.noteLanded(at: t0.addingTimeInterval(-1), now: t0)
        #expect(!o.capable && o.inFlight != nil)
    }

    /// Three unrelated ssh blips over a session's life must not switch retries off for
    /// good — the counter is "since the last write that worked", not lifetime.
    @Test func failuresResetWhenAWriteLands() {
        var s = AliasSync()
        _ = observe(&s, live: "Old", cached: "Old")
        var live = "Old"
        for i in 0..<3 {                                // fail → retry → land, three times
            let at = t0.addingTimeInterval(Double(i * 10)), name = "N\(i)"
            s.noteSent(sent: name, wire: name, at: at)
            s.noteFailed(at: at)
            #expect(s.failures == 1)
            #expect(observe(&s, live: live, cached: name, dt: Double(i * 10 + 1)) == .push(name))
            let again = at.addingTimeInterval(1)
            s.noteSent(sent: name, wire: name, at: again)
            s.noteLanded(at: again, now: again)
            #expect(s.failures == 0)
            live = name                                 // the daemon now carries it
            #expect(observe(&s, live: live, cached: name, dt: Double(i * 10 + 3),
                            fetched: Double(i * 10 + 2)) == .none)
        }
        // The fourth failure still gets its retry (it wouldn't with a lifetime counter).
        let at = t0.addingTimeInterval(100)
        s.noteSent(sent: "Last", wire: "Last", at: at)
        s.noteFailed(at: at)
        #expect(observe(&s, live: "N2", cached: "Last", dt: 101) == .push("Last"))
    }

    @Test func anEchoAlsoResetsTheFailureCount() {
        var s = AliasSync()
        _ = observe(&s, live: "Old", cached: "Old")
        s.noteSent(sent: "A", wire: "A", at: t0); s.noteFailed(at: t0)
        #expect(s.failures == 1)
        _ = observe(&s, live: "Old", cached: "A", dt: 1)            // retry goes out
        s.noteSent(sent: "A", wire: "A", at: t0.addingTimeInterval(1))
        _ = observe(&s, live: "A", cached: "A", dt: 2)              // echoed
        #expect(s.failures == 0)
    }

    @Test func aDaemonThatCannotDoLabelsIsNotRetried() {
        var s = AliasSync()
        _ = observe(&s, live: nil, cached: "Name")                  // migrate
        s.noteSent(sent: "Name", wire: "Name", at: t0)
        s.noteFailed(at: t0, permanent: true)
        #expect(s.failures == AliasSync.maxFailures && s.retry == nil)
        #expect(observe(&s, live: nil, cached: "Name", dt: 3) == .none)   // cache stands, no spawn
    }

    /// A seed's (or clear's) expected echo is nil, so the very next label-less row drops
    /// its mask. A failure arriving *after* that used to find no stamp to match and was
    /// discarded — the seed never landed and was never retried.
    @Test func aFailureArrivingAfterTheTrivialEchoStillRetries() {
        var s = AliasSync()
        #expect(observe(&s, live: nil, cached: nil, seeded: true) == .push("acr"))
        s.noteSent(sent: nil, wire: "acr", at: t0)
        #expect(observe(&s, live: nil, cached: nil, dt: 3) == .none)      // nil == nil → unmasked
        #expect(s.pending == nil)
        s.noteFailed(at: t0)                                              // `run` times out at 5s
        #expect(observe(&s, live: nil, cached: nil, dt: 6) == .push("acr"))
    }

    @Test func aRecreateWithinTheSameSecondIsANewIncarnation() {
        // zmx's `created` is whole seconds and it explicitly supports kill-then-immediate-
        // recreate. Same second, different pid → labels died with the old daemon: migrate,
        // don't read the missing label as a clear.
        var s = AliasSync()
        _ = observe(&s, live: "Deploy", cached: "Deploy", pid: 100)
        #expect(observe(&s, live: nil, cached: "Deploy", pid: 200) == .push("Deploy"))
        // Same pid → same daemon → this is (the first strike of) a clear.
        var t = AliasSync()
        _ = observe(&t, live: "Deploy", cached: "Deploy", pid: 100)
        #expect(observe(&t, live: nil, cached: "Deploy", pid: 100) == .none)
        #expect(t.absentStrikes == 1)
    }

    @Test func anOlderFailedIntentDoesNotStompANewerRenameFromElsewhere() {
        var s = AliasSync()
        _ = observe(&s, live: "Old", cached: "Old")
        s.noteSent(sent: "Mine", wire: "Mine", at: t0)
        s.noteFailed(at: t0)
        // Meanwhile another Mac renamed it. The daemon moved since our write was issued, so
        // the queued retry is dropped and the daemon's value wins.
        #expect(observe(&s, live: "Theirs", cached: "Mine", dt: 3) == .setCache("Theirs"))
        #expect(s.retry == nil)
    }

    /// `capable` used to live only in memory, so every launch "migrated" the cached name back
    /// over a clear made elsewhere while the app was quit. The persisted incarnation makes
    /// a first sighting capable — iff it is the *same* incarnation.
    @Test func aPersistedProofSurvivesRelaunch() {
        var s = AliasSync()
        let proof = "\(Int(created.timeIntervalSince1970))/7"
        #expect(observe(&s, live: nil, cached: "Foo", proven: proof) == .none)       // strike 1
        #expect(observe(&s, live: nil, cached: "Foo", proven: proof) == .setCache(nil))
        #expect(s.incarnation == proof)
        // A proof for some earlier incarnation says nothing about this daemon: migrate.
        var n = AliasSync()
        #expect(observe(&n, live: nil, cached: "Foo", proven: "499/7") == .push("Foo"))
    }

    @Test func sanitizeIsIdempotent() {
        // Cap-then-trim: the 64th character being a space used to leave a trailing space the
        // daemon's echo (re-sanitized) didn't have, so cache ≠ echo forever.
        let name = String(repeating: "a", count: 63) + " b"
        let once = AliasCodec.sanitize(name)
        #expect(once == String(repeating: "a", count: 63))
        #expect(once.flatMap(AliasCodec.sanitize) == once)
        let echoed = AliasCodec.alias(from: AliasCodec.encode(once!)[...])
        #expect(echoed == once)
    }
}

@MainActor
struct ZmxRegistryTests {
    private func reset() -> SessionRegistry {
        let r = SessionRegistry.shared
        r.resetForTesting()
        r.aliasPusher = { _, _, _, _ in }
        return r
    }
    private func makeTab(_ r: SessionRegistry, on host: ForkHost.ID = "local", name: String) -> TabModel.ID {
        let t = r.newTab(on: host, title: name)
        r.setPersistedTree(.empty.appending(leaf: SessionRef(hostID: host, name: name)), for: t.id)
        return t.id
    }
    private func entry(_ name: String, alias: String? = nil, clients: Int = 1, pid: Int32? = 7,
                       created: Date = Date(timeIntervalSince1970: 500)) -> ZmxAdapter.ListEntry {
        .init(name: name, clients: clients, created: created, external: false, pid: pid, alias: alias)
    }
    private func tab(_ r: SessionRegistry, _ id: TabModel.ID) -> TabModel? { r.tabs.first { $0.id == id } }

    @Test func aTabThatAttachesTheSessionLaterIsHealed() {
        // The driver used to read the cache from `tabs.first` and fan out only on an action:
        // with tab A already equal to the daemon the reducer (rightly) says `.none`, and a
        // second tab attached after that never got the label.
        let r = reset()
        let a = makeTab(r, name: "acr")
        r.syncAliases(hostID: "local", list: .init(managed: [entry("acr", alias: "Alpha")]))
        let b = makeTab(r, name: "acr")
        #expect(tab(r, b)?.paneLabels["acr"] == nil)
        r.syncAliases(hostID: "local", list: .init(managed: [entry("acr", alias: "Alpha")]))
        #expect(tab(r, a)?.paneLabels["acr"] == "Alpha" && tab(r, b)?.paneLabels["acr"] == "Alpha")
    }

    @Test func aListFetchedBeforeThePaneExistedIsNotAboutIt() {
        // Kill → same-name create while a `zmx list` is in flight: the stale result must
        // not hand the new pane the dead session's alias (and burn its seed).
        let r = reset()
        let t = makeTab(r, name: "acr")
        let ref = SessionRef(hostID: "local", name: "acr")
        r.bind(surface: UUID(), to: ref)
        let stale = ZmxAdapter.ListResult(managed: [entry("acr", alias: "Dead")])
        r.syncAliases(hostID: "local", list: stale, fetchedAt: Date().addingTimeInterval(-10))
        #expect(tab(r, t)?.paneLabels["acr"] == nil && r.aliasSync[ref] == nil)
        r.syncAliases(hostID: "local", list: stale, fetchedAt: Date().addingTimeInterval(10))
        #expect(tab(r, t)?.paneLabels["acr"] == "Dead")
    }

    @Test func capabilityProofIsPersistedAndHonouredAfterRelaunch() {
        let r = reset()
        let t = makeTab(r, name: "acr")
        let ref = SessionRef(hostID: "local", name: "acr")
        r.syncAliases(hostID: "local", list: .init(managed: [entry("acr", alias: "Foo")]))
        #expect(tab(r, t)?.aliasProven["acr"] == "500/7")
        // "Relaunch": the in-memory reducer is gone, fork.json (the tab) survives.
        r.dropPane(ref)
        var pushes = 0
        r.aliasPusher = { _, _, _, _ in pushes += 1 }
        let cleared = ZmxAdapter.ListResult(managed: [entry("acr", alias: nil)])
        r.syncAliases(hostID: "local", list: cleared)
        r.syncAliases(hostID: "local", list: cleared)
        // The clear made while we were away propagates — it is NOT "migrated" back up.
        #expect(pushes == 0 && tab(r, t)?.paneLabels["acr"] == nil)
        // The proof rides along when the pane moves tabs, and is pruned with the pane.
        let dst = r.newTab(on: "local", title: "dst")
        r.setPaneLabel(tab: t, name: "acr", to: "X")
        #expect(r.movePanePersisted(from: t, ref: ref, to: dst.id))
        #expect(tab(r, dst.id)?.aliasProven["acr"] == "500/7" && tab(r, t)?.aliasProven.isEmpty == true)
    }

    @Test func anAckFeedsBackIntoTheReducer() {
        let r = reset()
        var stamps: [Date] = []
        r.aliasPusher = { _, _, _, at in stamps.append(at) }
        let t = makeTab(r, name: "acr")
        let ref = SessionRef(hostID: "local", name: "acr")
        r.syncAliases(hostID: "local", list: .init(managed: [entry("acr", alias: nil)]))
        r.renamePane(tab: t, name: "acr", to: "New")
        r.noteAliasWriteResult(ref, at: stamps[0], result: .acked)
        #expect(r.aliasSync[ref]?.capable == true)
        #expect(tab(r, t)?.aliasProven["acr"] == "500/7")
        // "daemon too old" is permanent; a plain failure queues a retry.
        r.renamePane(tab: t, name: "acr", to: "Again")
        r.noteAliasWriteResult(ref, at: stamps[1], result: .unsupported)
        #expect(r.aliasSync[ref]?.failures == AliasSync.maxFailures && r.aliasSync[ref]?.retry == nil)
    }

    @Test func removingAHostDropsItsAliasState() {
        // Host ids are a hash of user@host, so a re-added host would inherit a queued retry.
        let r = reset()
        let h = ForkHost(id: "abcd1234", label: "box", transport: .ssh(.init(user: nil, host: "box")))
        r.addHost(h)
        _ = makeTab(r, on: h.id, name: "acr")
        let ref = SessionRef(hostID: h.id, name: "acr")
        r.seedAlias(ref)
        r.syncAliases(hostID: h.id, list: .init(managed: [entry("acr", alias: "A")]))
        r.noteList(hostID: h.id, list: .init(managed: [entry("acr")]))
        #expect(r.aliasSync[ref] != nil && r.liveness[ref] != nil && r.zmxCwd[h.id] != nil)
        r.removeHost(h.id)
        #expect(r.aliasSync[ref] == nil && r.liveness[ref] == nil && r.zmxCwd[h.id] == nil)
    }

    @Test func livenessComesFromTheListAndEndedNeedsTwoMisses() {
        let r = reset()
        _ = makeTab(r, name: "up"); _ = makeTab(r, name: "busy"); _ = makeTab(r, name: "gone")
        let up = SessionRef(hostID: "local", name: "up"), busy = SessionRef(hostID: "local", name: "busy")
        let gone = SessionRef(hostID: "local", name: "gone")
        let list = ZmxAdapter.ListResult(
            managed: [entry("up", clients: 0), entry("gone")],
            unresponsive: [.init(name: "busy", external: false, err: "Timeout")])
        r.noteList(hostID: "local", list: list)
        #expect(r.liveness[up] == .listed(clients: 0))
        #expect(r.liveness[busy] == .unresponsive("Timeout"))
        #expect(r.liveness[gone] == .listed(clients: 1))
        // One miss is a session that hasn't finished starting (or a racing list)…
        let without = ZmxAdapter.ListResult(managed: [entry("up")])
        r.noteList(hostID: "local", list: without)
        #expect(r.liveness[gone] == .listed(clients: 1))
        // …two is an answer. And an unanswered daemon is never "ended".
        r.noteList(hostID: "local", list: without)
        #expect(r.liveness[gone] == .ended && r.liveness[busy] == .ended)
        // Coming back resets the count.
        r.noteList(hostID: "local", list: list)
        #expect(r.liveness[gone] == .listed(clients: 1) && r.liveness[busy] == .unresponsive("Timeout"))
        // A list that predates the pane can't say it ended.
        _ = makeTab(r, name: "fresh")
        let fresh = SessionRef(hostID: "local", name: "fresh")
        r.bind(surface: UUID(), to: fresh)
        for _ in 0..<3 { r.noteList(hostID: "local", list: without, fetchedAt: Date().addingTimeInterval(-5)) }
        #expect(r.liveness[fresh] == nil)
        // The daemon's cwd is kept for the peek / ⌘D / hover commands.
        var e = entry("up"); e.cwd = "/srv/app"
        r.noteList(hostID: "local", list: .init(managed: [e]))
        #expect(r.zmxCwd["local"]?["up"]?.cwd == "/srv/app")
    }

    @Test func anUnansweredDaemonIsNotAnExitedAgent() {
        // The session missed `zmx list`'s probe, so it wasn't among the entries the CC probe
        // matched. That's "couldn't look": keep the rail, the status text and `blocked`.
        let r = reset()
        _ = makeTab(r, name: "acr")
        let ref = SessionRef(hostID: "local", name: "acr")
        let info = CCProbe.Info(name: "fix", status: "busy", cwd: "/x", detail: "editing")
        r.applyProbeResult(hostID: "local", result: ["acr": info])
        #expect(r.panes[ref]?.ccBusy == true)
        r.applyProbeResult(hostID: "local", result: [:], unresponsive: ["acr"])
        r.applyProbeResult(hostID: "local", result: [:], unresponsive: ["acr"])
        #expect(r.panes[ref]?.ccBusy == true && r.ccLive["local"]?["acr"]?.detail == "editing")
        // Control: genuinely absent for two ticks *is* an exit.
        r.applyProbeResult(hostID: "local", result: [:])
        r.applyProbeResult(hostID: "local", result: [:])
        #expect(r.panes[ref]?.ccBusy == false && r.ccLive["local"]?["acr"] == nil)
    }

    @Test func theAutoNameIsRerolledWhenTheHostAlreadyHasIt() {
        var m = NewSessionMachine(host: .local, locked: true, placeholder: "shell-abc")
        var rolls = ["shell-def", "shell-xyz"].makeIterator()
        let list = ZmxAdapter.ListResult(
            managed: [entry("shell-abc")],
            unresponsive: [.init(name: "shell-def", external: false, err: "Timeout")])
        m.setRecents(.success(list), reroll: { rolls.next()! })
        // `shell-abc` is taken by an answered session, `shell-def` by one that didn't answer.
        #expect(m.placeholder == "shell-xyz")
        // The reason a list failed is kept for the empty state.
        m.setRecents(.failure(.zmxMissing))
        #expect(m.unreachable && m.failure == .zmxMissing)
        // Typing the name of a session that merely didn't answer is not a "create".
        m.setRecents(.success(list))
        m.query = "shell-def"
        #expect(!m.canSmartJump)
        m.query = "brand-new"
        #expect(m.canSmartJump)
        // The picker finds a session by the directory it is sitting in.
        var e = entry("shell-q"); e.cwd = "/Users/me/dev/ghostty"
        m.setRecents(.success(.init(managed: [e])))
        m.query = "ghostty"
        #expect(m.sessions.map(\.name) == ["shell-q"])
    }
}

/// Against the real binary, in a throwaway socket dir. Skipped when zmx isn't installed.
/// One test, run in order: the steps share daemons.
struct ZmxBinaryContractTests {
    static let zmx = ZmxAdapter.localZmx
    static var available: Bool { FileManager.default.isExecutableFile(atPath: zmx) }

    @Test(.enabled(if: ZmxBinaryContractTests.available))
    func theBehavioursTheAdapterLeansOn() async throws {
        // sun_path is 104 bytes on macOS — keep the dir short.
        let dir = "/tmp/zf-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func zmx(_ args: String...) async throws -> String {
            // `-u`: a test run launched from inside a zmx session inherits ZMX_SESSION, which
            // would turn `attach` into a switch and mark rows with `→`.
            try await ZmxAdapter.run(
                argv: ["-u", "ZMX_SESSION", "-u", "ZMX_SESSION_PREFIX", "ZMX_DIR=\(dir)", Self.zmx] + args,
                timeout: 15)
        }
        defer {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["-u", "ZMX_SESSION", "ZMX_DIR=\(dir)", Self.zmx, "kill", "*"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            try? FileManager.default.removeItem(atPath: dir)
        }

        // 1. No sessions: exit 0 + empty stdout. If zmx ever exits non-zero here every idle
        //    host renders "unreachable".
        let empty = ZmxAdapter.partition(try await zmx("list"), hostID: "zz")
        #expect(empty.managed.isEmpty && empty.external.isEmpty && empty.unresponsive.isEmpty)

        // 2. A real row parses into every field the fork reads.
        _ = try await zmx("run", "zz-c1", "-d", "sleep", "60")
        #expect(ZmxAdapter.classifySet(stdout: try await zmx("set", "zz-c1", ZmxAdapter.aliasKV("my api"), "env=prod"),
                                       error: nil) == .acked)
        let row = try #require(ZmxAdapter.partition(try await zmx("list"), hostID: "zz").managed.first)
        #expect(row.name == "c1" && row.alias == "my api")
        #expect(abs(row.created.timeIntervalSinceNow) < 120)            // seconds, not ns
        #expect(row.pid.map { Darwin.kill($0, 0) == 0 } == true)
        #expect(row.cwd?.hasPrefix("/") == true)      // a URI on the wire, a path once decoded
        // Empty value removes the label.
        _ = try await zmx("set", "zz-c1", ZmxAdapter.aliasKV(nil))
        #expect(ZmxAdapter.partition(try await zmx("list"), hostID: "zz").managed.first?.alias == nil)

        // 3. `zmx set` on a session that isn't there fails, distinguishably from "too old".
        do { _ = try await zmx("set", "zz-nosuch", "ghostty_name=x"); Issue.record("expected failure") }
        catch { #expect(ZmxAdapter.classifySet(stdout: "", error: error) == .transient) }

        // 4. Kill: confirmation on stdout; already-gone is SessionNotFound.
        #expect(try await zmx("kill", "zz-c1").contains("killed session"))
        do { _ = try await zmx("kill", "zz-c1"); Issue.record("expected failure") }
        catch let e as ZmxAdapter.CommandError { #expect(e.stderr.contains("SessionNotFound")) }

        // 5. Why `*`-suffixed names are refused: the literal name is a prefix match in kill.
        for n in ["ab1", "ab2", "ab*", "keep"] { _ = try await zmx("run", n, "-d", "sleep", "60") }
        let listed = ZmxAdapter.partition(try await zmx("list"), hostID: "zz")
        #expect(Set(listed.external.map(\.name)) == ["ab1", "ab2", "keep"])   // `ab*` never a ref
        _ = try await zmx("kill", "ab*")
        #expect(ZmxAdapter.partition(try await zmx("list"), hostID: "zz").external.map(\.name) == ["keep"])
    }
}
#endif
