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

    /// A moment in one zmx daemon's life. `seq` counts that daemon's changes; `born` puts a
    /// restart under the same name after everything the old daemon said.
    struct Stamp: Comparable, Hashable, Codable {
        var born: UInt64
        var seq: UInt64
        static func < (l: Self, r: Self) -> Bool { (l.born, l.seq) < (r.born, r.seq) }
    }
    /// What the session's own daemon says the program in it is doing (`BridgeLink`). Needs no
    /// surface and no poll, so it holds for cold and detached rows too.
    struct Link: Equatable {
        enum State: Equatable { case idle, done, working, error, blocked }
        var state: State
        /// The program never said this: it drew an OSC 9;4 progress bar and the bridge read
        /// `working` / `done` into that. One more witness, not the last word.
        var inferred: Bool
        var stamp: Stamp
    }
    var link: Link?
    /// The newest `link` the user has looked at. Unread is `link.stamp > seen`: nobody clears
    /// anything, so there is no clear to lose. Outlives the run (`SessionRegistry.linkSeen`).
    var seen: Stamp?
    /// The newest finish a banner was already decided for, either way. Survives `link` going
    /// nil, so a reconnect that repeats old news stays quiet.
    var told: Stamp?

    private var unseen: Bool {
        guard let link else { return false }
        return seen.map { $0 < link.stamp } ?? true
    }

    /// What the sidebar rail / `rollup` read. (The dock badge reads `needsYou` — `dot`
    /// collapses waiting+blocked into one "needs me most" precedence for rendering, while
    /// the badge counts *both* states, so it can't read this projection.)
    var dot: PaneState? {
        // The program speaks for itself, so nothing else gets a say. It has to be this blunt:
        // CC leaves its progress bar up while it waits on a question, and `phase == .working`
        // would hide the one state that most needs showing.
        if let link, !link.inferred {
            switch link.state {
            case .working: return .working
            case .blocked: return unseen ? .blocked : nil
            case .error:   return unseen ? .failed : nil
            case .done:    return unseen ? .waiting : nil
            case .idle:    return nil
            }
        }
        return phase == .working || ccBusy || link?.state == .working ? .working
            : blocked ? .blocked
            : link?.state == .error && unseen ? .failed
            : phase == .waiting || (link?.state == .done && unseen) ? .waiting : nil
    }

    /// The dock badge's question: is this pane waiting on the user?
    var needsYou: Bool {
        if let link, !link.inferred { return unseen && link.state != .working && link.state != .idle }
        let finished = unseen && (link?.state == .done || link?.state == .error)
        return (phase == .waiting || blocked || finished) && !ccBusy && link?.state != .working
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
        case .bell(let isActive):
            // An active-pane bell is interaction noise (readline/vim beeps under the user's
            // own typing), not a completion signal: don't consume the ⌘⌥A watch, don't
            // latch `notified`, don't banner. Counting it as "the user was told" was the
            // PR43 bell-latch trade-off — a stray beep in the pane you're working in would
            // silently swallow the banner for a completion that happened much later.
            guard !isActive else { return false }
            defer { watched = false }
            // A posted *background* bell still counts as "the user was told" — otherwise the
            // 250ms settle that usually follows a completion bell posts a second banner for
            // the same event.
            if watched { notified = true }
            return watched
        case .viewed:
            // Preserve `.working` — old `clearWaiting` only touched `.waiting`. Clobbering
            // it would (a) flicker the spinner on click and (b) break the settle gate
            // (`observeProgress` only arms the timer when `phase == .working`).
            if phase == .waiting { phase = .idle }
            blocked = false; notified = false
            if let link { seen = link.stamp }
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
            // probe-derived — all survive ⌘W→⌘Z. So does `link`: the daemon is still there.
            phase = .idle
        case .link(let new, let isActive, let quiet):
            link = new
            guard let new, new.state == .done || new.state == .error else { return false }
            // In the visible tab a finish is read as it lands, like an active `.settled`.
            // (`blocked` is not: a question in one split of four is easy to miss, so its
            // lamp waits for `.viewed` or for the program to move on.)
            if isActive { seen = max(seen ?? new.stamp, new.stamp) }
            guard told.map({ $0 < new.stamp }) ?? true else { return false }
            told = new.stamp
            // `quiet`: the first look at a host after launch. Everything that finished while
            // the app was closed lights its lamp; none of it is worth a banner each.
            guard !quiet, unseen || watched else { return false }
            // From here, `.settled`'s rule, sharing `notified` with it: an attached pane
            // reports the same finish down both paths and must banner once.
            let fire = watched || (!isActive && !notified)
            if watched { watched = false }
            if fire, !isActive { notified = true }
            return fire
        }
        return false
    }
}

enum PaneEvent {
    case progress                     // OSC 9;4 non-nil
    case settled(isActive: Bool)      // 250ms after nil (or upstream's 15s auto-nil)
    case bell(isActive: Bool)         // BEL / OSC 133;D — isActive: pane is in the visible tab
    case viewed                       // `activate(tab:)`
    case watch(Bool)                  // ⌘⌥A
    case probe(blocked: Bool, busy: Bool, sig: PaneMachine.Sig)
    case probeAbsent                  // ref in-tree but not in this tick's `result`
    case probeStopped                 // poll cancelled — clear probe-derived transients
    case detached                     // last surface for this ref unobserved
    /// The bridge's word on this session; nil = it has none (or the link is down).
    case link(PaneMachine.Link?, isActive: Bool, quiet: Bool)
}
#endif
