#if os(macOS)
import Foundation
import Testing
@testable import Ghostty

/// State-transition + commit-routing invariants for the new-session palette
/// reducer. `backResetsSel_evenWhenQueryAlreadyEmpty` is the PR54 live-bug
/// repro that motivated the extraction.
struct NewSessionMachineTests {
    private let local = ForkHost.local
    private let remote = ForkHost(id: "h2", label: "kaya", transport: .local)
    private var all: [ForkHost] { [local, remote] }

    private func entry(_ name: String, ext: Bool = false) -> ZmxAdapter.ListEntry {
        .init(name: name, clients: 0, created: .distantPast, external: ext, pid: nil)
    }
    private func machine(locked: Bool = false) -> NewSessionMachine {
        .init(host: local, locked: locked, placeholder: "auto-xyz")
    }

    // MARK: stage / sel

    @Test func unlockedStartsAtHost_lockedStartsAtSession() {
        #expect(machine().stage == .host)
        #expect(machine(locked: true).stage == .session)
    }

    @Test func typingResetsSel() {
        var m = machine()
        m.preselect(in: all)
        m.move(1, in: all)
        #expect(m.sel == 1)
        m.query = "ka"
        #expect(m.sel == 0)
    }

    @Test func backResetsSel_evenWhenQueryAlreadyEmpty() {
        var m = machine()
        m.advance(to: remote)
        m.setRecents(.init(managed: [entry("a"), entry("b"), entry("c")], external: []))
        #expect(m.query == "")
        m.move(1, in: all); m.move(1, in: all); m.move(1, in: all)
        #expect(m.sel == 3)
        m.back()
        #expect(m.stage == .host)
        #expect(m.sel == 0)
    }

    @Test func advanceResetsEverything() {
        var m = machine()
        m.advance(to: remote)
        m.setRecents(.init(managed: [entry("a")], external: []))
        m.query = "x"
        m.back()
        m.move(1, in: all)
        m.advance(to: local)
        #expect(m.stage == .session && m.host == local)
        #expect(m.query == "" && m.sel == 0)
        #expect(m.recents == nil && !m.unreachable)
    }

    @Test func backIsNoopWhenLocked() {
        var m = machine(locked: true)
        m.back()
        #expect(m.stage == .session)
    }

    @Test func moveClampsAndOffsetsSessionByOne() {
        var m = machine()
        for _ in 0..<5 { m.move(1, in: all) }
        #expect(m.sel == all.count - 1)
        m.advance(to: local)
        m.setRecents(.init(managed: [entry("a"), entry("b")], external: [entry("c", ext: true)]))
        for _ in 0..<5 { m.move(1, in: all) }
        #expect(m.sel == 3)  // 3 sessions + create slot 0 → max 3
    }

    // MARK: filtering / setRecents

    @Test func hostsFilterByLabel() {
        var m = machine()
        #expect(m.hosts(in: all).count == 2)
        m.query = "kay"
        #expect(m.hosts(in: all) == [remote])
    }

    @Test func setRecentsNilMeansUnreachable() {
        var m = machine(locked: true)
        m.setRecents(nil)
        #expect(m.unreachable)
        #expect(m.recents != nil)  // empty result, not nil — list renders as empty
    }

    // MARK: canSmartJump

    @Test func canSmartJump_eachGate() {
        var m = machine(locked: true)
        m.query = "fresh"
        #expect(!m.canSmartJump)                                 // recents not loaded
        m.setRecents(.init(managed: [entry("freshly")], external: []))
        #expect(m.canSmartJump)                                  // all gates pass
        m.move(1, in: all)
        #expect(m.sel == 1 && !m.canSmartJump)                   // row selected
        m.query = "freshly"
        #expect(!m.canSmartJump)                                 // name exists
        m.query = "bad name"
        #expect(!m.canSmartJump)                                 // invalid
        m.query = ""
        #expect(!m.canSmartJump)                                 // empty
    }

    // MARK: commit routing

    @Test func commitHostStageAdvances() {
        var m = machine()
        m.move(1, in: all)
        #expect(m.commit(shift: false, in: all) == .none)
        #expect(m.stage == .session && m.host == remote)
    }

    @Test func commitAttachesSelectedRow_winsOverShift() {
        var m = machine(locked: true)
        m.setRecents(.init(managed: [entry("a"), entry("b")], external: []))
        m.move(1, in: all)
        #expect(m.commit(shift: true, in: all) == .attach(name: "a", external: false))
    }

    @Test func commitShiftBeepsWhenIneligible() {
        var m = machine(locked: true)
        // recents not loaded → ineligible
        m.query = "fresh"
        #expect(m.commit(shift: true, in: all) == .beep)
    }

    @Test func commitShiftSmartJumps() {
        var m = machine(locked: true)
        m.setRecents(.init())
        m.query = "proj"
        #expect(m.commit(shift: true, in: all) == .create(name: "proj", smartJump: true))
    }

    @Test func commitCreatesPlaceholderWhenEmpty() {
        var m = machine(locked: true)
        m.setRecents(.init())
        #expect(m.commit(shift: false, in: all) == .create(name: "auto-xyz", smartJump: false))
    }

    @Test func commitInvalidNameNoop() {
        var m = machine(locked: true)
        m.setRecents(.init())
        m.query = "bad/name"
        #expect(m.commit(shift: false, in: all) == .none)
    }
}
#endif
