#if os(macOS)
import Testing
@testable import Ghostty

struct PaneMachineTests {
    private let s1 = PaneMachine.Sig(tempo: "blocked", needs: "answer A")
    private let s2 = PaneMachine.Sig(tempo: "blocked", needs: "answer B")

    @Test func settledBackgroundPostsOnce() {
        var m = PaneMachine()
        m.apply(.progress)
        #expect(m.apply(.settled(isActive: false)) == true)
        #expect(m.dot == .waiting)
        m.apply(.progress)
        // Second settle without `.viewed` — gated.
        #expect(m.apply(.settled(isActive: false)) == false)
    }

    @Test func viewedResetsNotified() {
        var m = PaneMachine()
        m.apply(.progress); _ = m.apply(.settled(isActive: false))
        m.apply(.viewed)
        #expect(m.dot == nil)
        m.apply(.progress)
        #expect(m.apply(.settled(isActive: false)) == true)
    }

    @Test func settledActiveDoesNotPost() {
        var m = PaneMachine()
        m.apply(.progress)
        #expect(m.apply(.settled(isActive: true)) == false)
        #expect(m.dot == nil)
    }

    @Test func watchPostsOnActiveSettle() {
        var m = PaneMachine()
        m.apply(.watch(true)); m.apply(.progress)
        #expect(m.apply(.settled(isActive: true)) == true)
        #expect(m.watched == false)   // one-shot
    }

    @Test func bellOnlyPostsWhenWatched() {
        var m = PaneMachine()
        #expect(m.apply(.bell) == false)
        m.apply(.watch(true))
        #expect(m.apply(.bell) == true)
        #expect(m.watched == false)
    }

    /// The four-bug class: probe says blocked, OSC `.progress` arrives, probe says blocked
    /// again with the SAME sig — must stay unblocked. (Was: stale `tempo` outliving the
    /// reply because watermark Dates were cross-referenced.)
    @Test func progressClearsBlocked_sameSigDoesNotReblock() {
        var m = PaneMachine()
        m.apply(.probe(blocked: true, busy: false, sig: s1))
        #expect(m.dot == .blocked)
        m.apply(.progress)
        #expect(m.dot == .working)
        m.apply(.probe(blocked: true, busy: false, sig: s1))   // unchanged classifier
        #expect(m.blocked == false)
        _ = m.apply(.settled(isActive: false))
        #expect(m.dot == .waiting)                // not .blocked
    }

    /// Genuine `.probe(false)` (classifier rewrote `tempo`) clears `blockSig` so the
    /// SAME sig coming back IS a fresh edge. Transient probe gaps never reach this —
    /// `mergeCC` only emits `.probe` for keys present in `result`.
    @Test func genuineUnblockThenSameSigReblocks() {
        var m = PaneMachine()
        m.apply(.probe(blocked: true, busy: false, sig: s1)); m.apply(.viewed)
        m.apply(.probe(blocked: false, busy: false, sig: .init(tempo: "active", needs: nil)))
        #expect(m.blockSig == nil)
        m.apply(.probe(blocked: true, busy: false, sig: s1))
        #expect(m.dot == .blocked)
    }

    /// Ack: viewed clears blocked; same sig doesn't re-edge; new sig does.
    @Test func viewedAcksBlocked_newSigReblocks() {
        var m = PaneMachine()
        m.apply(.probe(blocked: true, busy: false, sig: s1))
        m.apply(.viewed)
        #expect(m.blocked == false)
        m.apply(.probe(blocked: true, busy: false, sig: s1))
        #expect(m.blocked == false)               // blockSig survived .viewed
        m.apply(.probe(blocked: true, busy: false, sig: s2))
        #expect(m.dot == .blocked)
    }

    @Test func detachedResetsPhaseOnly() {
        var m = PaneMachine()
        m.apply(.progress); _ = m.apply(.settled(isActive: false))   // → notified
        m.apply(.watch(true))                                        // re-armed
        m.apply(.probe(blocked: true, busy: false, sig: s1)); m.apply(.progress)  // → .working, blockSig
        m.apply(.detached)
        #expect(m.phase == .idle)
        #expect(m.watched && m.notified && m.blockSig == s1)   // ⌘W→⌘Z preserves
    }

