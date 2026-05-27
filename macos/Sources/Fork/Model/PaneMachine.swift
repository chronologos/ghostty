#if os(macOS)
import Foundation

/// Per-session status reducer. The five scattered status dicts
/// (`paneState`/`lastWorkingAt`/`watchedSurfaces`/`ccBlockedSince`/`notifiedSurfaces`)
/// collapsed into one value type keyed on `SessionRef`. Event-arrival order on
/// `@MainActor` *is* the ordering — `.progress` clears `blocked`, a fresh `.probe`
/// edge sets it — so the Date-watermark machinery (and its four bugs) goes away.
struct PaneMachine: Equatable {
    enum Phase: Equatable { case idle, working, waiting }
    /// Probe classifier fingerprint — only `tempo`/`needs`, not `status`/`cwd`/etc
    /// (those churn while `tempo` is stale-stuck and would re-edge spuriously).
    struct Sig: Hashable { var tempo, needs: String? }

    var phase: Phase = .idle
    var watched  = false   // ⌘⌥A one-shot
    var notified = false   // banner-until-viewed gate
    var blocked  = false   // probe `tempo` says so AND no `.progress`/`busy` since AND not `.viewed`
    var ccBusy   = false   // probe `status == "busy"` — fresher than `tempo`, masks `blocked`
                           // the same way OSC `.progress` does (so a stale `tempo` can't
                           // contradict a live `status` — the dot-vs-rail conflict)
    var blockSig: Sig?     // last classifier — survives `.viewed` so an unchanged
                           // probe doesn't re-edge after the user's looked
    var probeMissed = false // 2-strike for `.probeAbsent` (torn pid-file vs CC-exit)

    /// What the sidebar rail / `rollup` read. (The dock badge reads `phase`/`ccBusy`
    /// directly — `dot` demotes `.waiting` to `.blocked`, which would drop a
    /// needs-input pane from the count.)
    var dot: PaneState? {
        phase == .working || ccBusy ? .working
            : blocked ? .blocked
            : phase == .waiting ? .waiting : nil
    }

    /// Returns `true` ⇒ caller should `ForkNotify.post`.
    @discardableResult
    mutating func apply(_ e: PaneEvent) -> Bool {
        switch e {
        case .progress:
            phase = .working; blocked = false
        case .settled(let isActive):
            // Banner: explicit watch always; otherwise first time a *background* pane
            // settles since last viewed. Active-tab settle just goes idle.
            let fire = watched || (!isActive && !notified)
            if watched { watched = false }
            phase = isActive ? .idle : .waiting
            if fire, !isActive { notified = true }
            return fire
        case .bell:
            defer { watched = false }
            // A posted bell counts as "the user was told" — otherwise the 250ms settle that
            // usually follows a completion bell posts a second banner for the same event.
            if watched { notified = true }
            return watched
        case .viewed:
            // Preserve `.working` — old `clearWaiting` only touched `.waiting`. Clobbering
            // it would (a) flicker the spinner on click and (b) break the settle gate
            // (`observeProgress` only arms the timer when `phase == .working`).
            if phase == .waiting { phase = .idle }
            blocked = false; notified = false
        case .watch(let on):
            watched = on
        case .probe(let isBlocked, let busy, let sig):
            probeMissed = false; ccBusy = busy
            if !isBlocked || busy { blocked = false }
            else if sig != blockSig { blocked = true }   // edge: new classifier output
            blockSig = isBlocked ? sig : nil
        case .probeStopped:
            // Poll torn down (showCC off / host removed / unreachable tick). `blocked`
            // survives — it has other clear paths (`.viewed`/`.progress`) — but `ccBusy`'s
            // only writer is the poll, and a pending `.probeAbsent` strike is no longer
            // "consecutive" once the poll was interrupted, so it resets too.
            ccBusy = false; probeMissed = false
        case .probeAbsent:
            // Key not in this tick's `result`. First miss = gap (torn pid-file / CC
            // restart) — keep the latch. Second consecutive miss = CC exited — clear so
            // a dead session's red dot doesn't persist.
            if probeMissed { blocked = false; blockSig = nil }
            probeMissed = true; ccBusy = false
        case .detached:
            // Last surface gone. Only `phase` is OSC-derived (stale without a surface);
            // `watched`/`notified` are user-intent and `blocked`/`blockSig` are
            // probe-derived — all survive ⌘W→⌘Z.
            phase = .idle
        }
        return false
    }
}

enum PaneEvent {
    case progress                     // OSC 9;4 non-nil
    case settled(isActive: Bool)      // 250ms after nil (or upstream's 15s auto-nil)
    case bell                         // BEL / OSC 133;D
    case viewed                       // `activate(tab:)`
    case watch(Bool)                  // ⌘⌥A
    case probe(blocked: Bool, busy: Bool, sig: PaneMachine.Sig)
    case probeAbsent                  // ref in-tree but not in this tick's `result`
    case probeStopped                 // poll cancelled — clear probe-derived transients
    case detached                     // last surface for this ref unobserved
}
#endif
