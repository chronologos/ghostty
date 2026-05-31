#if os(macOS)
import Foundation
import Testing
@testable import Ghostty

struct TransportTests {
    @Test func forkHostDecodeMissingOptional() throws {
        let json = #"{"id":"h","label":"host","transport":{"local":{}}}"#
        let h = try JSONDecoder().decode(ForkHost.self, from: Data(json.utf8))
        #expect(h.expanded == true)
        #expect(h.accentSlot == nil)
    }

    /// The PR36 `accentHue` migration shim is gone (TTL passed): the legacy key is now just
    /// an unknown key, and an out-of-range hand-edited slot clamps to nil instead of
    /// trapping at `palette[-1]` on launch.
    @Test func accentSlotDecodeIsLenient() throws {
        let legacy = #"{"id":"h","label":"host","transport":{"local":{}},"accentHue":0.08}"#
        #expect(try JSONDecoder().decode(ForkHost.self, from: Data(legacy.utf8)).accentSlot == nil)
        let outOfRange = #"{"id":"h","label":"host","transport":{"local":{}},"accentSlot":9999}"#
        #expect(try JSONDecoder().decode(ForkHost.self, from: Data(outOfRange.utf8)).accentSlot == nil)
        let negative = #"{"id":"h","label":"host","transport":{"local":{}},"accentSlot":-3}"#
        #expect(try JSONDecoder().decode(ForkHost.self, from: Data(negative.utf8)).accentSlot == nil)
    }

    @Test func lenientStateDecode() throws {
        let json = """
        {"version":1,"hosts":[
          {"id":"ok","label":"ok","transport":{"local":{}}},
          {"id":"bad","label":"bad","transport":{"et":{"host":"x"}}}
        ],"tabs":[]}
        """
        let s = try JSONDecoder().decode(ForkPersistence.State.self, from: Data(json.utf8))
        #expect(s.hosts.map(\.id) == ["ok"])
    }

    @Test func lenientRecentTagsDecode() throws {
        // One malformed tag (hue typed as a string) drops just that tag — it must not fail
        // the whole State decode (which would route fork.json through the "undecodable"
        // path and load .bak / empty state).
        let json = #"{"version":1,"hosts":[],"tabs":[],"recentTags":[{"text":"good","hue":0.5},{"text":"bad","hue":"oops"}]}"#
        let s = try JSONDecoder().decode(ForkPersistence.State.self, from: Data(json.utf8))
        #expect(s.recentTags.map(\.text) == ["good"])
    }

    @Test func shqRoundTrip() {
        #expect(shq("a") == "'a'")
        #expect(shq("a b") == "'a b'")
        #expect(shq("a';id;'b") == #"'a'\'';id;'\''b'"#)
        #expect(shq(["zmx", "attach", "x"]) == "'zmx' 'attach' 'x'")
    }

    @Test func paneStateOrder() {
        // rollup max-reduce: blocked > waiting > working
        #expect([PaneState.working, .blocked, .waiting].max() == .blocked)
        #expect([PaneState.working, .waiting].max() == .waiting)
    }

    @Test func identRejectsTrailingNewline() {
        #expect(isValidIdent("foo.bar-1_baz"))
        // ICU `$` would match before this trailing \n; `\z` must not.
        #expect(!isValidIdent("foo\n"))
        #expect(!isValidIdent(""))
        #expect(!isValidIdent("a b"))
        #expect(!isValidIdent("a;id"))
    }

    @Test func wrapLocal() {
        let cmd = ForkHost.Transport.local.wrap(["zmx", "attach", "h-n"])
        #expect(cmd == "'zmx' 'attach' 'h-n'")
    }

    @Test func wrapSshGolden() {
        let t = ForkHost.SSHTarget(user: "deploy", host: "prod-web-01")
        let cmd = ForkHost.Transport.ssh(t).wrap(["zmx", "attach", "h-n"])
        #expect(cmd == #"'ssh' '-t' '--' 'deploy@prod-web-01' ''\''env'\'' '\''TERM_PROGRAM=ghostty'\'' '\''TERM_PROGRAM_VERSION=1.2.0'\'' '\''zmx'\'' '\''attach'\'' '\''h-n'\'''"#)
    }

