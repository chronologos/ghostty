#if os(macOS)
import Foundation

/// Per-`SessionRef` reducer for the pane-alias cache ⇄ daemon-label protocol (the
/// `SessionRegistry.syncAliases` driver feeds it one `zmx list` observation per poll and
/// the result of every `zmx set`; the tests drive it directly). The alias's source of truth
/// is the daemon-side session label `ghostty_name`; `paneLabels[ref.key]` is its cache. A few
/// facts turn "copy daemon → cache" into a state machine instead of a one-liner:
///
/// - **`zmx list` can't tell you whether a daemon supports labels.** A pre-label daemon and
///   a new one with no label print identical rows. So `capable` is *earned*: only a daemon
///   that has reported a label, or Ack'd one of our writes (`noteLanded` — since zmx 0.7.0
///   `zmx set` exits 0 only on the daemon's Ack), is trusted to make a *missing* label
///   authoritative. Until then a missing label means "old daemon / not migrated" and the
///   cache stands — otherwise the first poll would wipe every pre-existing name. The proof
///   is persisted per incarnation (`TabModel.aliasProven`), so a clear made elsewhere while
///   the app was quit isn't undone by the next launch "migrating" the stale cache back up.
/// - **Session identity is `created` + pid, not the name.** zmx labels live in the session
///   daemon's memory; a killed-and-recreated session with the same id is a new, unlabeled
///   session. `created` alone has 1s resolution and zmx explicitly supports kill-then-
///   immediate-recreate, hence the pid. A new incarnation resets `capable`/`pushed` so the
///   cached name migrates onto it instead of being read as a clear.
/// - **One label-less row proves nothing.** `zmx list` asks each daemon for its labels as a
///   second message and waits only 50ms for the answer; a daemon busy with pty output is
///   printed without them. A clear is propagated only after two consecutive label-less
///   observations (the same two-strike shape as `PaneMachine`'s `.probeAbsent`).
struct AliasSync: Equatable {
    /// zmx `created` of the session the flags below describe. `nil` = never listed yet.
    private(set) var created: Date?
    private(set) var pid: Int32?
    /// The daemon has proven label-capable, so an *absent* label is an authoritative clear
    /// (propagate it) rather than "old daemon" (keep the cache).
    private(set) var capable = false
    /// A migration/seed write already went out for this session incarnation — never every
    /// tick (an old daemon fails it identically forever). Distinct from user renames, which
    /// always write.
    private(set) var pushed = false
    /// Failed writes since the last one that landed. Resets on success: a lifetime counter
    /// would let three unrelated ssh blips, days apart, permanently turn retries off — after
    /// which a failed rename silently reverts to the daemon's old label.
    private(set) var failures = 0
    /// The mask. Until the daemon echoes `sent` (the expected sanitized echo) — or a list
    /// fetched *after* the write's Ack arrives — the daemon's (stale) label must not
    /// overwrite the cache; that's how a just-renamed row would otherwise snap back for a
    /// poll cycle. `wire` is the original value the write carried (for a creation seed
    /// that's the id, though its expected echo is nil).
    private(set) var pending: Pending?
    struct Pending: Equatable {
        let sent: String?
        let wire: String?
        let at: Date
        /// When the daemon Ack'd. Any list fetched after this reflects the write.
        var landedAt: Date?
    }
    /// The write whose *result* hasn't come back. Separate from the mask on purpose: a
    /// write whose expected echo is nil (a seed, a clear) is "echoed" by the very next
    /// label-less row, which drops the mask — and a failure arriving after that used to
    /// find nothing to match its stamp against, so the seed was never retried.
    private(set) var inFlight: InFlight?
    struct InFlight: Equatable {
        let at: Date
        let wire: String?
        /// What the daemon was last seen reporting when this write was issued
        /// (`.none` = never observed).
        let liveAtIssue: String??
    }
    /// A failed write, queued to be re-sent. Retried ahead of daemon-wins so a rename that
    /// failed once (host blip, `MaxStartups`) isn't silently reverted by the daemon's old
    /// label on the next poll; bounded by `failures`. Dropped if the daemon's label has
    /// *changed* since the write was issued — that's a newer write from somewhere else
    /// (another Mac, an agent's `zmx set .`), and an older failed intent must not stomp it.
    private(set) var retry: Retry?
    struct Retry: Equatable {
        let wire: String?
        let liveAtIssue: String??
    }
    /// Consecutive label-less observations from a capable daemon while the cache holds a name.
    private(set) var absentStrikes = 0
    /// The previous observation's `live` (`.none` = never observed).
    private(set) var lastLive: String?? = .none

    /// Retries after failed writes, then give up.
    static let maxFailures = 3
    /// Label-less observations needed before a clear propagates.
    static let clearStrikes = 2

    init() {}

    /// Stable string for "this incarnation" — what `TabModel.aliasProven` stores.
    var incarnation: String? {
        created.map { "\(Int($0.timeIntervalSince1970))/\(pid.map { String($0) } ?? "")" }
    }

    enum Action: Equatable {
        case none
        /// Write the daemon's value into the cache (`nil` removes it — a propagated clear).
        case setCache(String?)
        /// Send `zmx set` carrying this value — the seed (the id itself), a cached label
        /// the daemon lacks, or a retry of a failed write.
        case push(String?)
    }

