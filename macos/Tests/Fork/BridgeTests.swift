#if os(macOS)
import Foundation
import Testing
@testable import Ghostty

private typealias Link = PaneMachine.Link
private func stamp(_ seq: UInt64, born: UInt64 = 9) -> PaneMachine.Stamp { .init(born: born, seq: seq) }
private func link(_ s: Link.State, _ seq: UInt64, inferred: Bool = false, born: UInt64 = 9) -> Link {
    .init(state: s, inferred: inferred, stamp: stamp(seq, born: born))
}

/// The lines are in the bridge's own shape (its `the_wire_shape` test, `bridge/README.md`).
struct BridgeWireTests {
    private func decode(_ s: String) -> BridgeMsg? { BridgeMsg.decode(Data(s.utf8)) }

    @Test func theFourLines() {
        #expect(decode(#"{"t":"hello","proto":1,"bridge":"0.1.0","zmx":"0.8.1"}"#) == .hello(proto: 1, bridge: "0.1.0"))
        #expect(decode(#"{"t":"ready"}"#) == .ready)
        #expect(decode(#"{"t":"del","name":"local-a"}"#) == .del(name: "local-a"))
        #expect(decode(#"{"t":"set","session":{"name":"b","pid":7,"born":9,"seq":0}}"#)
                == .set(.init(name: "b", born: 9, seq: 0, now: nil)))
    }

    @Test func aBlockedProgram() throws {
        let line = #"{"t":"set","session":{"name":"s1","pid":16,"born":1700000000,"seq":16,"now":{"id":"","state":"blocked","kind":"question","app":"deployer","msg":"Ship to eu-west · 3 of 4?","source":"status","seq":15,"at":1700000009568},"status":[{"id":"","state":"blocked","source":"status","seq":15,"at":1}],"title":{"text":"x","seq":7,"at":1}}}"#
        guard case .set(let s) = decode(line) else { Issue.record("not a set"); return }
        let now = try #require(s.now)
        #expect(now.state == .blocked && now.kind == "question" && now.app == "deployer" && !now.inferred)
        #expect(now.msg == "Ship to eu-west · 3 of 4?")
        #expect(now.at == Date(timeIntervalSince1970: 1_700_000_009.568))
        // The stamp is the *status*'s seq, not the session's: a bell after it is not news about it.
        #expect(s.link == link(.blocked, 15, born: 1_700_000_000))
    }

    @Test func anythingElseIsNotALine() {
        for bad in ["", "{", "[]", #"{"t":"later"}"#, #"{"t":"hello"}"#, #"{"t":"del"}"#, #"{"t":"del","name":""}"#,
                    #"{"t":"set"}"#, #"{"t":"set","session":{"name":"a","born":-1,"seq":0}}"#,
                    #"{"t":"set","session":{"name":"","born":1,"seq":0}}"#] {
            #expect(decode(bad) == nil, "\(bad)")
        }
        #expect(decode(#"{"t":"del","name":"\#(String(repeating: "a", count: 256))"}"#) == nil)
    }

    @Test func anUnknownStateIsNoStatusRatherThanAGuess() {
        let s = #"{"t":"set","session":{"name":"a","born":1,"seq":2,"now":{"state":"paused","source":"status","seq":2,"at":0}}}"#
        #expect(decode(s) == .set(.init(name: "a", born: 1, seq: 2, now: nil)))
    }

    @Test func onlyTheProgramsOwnWordCountsAsItsOwn() {
        func inferred(_ source: String) -> Bool? {
            guard case .set(let s) = decode(
                #"{"t":"set","session":{"name":"a","born":1,"seq":2,"now":{"state":"done"\#(source),"seq":2,"at":0}}}"#)
            else { return nil }
            return s.now?.inferred
        }
        #expect(inferred(#","source":"status""#) == false)
        #expect(inferred(#","source":"progress""#) == true)
        #expect(inferred(#","source":"tea-leaves""#) == true)
        #expect(inferred("") == true)
    }

    @Test func textIsStrippedAndCappedAgain() throws {
        let long = String(repeating: "x", count: 5000)
        let s = #"{"t":"set","session":{"name":"a","born":1,"seq":2,"now":{"state":"error","msg":"a\u001b[31mb\#(long)","app":"\u0007","source":"status","seq":2,"at":0}}}"#
        guard case .set(let got) = decode(s) else { Issue.record("not a set"); return }
        let now = try #require(got.now)
        #expect(now.msg?.hasPrefix("a[31mbx") == true && (now.msg?.count ?? 0) <= 512)
        #expect(now.app == nil)
    }

    @Test func whatTheProgramSaysReplacesWhatTheProbeGuessed() {
        let probe = CCProbe.Info(name: "fix-auth", status: "busy", cwd: "/x", waitingFor: "old",
                                 tempo: "active", needs: "stale", detail: "editing", sock: "/s")
        let b = BridgeStatus(state: .blocked, kind: "permission", msg: "Run rm?", seq: 1).overlaid(on: probe)
        #expect(b.isBlocked && b.attention == "Run rm?" && b.status == "idle" && b.detail == nil)
        #expect(b.name == "fix-auth" && b.cwd == "/x" && b.sock == "/s")   // only the probe knows these
        let w = BridgeStatus(state: .working, msg: "Reading", seq: 2).overlaid(on: probe)
        #expect(w.status == "busy" && !w.isBlocked && w.needs == nil && w.detail == "Reading")
        let alone = BridgeStatus(state: .done, msg: "Built", seq: 3).overlaid(on: nil)
        #expect(alone.status == "idle" && alone.detail == "Built" && alone.name == nil)
    }

    @Test func theCommandIsAConstant() {
        let ssh = ForkHost(id: "h1", label: "box", transport: .ssh(.init(user: "me", host: "box.example")))
        #expect(ZmxAdapter.bridgeArgv(host: ssh) == [
            "ssh", "-T", "-o", "BatchMode=yes",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "ConnectTimeout=15",
            "--", "me@box.example", "'zmx-bridge' '--stdio'",
        ])
        let local = ZmxAdapter.bridgeArgv(host: .local)
        #expect(local.count == 2 && local[0].hasSuffix("zmx-bridge") && local[1] == "--stdio")
    }
}