    /// `.viewed` must NOT clobber `.working` — old `clearWaiting` only touched `.waiting`,
    /// and `observeProgress` gates the settle timer on `phase == .working`.
    @Test func viewedPreservesWorking() {
        var m = PaneMachine()
        m.apply(.progress); m.apply(.viewed)
        #expect(m.phase == .working)
        #expect(m.blocked == false && m.notified == false)   // those still clear
    }

    /// 2-strike absent: first miss = gap (latch kept), second = exit (clear).
    @Test func probeAbsentTwoStrike() {
        var m = PaneMachine()
        m.apply(.probe(blocked: true, busy: false, sig: s1)); m.apply(.viewed)
        m.apply(.probeAbsent)
        #expect(m.blockSig == s1)         // gap — survives
        m.apply(.probe(blocked: true, busy: false, sig: s1))
        #expect(m.blocked == false)       // ack held across the gap
        m.apply(.probeAbsent); m.apply(.probeAbsent)
        #expect(m.blockSig == nil && m.blocked == false)   // exit — cleared
    }

    @Test func dotPrecedence() {
        var m = PaneMachine()
        m.apply(.probe(blocked: true, busy: false, sig: s1))
        m.apply(.progress)
        #expect(m.dot == .working)      // working masks blocked (which .progress also cleared)
        _ = m.apply(.settled(isActive: false))
        #expect(m.dot == .waiting)
        m.apply(.probe(blocked: true, busy: false, sig: s2))
        #expect(m.dot == .blocked)      // blocked masks waiting
    }

    /// `status == "busy"` masks a stale `tempo == "blocked"` the same way OSC does — the
    /// dot-vs-rail conflict (red `.blocked` next to green busy-ring) closed by construction.
    @Test func ccBusyMasksBlocked() {
        var m = PaneMachine()
        m.apply(.probe(blocked: true, busy: true, sig: s1))
        #expect(m.dot == .working)
        #expect(m.blocked == false)     // busy clears the latch, not just the projection
        m.apply(.probe(blocked: true, busy: false, sig: s1))
        #expect(m.dot == nil)           // same sig → no re-edge; busy gone → not working
        m.apply(.probe(blocked: true, busy: false, sig: s2))
        #expect(m.dot == .blocked)      // genuine new question still reds
    }

    /// Toggling the probe off while busy must not wedge `.working` — `ccBusy`'s only
    /// writer is the poll, so `.probeStopped` is its only clear path. `blocked` survives.
    @Test func probeStoppedClearsBusyKeepsBlocked() {
        var m = PaneMachine()
        m.apply(.probe(blocked: true, busy: true, sig: s1))
        #expect(m.dot == .working)
        m.apply(.probeStopped)
        #expect(m.ccBusy == false && m.dot != .working)
        var b = PaneMachine()
        b.apply(.probe(blocked: true, busy: false, sig: s1))
        b.apply(.probeStopped)
        #expect(b.dot == .blocked)      // blocked latch survives poll teardown
    }

    /// A watched pane that rings BEL at completion must not double-banner: the bell post
    /// counts as "told", so the trailing 250ms settle is gated like any already-notified one.
    @Test func bellThenSettlePostsOnce() {
        var m = PaneMachine()
        m.apply(.watch(true)); m.apply(.progress)
        #expect(m.apply(.bell) == true)
        #expect(m.apply(.settled(isActive: false)) == false)
        #expect(m.dot == .waiting)
    }

    /// `.probeStopped` interrupts the 2-strike count — a miss before and a miss after a
    /// poll gap are not "consecutive", so the blocked latch must survive them.
    @Test func probeStoppedResetsAbsentStrike() {
        var m = PaneMachine()
        m.apply(.probe(blocked: true, busy: false, sig: s1))
        m.apply(.probeAbsent)          // strike 1
        m.apply(.probeStopped)         // poll gap
        m.apply(.probeAbsent)          // not a second consecutive strike
        #expect(m.blocked == true && m.blockSig == s1)
    }

    /// `phase==.waiting && ccBusy` must not double-report: the rail (driven by `dot`) says
    /// working, and the dock badge separately counts `phase == .waiting && !ccBusy` — both
    /// must agree that a busy pane isn't "needs you".
    @Test func dotWaitingExcludesBusy() {
        var m = PaneMachine()
        m.apply(.progress); _ = m.apply(.settled(isActive: false))
        #expect(m.dot == .waiting)
        m.apply(.probe(blocked: false, busy: true, sig: .init(tempo: nil, needs: nil)))
        #expect(m.phase == .waiting && m.dot == .working)
    }
}
#endif
