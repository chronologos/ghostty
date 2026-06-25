#if os(macOS)
import Testing
@testable import Ghostty

/// State-transition invariants for the new-session palette reducer —
/// `backResetsSel_evenWhenQueryAlreadyEmpty` is the PR54 live-bug repro that
/// motivated the extraction.
struct NewSessionMachineTests {
    private let local = ForkHost.local
    private let remote = ForkHost(id: "h2", label: "kaya", transport: .local)

    @Test func unlockedStartsAtHost_lockedStartsAtSession() {
        #expect(NewSessionMachine(host: local, locked: false).stage == .host)
        #expect(NewSessionMachine(host: local, locked: true).stage == .session)
    }

    @Test func typingResetsSel() {
        var m = NewSessionMachine(host: local, locked: false)
        m.preselect(hostIndex: 3)
        #expect(m.sel == 3)
        m.query = "ka"
        #expect(m.sel == 0)
    }

    /// PR54 live bug: ⌫ on an empty field backed out without resetting sel,
    /// because the prior fix leaned on `onChange(of: query)` which doesn't fire
    /// when query was already "".
    @Test func backResetsSel_evenWhenQueryAlreadyEmpty() {
        var m = NewSessionMachine(host: local, locked: false)
        m.advance(to: remote)
        #expect(m.query == "")
        m.move(1, count: 5); m.move(1, count: 5); m.move(1, count: 5)
        #expect(m.sel == 3)
        m.back()
        #expect(m.stage == .host)
        #expect(m.sel == 0)
    }

    @Test func advanceResetsQueryAndSel() {
        var m = NewSessionMachine(host: local, locked: false)
        m.query = "ka"
        m.move(1, count: 4); m.move(1, count: 4)
        #expect(m.sel == 2)
        m.advance(to: remote)
        #expect(m.stage == .session)
        #expect(m.host == remote)
        #expect(m.query == "")
        #expect(m.sel == 0)
    }

    @Test func backIsNoopWhenLocked() {
        var m = NewSessionMachine(host: remote, locked: true)
        m.back()
        #expect(m.stage == .session)
    }

    @Test func moveClampsAndOffsetsSessionByOne() {
        var m = NewSessionMachine(host: local, locked: false)
        // host stage: count=3 → sel ∈ [0,2]
        m.move(1, count: 3); m.move(1, count: 3); m.move(1, count: 3); m.move(1, count: 3)
        #expect(m.sel == 2)
        m.move(-9, count: 3)
        #expect(m.sel == 0)
        // session stage: count=3 → +1 create slot → sel ∈ [0,3]
        m.advance(to: local)
        m.move(1, count: 3); m.move(1, count: 3); m.move(1, count: 3); m.move(1, count: 3)
        #expect(m.sel == 3)
    }

    @Test func moveOnEmptyListIsNoop() {
        var m = NewSessionMachine(host: local, locked: false)
        m.move(1, count: 0)
        #expect(m.sel == 0)
        m.advance(to: local)
        // session stage with 0 sessions still has the create slot
        m.move(1, count: 0)
        #expect(m.sel == 0)
    }

    @Test func nameValid() {
        var m = NewSessionMachine(host: local, locked: true)
        #expect(m.nameValid)           // empty ok
        m.query = "good-name_1.2"
        #expect(m.nameValid)
        m.query = "bad name"
        #expect(!m.nameValid)
        m.query = "bad/name"
        #expect(!m.nameValid)
    }

    @Test func preselectIgnoredOutsideHostStage() {
        var m = NewSessionMachine(host: local, locked: true)
        m.preselect(hostIndex: 4)
        #expect(m.sel == 0)
    }
}
#endif
