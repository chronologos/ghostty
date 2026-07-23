#if os(macOS)
import Foundation

/// Per-`SessionRef` reducer for the pane-alias cache ⇄ daemon-label protocol (the
/// `SessionRegistry.syncAliases` driver feeds it one `zmx list` observation per poll; the
/// tests drive it directly). The alias's source of truth is the daemon-side session label
/// `ghostty_name`; `paneLabels[ref.key]` is its cache. Two facts turn "copy daemon → cache"
/// into a state machine instead of a one-liner:
///
/// - **We can't ask a daemon whether it supports labels.** A pre-label zmx daemon and a new
///   one with no label print identical `zmx list` lines, and `zmx set` exits 0 either way. So
///   `capable` is *earned*: only a daemon that has reported a label (or echoed our write) is
///   trusted to make a *missing* label authoritative. Until then a missing label means "old
///   daemon / not migrated" and the cache stands — otherwise the first poll would wipe every
///   pre-existing name.
/// - **Session identity is `created`, not the name.** zmx labels live in the session
///   daemon's memory; a killed-and-recreated session with the same id is a new, unlabeled
///   session. A changed `created` resets `capable`/`pushed` so the cached name migrates onto
///   the new incarnation instead of being read as a clear.
struct AliasSync: Equatable {
    /// zmx `created` of the session the flags below describe. `nil` = never listed yet.
    private(set) var created: Date?
    /// The daemon has proven label-capable, so an *absent* label is an authoritative clear
    /// (propagate it) rather than "old daemon" (keep the cache).
    private(set) var capable = false
    /// A migration/seed write already went out for this session incarnation — never every
    /// tick (an old daemon silently ignores it forever). Distinct from user renames, which
    /// always write.
    private(set) var pushed = false
    private(set) var failures = 0
    /// The write in flight. Until the daemon echoes `sent` (the expected sanitized echo), the
    /// daemon's (stale) label must not overwrite the cache — that's how a just-renamed row
    /// would otherwise snap back for a poll cycle. `wire` is the original value the write
    /// carried (what a retry must re-send: for a creation seed that's the id, though its
    /// expected echo is nil).
    private(set) var pending: Pending?
    struct Pending: Equatable { let sent: String?; let wire: String?; let at: Date }
    /// A failed write's value, queued to be re-sent. Retried ahead of daemon-wins so a
    /// rename that failed once (host blip, `MaxStartups`) isn't silently reverted by the
    /// daemon's old label on the next poll; bounded by `failures`.
    private(set) var retryWire: String?? = nil

    /// Retries after failed writes, then give up (an old daemon fails identically forever).
    static let maxFailures = 3

    init() {}

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
    mutating func observe(created c: Date, live: String?, cached: String?,
                          seeded: Bool, id: String, budget: Bool, managed: Bool,
                          now: Date, ttl: TimeInterval) -> Action {
        if created != c {                        // first sighting, or a new incarnation
            // A *re*creation: any write in flight was for the old daemon (labels died
            // with it) — its mask must not stall this session's migration for a TTL. On
            // a *first* sighting the pending write is a rename made before the first
            // poll and must keep its mask (else the daemon's stale value clobbers it).
            if created != nil { pending = nil; retryWire = nil }
            created = c; capable = false; pushed = false; failures = 0
        }
        // A queued retry outranks daemon-wins: the daemon's current label is exactly the
        // stale value the failed write was trying to replace.
        if let wire = retryWire {
            guard budget else { return .none }       // stays queued for a later tick
            retryWire = nil
            pushed = true                              // this write covers the migration too
            return .push(wire)
        }
        if let p = pending {
            // Echoed (daemon now reports what we sent) → landed; expired → give up and let
            // the daemon win. Until then the daemon is presumed stale.
            if live == p.sent || now.timeIntervalSince(p.at) > ttl { pending = nil }
            else { return .none }
        }
        if let live {
            capable = true
            return cached == live ? .none : .setCache(live)
        }
        // No label reported.
        if capable { return cached == nil ? .none : .setCache(nil) }   // authoritative clear
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
        pending = .init(sent: sent, wire: wire, at: at)
        retryWire = nil
    }

    /// The write stamped `at` failed (old zmx, unreachable host, session not created yet).
    /// Unmask now — no TTL wait — and queue that write's own value for a bounded number
    /// of retries. A stamp that no longer matches means a newer write superseded this
    /// one: an older failure must neither drop the newer mask nor resurrect a stale value.
    mutating func noteFailed(at: Date) {
        guard let p = pending, p.at == at else { return }
        pending = nil
        if failures < Self.maxFailures {
            failures += 1
            retryWire = .some(p.wire)
        }
    }
}
#endif