    @Test func wrapSshInjection() {
        let t = ForkHost.SSHTarget(user: nil, host: "h")
        let cmd = ForkHost.Transport.ssh(t).wrap(["zmx", "attach", "a';id;'b"])
        #expect(!cmd.contains(";id;") || cmd.contains(#"'\'';id;'\''"#))
    }

    @Test func controlArgvSsh() {
        let t = ForkHost.SSHTarget(user: nil, host: "h")
        let argv = ForkHost.Transport.ssh(t).controlArgv(["zmx", "list", "--short"])
        #expect(argv == ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", "h", "'zmx' 'list' '--short'"])
    }

    @Test func sshTargetValidation() {
        #expect(ForkHost.SSHTarget(user: "deploy", host: "prod-web-01").isValid)
        #expect(ForkHost.SSHTarget(user: nil, host: "10.40.12.22").isValid)
        #expect(!ForkHost.SSHTarget(user: nil, host: "h;rm -rf").isValid)
        #expect(!ForkHost.SSHTarget(user: "u$(id)", host: "h").isValid)
    }

    /// `init?(parsing:)` is the path every user-typed connection string takes (HostsView
    /// add form). The doc comment claims it's the inverse of `connectionString`.
    @Test func sshTargetParsing() {
        // Basic split + whitespace trim.
        let full = ForkHost.SSHTarget(parsing: "  deploy@prod-web-01 \n")
        #expect(full?.user == "deploy" && full?.host == "prod-web-01")
        let bare = ForkHost.SSHTarget(parsing: "prod-web-01")
        #expect(bare?.user == nil && bare?.host == "prod-web-01")
        // Round trip: parsing(connectionString) == self for valid targets.
        let t = ForkHost.SSHTarget(user: "me", host: "box.local")
        #expect(ForkHost.SSHTarget(parsing: t.connectionString) == t)
        // Rejections — empty parts, double-@ (host charset), ports, IPv6, shell metachars.
        #expect(ForkHost.SSHTarget(parsing: "") == nil)
        #expect(ForkHost.SSHTarget(parsing: "@host") == nil)
        #expect(ForkHost.SSHTarget(parsing: "user@") == nil)
        #expect(ForkHost.SSHTarget(parsing: "a@b@c") == nil)
        #expect(ForkHost.SSHTarget(parsing: "host:22") == nil)       // ports unsupported
        #expect(ForkHost.SSHTarget(parsing: "user@host:22") == nil)
        #expect(ForkHost.SSHTarget(parsing: "::1") == nil)           // IPv6 unsupported
        #expect(ForkHost.SSHTarget(parsing: "[fe80::1]") == nil)
        #expect(ForkHost.SSHTarget(parsing: "host;rm -rf /") == nil)
        #expect(ForkHost.SSHTarget(parsing: "$(id)@h") == nil)
        // Leading-dash host is ACCEPTED by the charset — the `--` in both ssh argv builders
        // is the load-bearing defense against option injection. Pin that so tightening the
        // charset (or dropping the `--`) is a conscious decision.
        #expect(ForkHost.SSHTarget(parsing: "-h") != nil)
    }