    /// One `zmx list` observation of this ref.
    /// - `live`: the sanitized daemon label (`nil` = none reported).
    /// - `cached`: `paneLabels[ref.key]`.
    /// - `seeded`: a typed name is queued for this brand-new session (label it with `id`).
    /// - `budget`: the driver's per-tick spawn budget still has room (gates every write).
    /// - `managed`: migration/seed writes are allowed for this ref (never unsolicited into
    ///   a foreign external session; retries of the user's own writes aren't gated on this).
    /// - `fetchedAt`: when the `zmx list` that produced `live` was *started*.
    /// - `proven`: the persisted `incarnation` this ref was last proven capable for.
    mutating func observe(created c: Date, pid p: Int32? = nil, live: String?, cached: String?,
                          seeded: Bool, id: String, budget: Bool, managed: Bool,
                          now: Date, ttl: TimeInterval,
                          fetchedAt: Date? = nil, proven: String? = nil) -> Action {
        defer { lastLive = .some(live) }
        let reborn = created != nil && (created != c || (pid != nil && p != nil && pid != p))
        if created == nil || reborn {                // first sighting, or a new incarnation
            // A *re*creation: any write in flight was for the old daemon (labels died
            // with it) — its mask must not stall this session's migration for a TTL. On
            // a *first* sighting the pending write is a rename made before the first
            // poll and must keep its mask (else the daemon's stale value clobbers it).
            if reborn { pending = nil; inFlight = nil; retry = nil }
            created = c; pid = p; pushed = false; failures = 0; absentStrikes = 0
            capable = proven != nil && proven == incarnation
        } else if pid == nil {
            pid = p
        }
        // A queued retry outranks daemon-wins: the daemon's current label is exactly the
        // stale value the failed write was trying to replace — unless it has moved since.
        if let r = retry {
            if case .some(let issued) = r.liveAtIssue, issued != live {
                retry = nil                          // someone else's newer write; it wins
            } else {
                guard budget else { return .none }   // stays queued for a later tick
                retry = nil
                pushed = true                        // this write covers the migration too
                return .push(r.wire)
            }
        }
        if let p = pending {
            // Echoed (daemon now reports what we sent), or this list was fetched after the
            // write's Ack → landed; expired → give up and let the daemon win. Until then
            // the daemon is presumed stale.
            let echoed = live == p.sent
            let postdatesAck = p.landedAt.flatMap { l in fetchedAt.map { $0 > l } } ?? false
            if echoed, p.sent != nil { failures = 0 }
            if echoed || postdatesAck || now.timeIntervalSince(p.at) > ttl { pending = nil }
            else { return .none }
        }
        if let live {
            capable = true
            absentStrikes = 0
            return cached == live ? .none : .setCache(live)
        }
        // No label reported.
        if capable {                                 // authoritative clear — on the 2nd strike
            guard cached != nil else { absentStrikes = 0; return .none }
            absentStrikes += 1
            guard absentStrikes >= Self.clearStrikes else { return .none }
            absentStrikes = 0
            return .setCache(nil)
        }
        guard !pushed, budget, managed else { return .none }
        // A cached name (an existing pane, or a rename typed before the session listed)
        // outranks the creation seed — the seed is just the id, i.e. the fallback.
        if let cached { pushed = true; return .push(cached) }
        if seeded { pushed = true; return .push(id) }
        return .none
    }

    /// A write (`zmx set`) went out at `at`, carrying `wire`, expecting the daemon to echo
    /// `sent`. Supersedes any queued retry — the newer value is what the user wants now.
    mutating func noteSent(sent: String?, wire: String?, at: Date) {
        pending = .init(sent: sent, wire: wire, at: at, landedAt: nil)
        inFlight = .init(at: at, wire: wire, liveAtIssue: lastLive)
        retry = nil
    }

    /// The write stamped `at` was Ack'd by the daemon. That is a capability proof, it
    /// clears the failure count, and it lets the mask release on the first list fetched
    /// after `now` instead of waiting out an echo or the TTL.
    mutating func noteLanded(at: Date, now: Date) {
        guard let f = inFlight, f.at == at else { return }
        inFlight = nil
        capable = true
        failures = 0
        if pending?.at == at { pending?.landedAt = now }
    }

    /// The write stamped `at` failed. Unmask now — no TTL wait — and queue that write's own
    /// value for a bounded number of retries. A stamp that no longer matches means a newer
    /// write superseded this one: an older failure must neither drop the newer mask nor
    /// resurrect a stale value. `permanent`: the daemon (or the zmx over there) doesn't do
    /// labels at all — retrying costs an ssh handshake plus zmx's 1s wait each time, for the
    /// same answer.
    mutating func noteFailed(at: Date, permanent: Bool = false) {
        guard let f = inFlight, f.at == at else { return }
        inFlight = nil
        if pending?.at == at { pending = nil }
        if permanent { failures = Self.maxFailures; return }
        if failures < Self.maxFailures {
            failures += 1
            retry = .init(wire: f.wire, liveAtIssue: f.liveAtIssue)
        }
    }
}
#endif