struct PaneMachineLinkTests {
    private func on(_ l: Link?, active: Bool = false, quiet: Bool = false) -> PaneEvent {
        .link(l, isActive: active, quiet: quiet)
    }

    @Test func eachStateHasItsLamp() {
        var m = PaneMachine()
        for (s, dot) in [(Link.State.working, PaneState.working), (.blocked, .blocked), (.error, .failed),
                         (.done, .waiting)] {
            m.apply(on(link(s, 1)))
            #expect(m.dot == dot)
        }
        m.apply(on(link(.idle, 2)))
        #expect(m.dot == nil)
    }

    @Test func unreadIsNewerThanWhatYouLastLookedAt() {
        var m = PaneMachine()
        for s in [Link.State.done, .error, .blocked] {
            m.apply(on(link(s, 5)))
            #expect(m.dot != nil && m.needsYou)
            m.apply(.viewed)
            #expect(m.dot == nil && !m.needsYou)
            // Said again, unchanged (a reconnect, the 3s re-apply): still read.
            m.apply(on(link(s, 5)))
            #expect(m.dot == nil)
            m.seen = nil
        }
        m.apply(on(link(.done, 5))); m.apply(.viewed)
        m.apply(on(link(.done, 6)))
        #expect(m.dot == .waiting)
    }

    @Test func aRestartedSessionStartsOver() {
        var m = PaneMachine()
        m.apply(on(link(.done, 400))); m.apply(.viewed)
        m.apply(on(link(.done, 2, born: 10)))       // new daemon, same name, small seq
        #expect(m.dot == .waiting)
    }

    /// CC leaves its OSC 9;4 bar up while it waits on a question, and the probe can lag by a
    /// poll. Neither may hide `blocked`.
    @Test func theProgramsOwnWordOutranksEverythingElse() {
        var m = PaneMachine()
        m.apply(.progress)
        m.apply(.probe(blocked: false, busy: true, sig: .init(tempo: "active", needs: nil)))
        #expect(m.dot == .working)
        m.apply(on(link(.blocked, 3)))
        #expect(m.dot == .blocked && m.needsYou)
        m.apply(on(link(.idle, 4)))
        #expect(m.dot == nil && !m.needsYou)
        // Link gone: the old witnesses are believed again.
        m.apply(on(nil))
        #expect(m.dot == .working)
    }

