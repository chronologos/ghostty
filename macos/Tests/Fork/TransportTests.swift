#if os(macOS)
import Foundation
import Testing
@testable import Ghostty

struct TransportTests {
    @Test func forkHostDecodeMissingOptional() throws {
        let json = #"{"id":"h","label":"host","transport":{"local":{}}}"#
        let h = try JSONDecoder().decode(ForkHost.self, from: Data(json.utf8))
        #expect(h.expanded == true)
        #expect(h.accentHue == nil)
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

    @Test func shqRoundTrip() {
        #expect(shq("a") == "'a'")
        #expect(shq("a b") == "'a b'")
        #expect(shq("a';id;'b") == #"'a'\'';id;'\''b'"#)
        #expect(shq(["zmx", "attach", "x"]) == "'zmx' 'attach' 'x'")
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
        #expect(s.contains(#"'{"type":"control","action":"rename","name":"a\"b"}'"#))
        #expect(s.hasSuffix(#"| nc -NU -- '/tmp/$(x).sock'"#))
    }

    @Test func lenientHoverCommandsDecode() throws {
        let json = #"{"hoverCommands":{"j":{"cmd":["jj","log"],"mode":"overlay"},"x":{"cmd":["a"],"mode":"nope"}}}"#
        let s = try JSONDecoder().decode(ForkPersistence.State.self, from: Data(json.utf8))
        #expect(s.hoverCommands["j"]?.mode == .overlay)
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

    @Test func mergingConcatsLeavesInOrder() {
        let a = SessionRef(hostID: "h", name: "a")
        let b = SessionRef(hostID: "h", name: "b")
        let c = SessionRef(hostID: "h", name: "c")
        let left = PersistedTree.leaf(a)
        let right = PersistedTree.split(horizontal: true, ratio: 0.5,
                                        a: .leaf(b), b: .leaf(c))
        #expect(left.merging(right).leafRefs == [a, b, c])
        // Merging into empty flattens other's shape to a right-leaning chain,
        // starting with its first leaf as a bare leaf.
        #expect(PersistedTree.empty.merging(right).leafRefs == [b, c])
    }

    @Test func mergingEmptyIsIdentity() {
        let a = SessionRef(hostID: "h", name: "a")
        let t = PersistedTree.split(horizontal: false, ratio: 0.5,
                                    a: .leaf(a), b: .leaf(a))
        #expect(t.merging(.empty) == t)
        #expect(PersistedTree.empty.merging(.empty) == .empty)
    }

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
}
#endif