    /// fork.json is hand-editable: a hostile/typo'd tag hue must clamp at decode, not trap
    /// at `Int(hue * 97)` (the Pebble seed) on every launch — that's a launch-loop brick.
    @Test func paneTagHueClampsAtDecode() throws {
        func tag(_ hue: String) throws -> PaneTag {
            try JSONDecoder().decode(PaneTag.self, from: Data(#"{"text":"t","hue":\#(hue)}"#.utf8))
        }
        #expect(try tag("0.5").hue == 0.5)
        #expect(try tag("1e300").hue == 1.0)     // overflow → clamp
        #expect(try tag("-3").hue == 0.0)        // negative → clamp
        #expect(try tag("1e-320").hue >= 0)      // subnormal → finite, in range
        // Non-finite (JSON can't carry literal NaN/Infinity, but a future encoder bug or a
        // hand-edit through a tolerant parser could) — covered by the memberwise path too.
        #expect(PaneTag(text: "t", hue: 7).hue == 7)  // memberwise unclamped (UI passes 0...1)
    }

    /// `Info.==` is the publish guard for the whole CC poll: a field added to `Info` but not
    /// to `==` silently defeats `mergeCC`'s `!=` check and the sidebar stops repainting for
    /// changes in that field. The Mirror count forces the conscious decision.
    @Test func ccInfoEqualityContract() {
        let base = CCProbe.Info(name: "n", status: "idle", cwd: "/x", updatedAt: .distantPast,
                                waitingFor: nil, tempo: "active", needs: nil, detail: "d",
                                sock: "/s")
        // 9 stored fields today: name, status, cwd, updatedAt, waitingFor, tempo, needs,
        // detail, sock. Adding a 10th without updating `==`/`hash`/this test fails here.
        #expect(Mirror(reflecting: base).children.count == 9)
        // updatedAt is excluded BY DESIGN (heartbeat-only ticks must not publish).
        var heartbeat = base; heartbeat.updatedAt = .distantFuture
        #expect(base == heartbeat)
        #expect(base.hashValue == heartbeat.hashValue)
        // Every other field participates in ==.
        func differs(_ mutate: (inout CCProbe.Info) -> Void) -> Bool {
            var m = base; mutate(&m); return m != base
        }
        #expect(differs { $0.name = "y" })
        #expect(differs { $0.status = "busy" })
        #expect(differs { $0.cwd = "/y" })
        #expect(differs { $0.waitingFor = "w" })
        #expect(differs { $0.tempo = "blocked" })
        #expect(differs { $0.needs = "answer" })
        #expect(differs { $0.detail = "other" })
        #expect(differs { $0.sock = "/t" })
    }

    @Test func sessionRefValidation() {
        #expect(SessionRef(hostID: "local", name: "shell-abc").isValid)
        #expect(!SessionRef(hostID: "local", name: "a;b").isValid)
    }

    // Mirrors zmx util.zig:590-602.
    @Test(arguments: ["→ ", "  ", ""])
    func parseListLine(prefix: String) {
        let e = ZmxAdapter.parse(line: "\(prefix)name=dev\tpid=123\tclients=2\tcreated=1700000000"[...])
        #expect(e?.name == "dev")
        #expect(e?.clients == 2)
        #expect(e?.created == Date(timeIntervalSince1970: 1700000000))
        #expect(e?.pid == 123)
    }

    @Test func parseListLineNoPid() {
        let e = ZmxAdapter.parse(line: "name=dev\tclients=1\tcreated=1700000000"[...])
        #expect(e?.pid == nil)
    }

    @Test func parseListLineErr() {
        #expect(ZmxAdapter.parse(line: "  name=dead\terr=ConnectionRefused\tstatus=cleaning up") == nil)
    }

    @Test func detachedScriptCCNameQuoted() {
        let ref = SessionRef(hostID: "local", name: "s")
        let cmd = ZmxAdapter.detachedScript(host: .local, ref: ref, ccName: "$(id)")
        #expect(cmd.contains("was: %s"))
        // Doubly-quoted: inner shq → '$(id)', outer shq(["sh","-c",inner]) → each ' → '\''.
        // Without the inner shq the outer level would contain bare `$(id)` and this fails.
        #expect(cmd.contains(#"'\''$(id)'\''"#))
    }

    @Test func restoreCmdCCNameQuoted() {
        let argv = ZmxAdapter.restoreCmd(ccName: "a';id;'b")
        #expect(argv[0] == "sh" && argv[1] == "-c")
        #expect(argv[2].contains(#"'a'\'';id;'\''b'"#))
        #expect(argv[2].hasSuffix("exec ${SHELL:-/bin/sh}"))
    }

    @Test func wireName() {
        let ref = SessionRef(hostID: "abcd1234", name: "shell-x")
        #expect(ZmxAdapter.wireName(ref) == "abcd1234-shell-x")
    }

    @Test func expandHoverCommand() {
        let ref = SessionRef(hostID: "h1", name: "shell-abc")
        let ssh = ForkHost(id: "h1", label: "box", transport: .ssh(.init(user: "me", host: "box")))
        let out = ZmxAdapter.expand(["lazygit", "-p", "{cwd}", "{ref}", "{host}"],
                                    host: ssh, ref: ref, cwd: "/tmp/$(rm -rf ~)")
        // Whole-token only; hostile cwd stays one argv element (shq/Process.arguments
        // boundary handles inertness — this just verifies no string-splitting happened).
        // {host} → ssh connectionString, not the SHA-prefix `hostID`.
        #expect(out == ["lazygit", "-p", "/tmp/$(rm -rf ~)", "shell-abc", "me@box"])
        #expect(ZmxAdapter.expand(["{cwd}"], host: .local, ref: ref, cwd: nil) == ["."])
        #expect(ZmxAdapter.expand(["{host}"], host: .local, ref: ref, cwd: nil) == ["localhost"])
        // Substring NOT substituted — "-C={cwd}" passes through verbatim.
        #expect(ZmxAdapter.expand(["-C={cwd}"], host: .local, ref: ref, cwd: "/x") == ["-C={cwd}"])
    }

    @Test func renameScriptShape() {
        let s = CCProbe.renameScript(sock: "/tmp/$(x).sock", to: #"a"b"#)!
        // JSON-encoded name (quote escaped) shq'd as one printf arg; sock shq'd after `--`.
        // `.sortedKeys` → alphabetical, deterministic.
        #expect(s.contains(#"'{"action":"rename","name":"a\"b","type":"control"}'"#))
        #expect(s.hasSuffix(#"| nc -w 1 -U -- '/tmp/$(x).sock'"#))
    }

    @Test func lenientHoverCommandsDecode() throws {
        let json = #"{"hoverCommands":{"j":{"cmd":["jj","log"],"mode":"pane"},"o":{"cmd":["open"],"mode":"overlay"},"x":{"cmd":["a"],"mode":"nope"}}}"#
        let s = try JSONDecoder().decode(ForkPersistence.State.self, from: Data(json.utf8))
        #expect(s.hoverCommands["j"]?.mode == .pane)
        // `overlay` mode was removed (PR51): old entries drop like any unknown mode, and
        // the load path's lossyDropCount preserves the original file aside.
        #expect(s.hoverCommands["o"] == nil)
        #expect(s.hoverCommands["x"] == nil)
    }

    @Test func stripControlFilters() {
        #expect(stripControl("a\u{1B}]52;c;evil\u{07}b", max: 64) == "a]52;c;evilb")
        #expect(stripControl("x\u{7F}\u{9B}y", max: 64) == "xy")
        #expect(stripControl("abcdef", max: 3) == "abc")
    }

    @Test func persistedTreePaneCount() {
        let leaf = PersistedTree.leaf(.init(hostID: "h", name: "n"))
        #expect(PersistedTree.empty.paneCount == 0)
        #expect(leaf.paneCount == 1)
        #expect(PersistedTree.split(horizontal: true, ratio: 0.5,
                                    a: leaf,
                                    b: .split(horizontal: false, ratio: 0.5, a: leaf, b: leaf)).paneCount == 3)
    }

    @Test func appendingLeafOnEmpty() {
        let ref = SessionRef(hostID: "h", name: "a")
        let t = PersistedTree.empty.appending(leaf: ref)
        #expect(t == .leaf(ref))
    }

    @Test func removingFirstMatchOnly() {
        // Split-picker can attach the same session twice in one tab; removing(ref)
        // must drop one leaf, not all — see Host.swift:151.
        let a = SessionRef(hostID: "h", name: "a")
        let dup = PersistedTree.empty.appending(leaf: a).appending(leaf: a)
        #expect(dup.paneCount == 2)
        #expect(dup.removing(a).paneCount == 1)
        #expect(dup.removing(a).removing(a) == .empty)
    }

    @Test func appendingLeafOnSplit() {
        let a = SessionRef(hostID: "h", name: "a")
        let b = SessionRef(hostID: "h", name: "b")
        let c = SessionRef(hostID: "h", name: "c")
        let split = PersistedTree.split(horizontal: false, ratio: 0.5,
                                        a: .leaf(a), b: .leaf(b))
        let t = split.appending(leaf: c)
        #expect(t.paneCount == 3)
        #expect(t.leafRefs == [a, b, c])
        // Appended leaf lives on the right of a new 50/50 horizontal split.
        if case .split(let h, let ratio, _, let rhs) = t {
            #expect(h == true)
            #expect(ratio == 0.5)
            #expect(rhs == .leaf(c))
        } else {
            Issue.record("expected split at root")
        }
    }

    // (`merging(_:)` tests removed with the API — it had no production caller.)

    // MARK: CCProbe

    @Test func ccProbeParsePS() {
        let m = CCProbe.parsePS("  100   1\n  200   100\n  201   100\n  300   200\n")
        #expect(m[100]?.sorted() == [200, 201])
        #expect(m[200] == [300])
    }

    private func entry(_ name: String, pid: Int32?, external: Bool = false) -> ZmxAdapter.ListEntry {
        .init(name: name, clients: 1, created: .distantPast, external: external, pid: pid)
    }

    @Test func ccProbeMatchShallowestWins() {
        // 100 → 200 → 300; both 200 and 300 are CC pids → 200 (shallowest) wins.
        let children: [Int32: [Int32]] = [100: [200], 200: [300]]
        let cc: [Int32: CCProbe.Info] = [200: .init(name: "outer"), 300: .init(name: "inner")]
        let r = CCProbe.match(entries: [entry("dev", pid: 100)], hostID: "h",
                              children: children, cc: cc)
        #expect(r["dev"]?.name == "outer")
    }

    @Test func ccProbeMatchSkipsZeroPid() {
        // pid 0/nil must not seed BFS — launchd's ppid is 0, so a 0-seed would walk
        // everything and attribute an unrelated CC.
        let children: [Int32: [Int32]] = [0: [1], 1: [42]]
        let cc: [Int32: CCProbe.Info] = [42: .init(name: "stray")]
        let r = CCProbe.match(entries: [entry("a", pid: 0), entry("b", pid: nil)], hostID: "h",
                              children: children, cc: cc)
        #expect(r.isEmpty)
    }

    @Test func ccProbeMatchKeyedByRefKey() {
        // Managed `acr` and external `acr` share entry.name post-prefix-strip; result must
        // key on SessionRef.key (`acr` vs `@acr`) so they don't collide.
        let children: [Int32: [Int32]] = [10: [11], 20: [21]]
        let cc: [Int32: CCProbe.Info] = [11: .init(name: "mine"), 21: .init(name: "theirs")]
        let r = CCProbe.match(
            entries: [entry("acr", pid: 10, external: false), entry("acr", pid: 20, external: true)],
            hostID: "h", children: children, cc: cc)
        #expect(r["acr"]?.name == "mine")
        #expect(r["@acr"]?.name == "theirs")
    }

    /// The native local probe's process-table read: must see this very test process and
    /// its parent relationship — that's the same edge the zmx-pid → CC-pid BFS walks.
    @Test func localProcessTreeContainsSelf() {
        let tree = CCProbe.localProcessTree()
        #expect(tree != nil)
        let me = getpid(), parent = getppid()
        #expect(tree?[parent]?.contains(me) == true)
    }
}
#endif