    @Test func aProgressBarIsOnlyOneMoreWitness() {
        var m = PaneMachine()
        m.apply(on(link(.working, 1, inferred: true)))
        #expect(m.dot == .working && !m.needsYou)
        m.apply(on(link(.done, 2, inferred: true)))
        #expect(m.dot == .waiting && m.needsYou)
        // The probe knows something a progress bar can't say.
        m.apply(.probe(blocked: true, busy: false, sig: .init(tempo: "blocked", needs: "x")))
        #expect(m.dot == .blocked)
        m.apply(.viewed)
        #expect(m.dot == nil)
        m.apply(on(link(.error, 3, inferred: true)))
        #expect(m.dot == .failed)
    }

    @Test func aBackgroundFinishBannersOnceUntilViewed() {
        var m = PaneMachine()
        m.apply(on(link(.working, 1)))
        #expect(m.apply(on(link(.done, 2))) == true)
        #expect(m.apply(on(link(.done, 2))) == false)        // repeated
        m.apply(on(link(.working, 3)))
        #expect(m.apply(on(link(.done, 4))) == false)        // `notified` until viewed
        m.apply(.viewed)
        m.apply(on(link(.working, 5)))
        #expect(m.apply(on(link(.error, 6))) == true)
    }

    @Test func blockedWorkingAndIdleNeverBanner() {
        var m = PaneMachine()
        for (i, s) in [Link.State.working, .blocked, .idle].enumerated() {
            #expect(m.apply(on(link(s, UInt64(i + 1)))) == false)
        }
    }

    @Test func aFinishInTheVisibleTabIsReadAsItLands() {
        var m = PaneMachine()
        #expect(m.apply(on(link(.done, 2), active: true)) == false)
        #expect(m.dot == nil && m.seen == stamp(2))
        // A question is not: one split of four is easy to miss.
        m.apply(on(link(.blocked, 3), active: true))
        #expect(m.dot == .blocked)
    }

    @Test func watchBannersEvenInTheVisibleTab() {
        var m = PaneMachine()
        m.apply(.watch(true))
        #expect(m.apply(on(link(.done, 2), active: true)) == true)
        #expect(m.watched == false)
    }

    /// An attached pane reports one finish twice: the daemon's `done` at once, and the
    /// surface's `.settled` 250ms later. Either order, one banner.
    @Test func oneFinishDownTwoPathsIsOneBanner() {
        var a = PaneMachine()
        a.apply(.progress)
        #expect(a.apply(on(link(.done, 2))) == true)
        #expect(a.apply(.settled(isActive: false)) == false)
        var b = PaneMachine()
        b.apply(.progress)
        #expect(b.apply(.settled(isActive: false)) == true)
        #expect(b.apply(on(link(.done, 2))) == false)
    }

    @Test func theFirstLookAfterLaunchLightsLampsButStaysQuiet() {
        var m = PaneMachine()
        #expect(m.apply(on(link(.done, 7), quiet: true)) == false)
        #expect(m.dot == .waiting)
        // ...and does not owe that banner later.
        #expect(m.apply(on(link(.done, 7))) == false)
        // Read in an earlier run.
        var old = PaneMachine(seen: stamp(7))
        #expect(old.apply(on(link(.done, 7), quiet: true)) == false)
        #expect(old.dot == nil)
    }

    @Test func aDroppedLinkDoesNotRepeatOldNewsButDeliversNew() {
        var m = PaneMachine()
        #expect(m.apply(on(link(.done, 2))) == true)
        m.apply(.viewed)
        m.apply(on(nil))
        #expect(m.dot == nil)
        #expect(m.apply(on(link(.done, 2))) == false)
        m.apply(on(nil))
        #expect(m.apply(on(link(.done, 9))) == true)         // finished during the outage
    }

    @Test func losingTheSurfaceDoesNotLoseTheDaemon() {
        var m = PaneMachine()
        m.apply(on(link(.working, 1)))
        m.apply(.detached)
        #expect(m.dot == .working)
    }
}

@MainActor
struct BridgeRegistryTests {
    private func reset() -> SessionRegistry {
        let r = SessionRegistry.shared
        r.resetForTesting()
        r.aliasPusher = { _, _, _, _ in }
        return r
    }
    private func makeTab(_ r: SessionRegistry, name: String, external: Bool = false) -> TabModel.ID {
        let t = r.newTab(on: "local", title: name)
        r.setPersistedTree(.empty.appending(leaf: SessionRef(hostID: "local", name: name, external: external)),
                           for: t.id)
        return t.id
    }
    private func set(_ wire: String, _ s: Link.State?, _ seq: UInt64, msg: String? = nil,
                     inferred: Bool = false) -> BridgeMsg {
        .set(.init(name: wire, born: 9, seq: seq,
                   now: s.map { .init(state: $0, msg: msg, inferred: inferred, seq: seq) }))
    }
    private let hello = BridgeMsg.hello(proto: 1, bridge: "t")

    @Test func sessionsAreMatchedByWireName() {
        let r = reset()
        _ = makeTab(r, name: "api"); _ = makeTab(r, name: "api", external: true)
        let managed = SessionRef(hostID: "local", name: "api")
        let external = SessionRef(hostID: "local", name: "api", external: true)
        r.noteBridge(hostID: "local", [hello, set("local-api", .working, 1), set("api", .blocked, 1),
                                       set("stranger", .error, 1), .ready])
        #expect(r.dot(ref: managed) == .working && r.dot(ref: external) == .blocked)
        #expect(r.panes.count == 2)          // a session that is nobody's pane mints no machine
    }

    @Test func delAndASilentReadyBothEndIt() {
        let r = reset()
        _ = makeTab(r, name: "a"); _ = makeTab(r, name: "b")
        let a = SessionRef(hostID: "local", name: "a"), b = SessionRef(hostID: "local", name: "b")
        r.noteBridge(hostID: "local", [hello, set("local-a", .working, 1), set("local-b", .working, 1), .ready])
        r.noteBridge(hostID: "local", [.del(name: "local-a")])
        #expect(r.dot(ref: a) == nil && r.dot(ref: b) == .working)
        // Reconnect: lamps hold through `hello`, and whoever isn't named by `ready` is gone.
        r.noteBridge(hostID: "local", [hello])
        #expect(r.dot(ref: b) == .working)
        r.noteBridge(hostID: "local", [.ready])
        #expect(r.dot(ref: b) == nil)
    }

    @Test func aLostLinkLeavesNoLampBehind() {
        let r = reset()
        _ = makeTab(r, name: "a")
        let a = SessionRef(hostID: "local", name: "a")
        r.noteBridge(hostID: "local", [hello, set("local-a", .working, 1), .ready])
        r.noteBridgeDown(hostID: "local")
        #expect(r.dot(ref: a) == nil && r.linkSessions["local"] == nil)
    }

    @Test func bannersNameThePaneAndSkipTheOpening() {
        let r = reset()
        let tab = makeTab(r, name: "a"); _ = makeTab(r, name: "b")
        var posted: [(TabModel.ID, String)] = []
        r.linkBanner = { id, title, _ in posted.append((id, title)) }
        r.noteBridge(hostID: "local", [hello, set("local-a", .done, 4), .ready])
        #expect(posted.isEmpty && r.dot(ref: .init(hostID: "local", name: "a")) == .waiting)
        r.noteBridge(hostID: "local", [set("local-b", .error, 2)])
        #expect(posted.map(\.1) == ["b failed"])
        r.renamePane(tab: tab, name: "a", to: "my api")
        r.apply(.init(hostID: "local", name: "a"), .viewed)
        r.noteBridge(hostID: "local", [set("local-a", .done, 6)])
        #expect(posted.count == 2 && posted[1].0 == tab && posted[1].1 == "my api finished")
    }

    @Test func theVisibleTabReadsItsOwnFinishes() {
        let r = reset()
        let tab = makeTab(r, name: "a")
        r.setActive(tab: tab)
        var posted = 0
        r.linkBanner = { _, _, _ in posted += 1 }
        r.noteBridge(hostID: "local", [hello, .ready, set("local-a", .done, 4)])
        #expect(posted == 0 && r.dot(ref: .init(hostID: "local", name: "a")) == nil)
    }

    @Test func aBarThatComesStraightBackIsNotAFinish() async throws {
        let r = SessionRegistry.isolatedForTesting()
        _ = makeTab(r, name: "a")
        let a = SessionRef(hostID: "local", name: "a")
        var posted = 0
        r.linkBanner = { _, _, _ in posted += 1 }
        r.noteBridge(hostID: "local", [hello, .ready, set("local-a", .working, 1, inferred: true)])
        r.noteBridge(hostID: "local", [set("local-a", .done, 2, inferred: true)])
        #expect(r.dot(ref: a) == .working)                   // not believed yet
        r.noteBridge(hostID: "local", [set("local-a", .working, 3, inferred: true)])
        try await Task.sleep(for: .milliseconds(400))
        #expect(r.dot(ref: a) == .working && posted == 0)
        r.noteBridge(hostID: "local", [set("local-a", .done, 4, inferred: true)])
        try await Task.sleep(for: .milliseconds(400))
        #expect(r.dot(ref: a) == .waiting && posted == 1)
        // Said outright, it is believed at once.
        r.noteBridge(hostID: "local", [set("local-a", .working, 5), set("local-a", .error, 6)])
        #expect(r.dot(ref: a) == .failed)
    }

    @Test func statusTextIsLaidOverTheProbes() {
        let r = reset()
        _ = makeTab(r, name: "a"); _ = makeTab(r, name: "b")
        r.applyProbeResult(hostID: "local", result: [
            "a": .init(name: "fix", status: "busy", detail: "probe says"),
            "b": .init(name: "other", status: "idle", detail: "untouched"),
        ])
        r.noteBridge(hostID: "local", [hello, set("local-a", .blocked, 3, msg: "Run it?"),
                                       set("local-b", .working, 1, inferred: true), .ready])
        r.publishCC("local")
        #expect(r.ccLive["local"]?["a"]?.attention == "Run it?" && r.ccLive["local"]?["a"]?.name == "fix")
        #expect(r.ccLive["local"]?["b"]?.detail == "untouched")       // a bar has nothing to say
        // The next probe tick must not put the stale text back.
        r.applyProbeResult(hostID: "local", result: ["a": .init(name: "fix", status: "busy", detail: "probe says")])
        #expect(r.ccLive["local"]?["a"]?.attention == "Run it?")
        #expect(r.probeSaw(.init(hostID: "local", name: "a")))
        // Link gone: the probe's own words again.
        r.noteBridgeDown(hostID: "local")
        r.publishCC("local")
        #expect(r.ccLive["local"]?["a"]?.detail == "probe says")
    }

    @Test func aProgramTheProbeNeverSawStillGetsItsLine() {
        let r = reset()
        _ = makeTab(r, name: "build")
        let ref = SessionRef(hostID: "local", name: "build")
        r.noteBridge(hostID: "local", [hello, set("local-build", .working, 1, msg: "Compiling 40/90"), .ready])
        r.publishCC("local")
        #expect(r.ccLive["local"]?["build"]?.detail == "Compiling 40/90")
        #expect(!r.probeSaw(ref))             // and is not mistaken for an agent's prompt (⌘⇧R nudge)
    }

    @Test func aHostileHostCannotGrowTheTable() {
        let r = reset()
        _ = makeTab(r, name: "a")
        r.noteBridge(hostID: "local", [hello] + (0..<2000).map { set("x\($0)", .working, 1) })
        #expect(r.linkSessions["local"]?.count == 512)
        r.noteBridge(hostID: "nowhere", [hello, set("a", .working, 1)])
        #expect(r.linkSessions["nowhere"] == nil)
    }
}

/// `BridgeLink` against real child processes.
@MainActor
struct BridgeLinkTests {
    @MainActor final class Log {
        var msgs: [BridgeMsg] = []
        var downs = 0
    }
    private func wait(_ what: String, _ cond: @MainActor () -> Bool) async throws {
        for _ in 0..<300 { if cond() { return }; try await Task.sleep(for: .milliseconds(10)) }
        Issue.record("timed out waiting for \(what)")
    }
    private func make(_ script: String, _ log: Log) -> BridgeLink {
        BridgeLink(argv: ["/bin/sh", "-c", script], label: "test",
                   deliver: { log.msgs += $0 }, down: { log.downs += 1 })
    }

    @Test func linesArriveInOrderAndJunkIsSkipped() async throws {
        let log = Log()
        let l = make(#"""
            printf '{"t":"hello","proto":1,"bridge":"x"}\nnot json\n{"t":"del","na'
            sleep 0.1
            printf 'me":"a"}\n{"t":"later"}\n{"t":"ready"}\n'
            cat >/dev/null
            """#, log)
        l.start()
        try await wait("ready") { log.msgs.contains(.ready) }
        #expect(log.msgs == [.hello(proto: 1, bridge: "x"), .del(name: "a"), .ready])
        #expect(l.phase == .live && log.downs == 0)
        l.stop()
    }

    @Test func stoppingHangsUpAndTheChildGoes() async throws {
        let log = Log()
        let mark = "/tmp/zf-link-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: mark) }
        // `cat` returns when stdin closes, which is how a real bridge is told to leave.
        let l = make(#"printf '{"t":"ready"}\n'; cat >/dev/null; : > "\#(mark)""#, log)
        l.start()
        try await wait("ready") { l.phase == .live }
        l.stop()
        #expect(l.phase == .stopped)
        let before = log.msgs.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(log.msgs.count == before && log.downs == 0)      // we hung up: not an outage
    }

    @Test func aMissingBridgeIsAbsentNotRetriedHot() async throws {
        let log = Log()
        let l = BridgeLink(argv: ["/nonexistent/zmx-bridge", "--stdio"], label: "test",
                           deliver: { log.msgs += $0 }, down: { log.downs += 1 })
        l.start()
        try await wait("absent") { l.phase == .absent }
        #expect(log.msgs.isEmpty)
        l.stop()
        for status in [2, 64, 127] {
            let r = make("exit \(status)", log)
            r.start()
            try await wait("absent on \(status)") { r.phase == .absent }
            r.stop()
        }
    }

    @Test func aDroppedConnectionIsReportedAndRetried() async throws {
        let log = Log()
        let l = make(#"printf '{"t":"hello","proto":1}\n{"t":"ready"}\n'; exit 255"#, log)
        l.start()
        try await wait("down") { log.downs >= 1 }
        #expect(log.msgs.contains(.ready))                       // last lines land before `down`
        try await wait("a second connection") { log.msgs.filter { $0 == .ready }.count >= 2 }
        l.stop()
    }

    @Test func aProtocolFromTheFutureIsAbsent() async throws {
        let log = Log()
        let l = make(#"printf '{"t":"hello","proto":2}\n{"t":"ready"}\n'; cat >/dev/null"#, log)
        l.start()
        try await wait("absent") { l.phase == .absent }
        #expect(log.msgs.isEmpty && log.downs == 1)
        l.stop()
    }

    @Test func aLineWithNoEndIsCutOff() async throws {
        let log = Log()
        let l = make("yes x | tr -d '\\n'", log)
        l.start()
        try await wait("down") { log.downs >= 1 }
        #expect(log.msgs.isEmpty)
        l.stop()
    }

    /// The real bridge over a real patched daemon, in a throwaway socket dir:
    /// `TEST_RUNNER_FORK_BRIDGE_BIN=<dir holding zmx and zmx-bridge>`.
    static let bin = ProcessInfo.processInfo.environment["FORK_BRIDGE_BIN"]

    @Test(.enabled(if: BridgeLinkTests.bin != nil))
    func theRealThing() async throws {
        let bin = Self.bin!, dir = "/tmp/zf-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let env = ["-u", "ZMX_SESSION", "-u", "ZMX_SESSION_PREFIX", "ZMX_DIR=\(dir)"]
        defer {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = env + ["\(bin)/zmx", "kill", "*"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            try? FileManager.default.removeItem(atPath: dir)
            try? FileManager.default.removeItem(atPath: dir + ".facts")
        }
        let r = SessionRegistry.isolatedForTesting()
        let t = r.newTab(on: "local", title: "real")
        let ref = SessionRef(hostID: "local", name: "real")
        r.setPersistedTree(.empty.appending(leaf: ref), for: t.id)
        let l = BridgeLink(argv: env + ["\(bin)/zmx-bridge", "--stdio"], label: "real",
                           deliver: { r.noteBridge(hostID: "local", $0) },
                           down: { r.noteBridgeDown(hostID: "local") })
        l.start()
        try await wait("live") { l.phase == .live }

        let script = dir + "/agent.sh"
        try #"""
            printf '\033]7501;state=working:app=demo:msg=aGVsbG8=\033\\'; sleep 0.4
            printf '\033]7501;state=blocked:kind=permission:msg=UnVuIGl0Pw==\033\\'; sleep 0.4
            printf '\033]7501;state=done\033\\'; sleep 30
            """#.write(toFile: script, atomically: true, encoding: .utf8)
        _ = try await ZmxAdapter.run(argv: env + ["\(bin)/zmx", "run", "local-real", "-d", "bash", script], timeout: 10)
        try await wait("working") { r.dot(ref: ref) == .working }
        try await wait("blocked") { r.dot(ref: ref) == .blocked }
        r.publishCC("local")
        #expect(r.ccLive["local"]?["real"]?.attention == "Run it?")
        try await wait("done") { r.dot(ref: ref) == .waiting }
        _ = try await ZmxAdapter.run(argv: env + ["\(bin)/zmx", "kill", "local-real"], timeout: 10)
        try await wait("gone") { r.dot(ref: ref) == nil && r.linkSessions["local"]?["local-real"] == nil }
        l.stop()
    }
}
#endif
