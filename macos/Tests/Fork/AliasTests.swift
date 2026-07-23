#if os(macOS)
import Foundation
import Testing
@testable import Ghostty

/// Pane display alias = the daemon-side zmx `ghostty_name` label; `paneLabels` is its
/// write-through cache. Covers the escape codec, the `zmx list` label parse (a trust
/// boundary), the per-ref `AliasSync` reducer, and the registry driver around it.
struct AliasCodecTests {
    @Test func passthroughCharsetIsUnchanged() {
        #expect(AliasCodec.encode("code-review.v2") == "code-review.v2")
    }

    @Test func escapesEverythingOutsideTheZmxCharset() {
        // Space and `_` (the escape prefix itself) both escape; the result stays inside
        // zmx's `[A-Za-z0-9._-]` so `assertLabel` can never reject it.
        let enc = AliasCodec.encode("code review_🔥")
        #expect(enc == "code_20review_5F_F0_9F_94_A5")
        #expect(enc.utf8.allSatisfy { c in
            let s = Character(Unicode.Scalar(c))
            return s.isLetter || s.isNumber || s == "." || s == "-" || s == "_"
        })
        #expect(AliasCodec.decode(enc[...]) == "code review_🔥")
    }

    @Test func encodeCapsBeforeItBecomesAnArgvToken() {
        // A pasted wall of text must not become a multi-KB `zmx set` token on the wire.
        #expect(AliasCodec.encode(String(repeating: "x", count: 500)).count == AliasCodec.cap)
    }

    @Test func decodeIsLenientForHandSetLabels() {
        // `zmx set . ghostty_name=my_thing` — a `_` not followed by two hex digits is
        // literal, so CLI-set labels don't get mangled by our escape scheme.
        #expect(AliasCodec.decode("my_thing") == "my_thing")
        #expect(AliasCodec.decode("trailing_") == "trailing_")
        #expect(AliasCodec.decode("a_2Gz") == "a_2Gz")   // G isn't hex → literal
        #expect(AliasCodec.decode("ab_2") == "ab_2")     // truncated escape at end → literal
        #expect(AliasCodec.decode("_6a") == "j")         // lowercase hex accepted
    }

    @Test func aliasRejectsRawValuesOutsideTheWireCharset() {
        // zmx's daemon stores IPC-set label bytes verbatim (only the CLI validates), and a
        // separator byte in a value can forge whole `zmx list` rows. A raw value with any
        // byte our codec would never emit didn't come from a legitimate `zmx set` — reject.
        #expect(AliasCodec.alias(from: "has space") == nil)
        #expect(AliasCodec.alias(from: "tab\there") == nil)
        #expect(AliasCodec.alias(from: "utf8_é") == nil)
        #expect(AliasCodec.alias(from: "ok_2Dvalue") == "ok-value")
    }

    @Test func aliasStripsControlsFormatCharsAndDropsEmpty() {
        // Escape chars and bidi/format scalars (an alias is a *primary* identity — it must
        // not visually reorder or hide the id beside it) never reach the UI; blank → nil.
        #expect(AliasCodec.alias(from: AliasCodec.encode("bad\u{1B}[2Jname")[...]) == "bad[2Jname")
        #expect(AliasCodec.alias(from: AliasCodec.encode("evil\u{202E}live")[...]) == "evillive")
        #expect(AliasCodec.alias(from: "") == nil)
        #expect(AliasCodec.alias(from: nil) == nil)
        #expect(AliasCodec.alias(from: AliasCodec.encode("   ")[...]) == nil)
        #expect(AliasCodec.sanitize(String(repeating: "x", count: 100))?.count == AliasCodec.cap)
    }

    @Test func parseReadsGhosttyNameLabel() {
        let line = "name=dev\tpid=1\tclients=0\tcreated=1700000000\tenv=prod\tghostty_name=my_20api"
        #expect(ZmxAdapter.parse(line: line[...])?.alias == "my api")
        #expect(ZmxAdapter.parse(line: "name=dev\tclients=0\tcreated=1700000000"[...])?.alias == nil)
    }

    @Test func labelsCannotShadowBuiltinFields() {
        // zmx only reserves name/start_dir/cmd — anyone on the host can `zmx set foo err=x`
        // or `clients=9`. First occurrence wins, so labels (emitted after the built-ins)
        // can neither hide a session behind a fake `err=` nor corrupt its fields.
        let evil = "name=dev\tpid=1\tclients=2\tcreated=1700000000\terr=fake\tclients=99\tname=x"
        let e = ZmxAdapter.parse(line: evil[...])
        #expect(e != nil)                 // fake err= didn't drop the row
        #expect(e?.name == "dev")
        #expect(e?.clients == 2)
    }

    @Test func partitionCarriesAliasThroughBothPartitions() {
        let out = """
            name=h1-acr\tpid=1\tclients=0\tcreated=1700000000\tghostty_name=Alpha
            name=other\tpid=2\tclients=0\tcreated=1700000000\tghostty_name=Beta
            """
        let r = ZmxAdapter.partition(out, hostID: "h1")
        #expect(r.managed.first?.alias == "Alpha")
        #expect(r.external.first?.alias == "Beta")
    }

    @Test func partitionDropsForgedDuplicateRows() {
        // A newline smuggled into a label prints as a second, attacker-composed row that
        // reuses a real session's name. Only the first row for a key survives, so a forged
        // duplicate can't rewrite the real session's alias/pid.
        let out = """
            name=h1-acr\tpid=1\tclients=1\tcreated=1700000000\tghostty_name=Real
            name=h1-acr\tpid=666\tclients=0\tcreated=0\tghostty_name=Forged
            name=other\tpid=2\tclients=0\tcreated=1700000000
            name=other\tpid=3\tclients=0\tcreated=1700000001
            """
        let r = ZmxAdapter.partition(out, hostID: "h1")
        #expect(r.managed.count == 1 && r.managed[0].pid == 1 && r.managed[0].alias == "Real")
        #expect(r.external.count == 1 && r.external[0].pid == 2)
    }

    @Test func setAliasKVIsWireSafeAndEmptyClears() {
        #expect(ZmxAdapter.aliasKV("my api") == "ghostty_name=my_20api")
        #expect(ZmxAdapter.aliasKV(nil) == "ghostty_name=")     // empty value = remove label
    }
}

/// The per-ref reducer, driven directly: every guard here is mutation-tested (delete or
/// invert it and a case fails). `.distantPast` created / `now` = fixed points; the TTL is a
/// parameter so expiry is exercised without wall-clock waits.
struct AliasSyncTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let created = Date(timeIntervalSince1970: 500)

    private func observe(_ s: inout AliasSync, live: String?, cached: String?,
                         seeded: Bool = false, budget: Bool = true, managed: Bool = true,
                         dt: TimeInterval = 0, ttl: TimeInterval = 40,
                         created c: Date? = nil) -> AliasSync.Action {
        s.observe(created: c ?? created, live: live, cached: cached, seeded: seeded,
                  id: "acr", budget: budget, managed: managed,
                  now: t0.addingTimeInterval(dt), ttl: ttl)
    }

    @Test func daemonWinsIntoTheCache() {
        var s = AliasSync()
        #expect(observe(&s, live: "Alpha", cached: nil) == .setCache("Alpha"))
        #expect(observe(&s, live: "Beta", cached: "Alpha") == .setCache("Beta"))
        #expect(observe(&s, live: "Beta", cached: "Beta") == .none)   // steady → no publish
        #expect(s.capable)
    }

    @Test func absentLabelIsAuthoritativeOnlyOnceCapable() {
        // Capability can't be probed (old and new daemons print alike), so it's earned.
        // Before that, a missing label keeps the cache (old daemon) and migrates once.
        var s = AliasSync()
        #expect(observe(&s, live: nil, cached: "Alpha") == .push("Alpha"))   // migrate
        #expect(observe(&s, live: nil, cached: "Alpha", dt: 999, ttl: 1) == .none)  // once
        // A daemon that has shown a label proves capable → a later absence is a *clear*
        // (from another Mac / `zmx set … ghostty_name=`) and must propagate, not resurrect.
        var c = AliasSync()
        _ = observe(&c, live: "Alpha", cached: "Alpha")
        #expect(observe(&c, live: nil, cached: "Alpha") == .setCache(nil))
        #expect(observe(&c, live: nil, cached: nil) == .none)
    }

    @Test func seedPushesTheIdButACachedNameOutranksIt() {
        var s = AliasSync()
        #expect(observe(&s, live: nil, cached: nil, seeded: true) == .push("acr"))
        // A rename typed before the session first listed beats the seed (which is just the
        // id): the cache is pushed instead, and the rename isn't lost.
        var r = AliasSync()
        #expect(observe(&r, live: nil, cached: "Deploy", seeded: true) == .push("Deploy"))
    }

    @Test func migrationRespectsThePushBudget() {
        // No budget this tick → stays eligible (not marked pushed), so it drains later.
        var s = AliasSync()
        #expect(observe(&s, live: nil, cached: "Alpha", budget: false) == .none)
        #expect(!s.pushed)
        #expect(observe(&s, live: nil, cached: "Alpha", budget: true) == .push("Alpha"))
        #expect(s.pushed)
    }

    @Test func migrationSkipsForeignExternalSessions() {
        // A foreign (external) session never gets an unsolicited migration/seed write.
        var s = AliasSync()
        #expect(observe(&s, live: nil, cached: "Alpha", managed: false) == .none)
        #expect(observe(&s, live: nil, cached: nil, seeded: true, managed: false) == .none)
    }

    @Test func pendingWriteMasksTheStaleEchoUntilEchoedOrExpired() {
        var s = AliasSync()
        s.noteSent(sent: "New", wire: "New", at: t0)
        // Daemon still echoes the old label → masked (cache must not snap back).
        #expect(observe(&s, live: "Old", cached: "New", dt: 1) == .none)
        // Echo of what we sent → landed; daemon-wins resumes.
        #expect(observe(&s, live: "New", cached: "New", dt: 2) == .none)
        #expect(observe(&s, live: "Elsewhere", cached: "New", dt: 3) == .setCache("Elsewhere"))
        // Backstop: an echo that never comes gives up after the TTL and the daemon wins.
        var e = AliasSync()
        e.noteSent(sent: "New", wire: "New", at: t0)
        #expect(observe(&e, live: "Old", cached: "New", dt: 41, ttl: 40) == .setCache("Old"))
    }

    @Test func failedRenameIsRetriedNotRevertedByTheDaemonsOldLabel() {
        // Regression: session already labeled "Old" (a capable daemon). The user renames
        // to "New"; the `zmx set` fails (ssh blip). The old rule only retried through the
        // migration path (daemon reports NO label), so the next poll's daemon-wins
        // silently snapped the row back to "Old" with no retry. Now the failure queues
        // its own value ahead of daemon-wins.
        var s = AliasSync()
        _ = observe(&s, live: "Old", cached: "Old")          // capable, labeled
        s.noteSent(sent: "New", wire: "New", at: t0)          // user renames → New
        s.noteFailed(at: t0)                                  // …and it fails
        // Next poll: daemon still says "Old", cache says "New" — must retry, not revert.
        #expect(observe(&s, live: "Old", cached: "New", dt: 3) == .push("New"))
        // The retry itself lands: masked while in flight, then echoed.
        s.noteSent(sent: "New", wire: "New", at: t0.addingTimeInterval(3))
        #expect(observe(&s, live: "Old", cached: "New", dt: 4) == .none)
        #expect(observe(&s, live: "New", cached: "New", dt: 5) == .none)
    }

    @Test func failedSeedRetriesTheIdInsteadOfBeingDropped() {
        // Regression: the seed is consumed the moment its push is *sent* (`pushed`), so a
        // transient failure of that first `zmx set` used to leave nothing to retry — the
        // session never got its label. The retry now carries the seed's own wire value
        // (the id), even though its expected echo is nil.
        var s = AliasSync()
        #expect(observe(&s, live: nil, cached: nil, seeded: true) == .push("acr"))
        s.noteSent(sent: nil, wire: "acr", at: t0)           // driver: expected echo is nil
        s.noteFailed(at: t0)                                  // first attempt fails
        // Seed already consumed by the driver, cache nil — the retry still re-sends the id.
        #expect(observe(&s, live: nil, cached: nil, seeded: false, dt: 3) == .push("acr"))
    }

    @Test func failedWriteRetriesAreBounded() {
        // An old daemon fails identically forever, so retries stop after `maxFailures`.
        // Simulate the driver: each `.push` is sent (`noteSent`) and fails again.
        var s = AliasSync()
        _ = observe(&s, live: nil, cached: nil, budget: false)   // first sighting
        s.noteSent(sent: "New", wire: "New", at: t0)             // rename in flight
        s.noteFailed(at: t0)                                     // fails → queues a retry
        var attempts = 0
        for i in 1...20 {
            let at = t0.addingTimeInterval(Double(i))
            if observe(&s, live: nil, cached: "New", dt: Double(i)) == .push("New") {
                attempts += 1
                s.noteSent(sent: "New", wire: "New", at: at)
                s.noteFailed(at: at)
            }
        }
        #expect(attempts == AliasSync.maxFailures)
    }

    @Test func staleFailureDoesNotUnmaskANewerWrite() {
        // Rename A then B; A's timeout must neither drop B's mask nor requeue A.
        var s = AliasSync()
        s.noteSent(sent: "A", wire: "A", at: t0)
        s.noteSent(sent: "B", wire: "B", at: t0.addingTimeInterval(1))
        s.noteFailed(at: t0)                       // A's late failure (stamp is stale)
        #expect(observe(&s, live: "Old", cached: "B", dt: 2) == .none)   // still masked
        #expect(observe(&s, live: "B", cached: "B", dt: 3) == .none)
    }

    @Test func renameBeforeFirstPollKeepsItsMask() {
        // A cold-restored pane renamed before its session was ever polled: the first
        // sighting must NOT drop the write's mask, or the daemon's stale label clobbers
        // the rename. (Only a genuine *re*creation — created changing from a known
        // value — invalidates in-flight writes.)
        var s = AliasSync()
        s.noteSent(sent: "New", wire: "New", at: t0)
        #expect(observe(&s, live: "Old", cached: "New", dt: 1) == .none)      // masked
        #expect(observe(&s, live: "New", cached: "New", dt: 2) == .none)      // echoed
    }

    @Test func recreatedSessionIsANewIncarnation() {
        // Session died and was recreated under the same id (new `created`): daemon labels
        // died with the old daemon, so this reads as a fresh unlabeled session — the cached
        // name migrates onto it again instead of being taken as a clear.
        var s = AliasSync()
        _ = observe(&s, live: "Deploy", cached: "Deploy", created: created)
        let action = observe(&s, live: nil, cached: "Deploy",
                             created: created.addingTimeInterval(9000))
        #expect(action == .push("Deploy"))
    }
}

/// The registry driver: fan-out to tabs, seeds, external no-migrate, and the budget.
@MainActor
struct AliasDriverTests {
    private func reset() -> SessionRegistry {
        let r = SessionRegistry.shared
        r.resetForTesting()
        return r
    }

    private func makeTab(_ r: SessionRegistry, name: String, external: Bool = false) -> TabModel.ID {
        let t = r.newTab(on: "local", title: name)
        r.setPersistedTree(.empty.appending(leaf: SessionRef(hostID: "local", name: name,
                                                             external: external)), for: t.id)
        return t.id
    }

    private func entry(_ name: String, alias: String?, external: Bool = false,
                       created: Date = .distantPast) -> ZmxAdapter.ListEntry {
        .init(name: name, clients: 1, created: created, external: external, pid: nil, alias: alias)
    }

    private func label(_ r: SessionRegistry, _ tab: TabModel.ID, _ key: String) -> String? {
        r.tabs.first { $0.id == tab }?.paneLabels[key]
    }

    @Test func daemonAliasWritesIntoCacheOfEveryTabHoldingTheRef() {
        // A ref attached in two tabs (dup-attach): one decision per ref, both caches
        // updated — and no second pass to clear a pending mask twice.
        let r = reset()
        let a = makeTab(r, name: "acr")
        let b = makeTab(r, name: "acr")
        r.syncAliases(hostID: "local", list: .init(managed: [entry("acr", alias: "Alpha")]))
        #expect(label(r, a, "acr") == "Alpha")
        #expect(label(r, b, "acr") == "Alpha")
        // A rename made from either tab fans out to both — the two rows can't diverge.
        r.aliasPusher = { _, _, _, _ in }
        r.renamePane(tab: b, name: "acr", to: "Beta")
        #expect(label(r, a, "acr") == "Beta")
        #expect(label(r, b, "acr") == "Beta")
    }

    @Test func renamingToTheIdItselfClearsInsteadOfCachingTheId() {
        // The inline rename field prefills the *id*; ⏎ without editing must mean "no
        // alias" — a cached label == id would freeze the row over the live OSC title
        // and could never prove the daemon capable (its echo normalizes to nil).
        let r = reset()
        var pushes: [String?] = []
        r.aliasPusher = { _, _, alias, _ in pushes.append(alias) }
        let t = makeTab(r, name: "acr")
        r.renamePane(tab: t, name: "acr", to: "acr")
        #expect(label(r, t, "acr") == nil)
        #expect(pushes == [nil])
        // A pre-existing label == id (old fork.json) is healed on the next sync too.
        r.setPaneLabel(tab: t, name: "acr", to: "acr")
        r.syncAliases(hostID: "local", list: .init(managed: [entry("acr", alias: nil)]))
        #expect(label(r, t, "acr") == nil)
    }

    @Test func renameWritesCacheAndPushesSanitized() {
        let r = reset()
        var pushes: [(SessionRef, String?)] = []
        r.aliasPusher = { _, ref, alias, _ in pushes.append((ref, alias)) }
        let t = makeTab(r, name: "acr")
        r.renamePane(tab: t, name: "acr", to: "  New Name  ")
        #expect(label(r, t, "acr") == "New Name")            // trimmed like the echo will be
        #expect(pushes.count == 1 && pushes[0].1 == "New Name")
        // A rename that sanitizes to nothing is a clear, not a permanent blank row.
        r.renamePane(tab: t, name: "acr", to: "   ")
        #expect(label(r, t, "acr") == nil)
        #expect(pushes.count == 2 && pushes[1].1 == nil)
    }

    @Test func seededNameLabelsTheDaemonNotTheCache() {
        let r = reset()
        var pushes: [String?] = []
        r.aliasPusher = { _, _, alias, _ in pushes.append(alias) }
        let t = makeTab(r, name: "proj")
        r.seedAlias(SessionRef(hostID: "local", name: "proj"))
        r.syncAliases(hostID: "local", list: .init(managed: [entry("proj", alias: nil)]))
        #expect(pushes == ["proj"])
        // The echo (label == id) must NOT land in the cache — that would freeze the row
        // over the live OSC title; the id shows via the fallback chain either way.
        r.syncAliases(hostID: "local", list: .init(managed: [entry("proj", alias: "proj")]))
        #expect(label(r, t, "proj") == nil)
        // A real (non-id) alias set later still flows in.
        r.syncAliases(hostID: "local", list: .init(managed: [entry("proj", alias: "Real")]))
        #expect(label(r, t, "proj") == "Real")
    }

    @Test func externalSessionsNeverGetUnsolicitedWrites() {
        // Migration/seeding target only fork-created sessions; a foreign (external)
        // session is labeled solely by an explicit rename.
        let r = reset()
        var pushes = 0
        r.aliasPusher = { _, _, _, _ in pushes += 1 }
        let t = makeTab(r, name: "theirs", external: true)
        r.setPaneLabel(tab: t, name: "@theirs", to: "Mine")
        r.syncAliases(hostID: "local", list: .init(external: [entry("theirs", alias: nil, external: true)]))
        #expect(pushes == 0)
        r.renamePane(tab: t, name: "@theirs", to: "Explicit")
        #expect(pushes == 1)
    }

    @Test func migrationBurstIsBudgetedPerHostPerTick() {
        // First launch after this ships migrates every labeled pane at once; the budget
        // bounds concurrent `zmx set` spawns (sshd MaxStartups); the rest drain next tick.
        // TTL −1 so the pending masks never hold: the third tick's silence must come
        // from the once-per-incarnation `pushed` guard, not from masking.
        let r = reset()
        var pushes = 0
        r.aliasPusher = { _, _, _, _ in pushes += 1 }
        r.aliasPendingTTL = -1
        let names = (0..<7).map { "s\($0)" }
        for n in names { r.setPaneLabel(tab: makeTab(r, name: n), name: n, to: "Label \(n)") }
        let list = ZmxAdapter.ListResult(managed: names.map { entry($0, alias: nil) })
        r.syncAliases(hostID: "local", list: list)
        #expect(pushes == 4)
        r.syncAliases(hostID: "local", list: list)
        #expect(pushes == 7)
        r.syncAliases(hostID: "local", list: list)
        #expect(pushes == 7)          // once per app session, not once per tick
    }

    @Test func unlistedSessionIsLeftAlone() {
        let r = reset()
        var pushes = 0
        r.aliasPusher = { _, _, _, _ in pushes += 1 }
        let t = makeTab(r, name: "acr")
        r.setPaneLabel(tab: t, name: "acr", to: "Alpha")
        r.seedAlias(SessionRef(hostID: "local", name: "acr"))
        r.syncAliases(hostID: "local", list: .init(managed: [entry("other", alias: nil)]))
        #expect(pushes == 0)
        #expect(label(r, t, "acr") == "Alpha")
    }

    @Test func pendingTTLIsInjectable() {
        // With a zero TTL the mask never blocks: proves the driver actually reads
        // `aliasPendingTTL` (a deleted expiry branch would leave the row stuck).
        let r = reset()
        r.aliasPusher = { _, _, _, _ in }
        r.aliasPendingTTL = -1   // always expired, whatever the clock does
        let t = makeTab(r, name: "acr")
        r.renamePane(tab: t, name: "acr", to: "New")
        r.syncAliases(hostID: "local", list: .init(managed: [entry("acr", alias: "Old")]))
        #expect(label(r, t, "acr") == "Old")   // expired instantly → daemon wins
    }
}

/// The poll's two stored inputs and their derived effects — the alias sync (and the
/// unreachable cue) must not depend on the CC-status toggle.
@MainActor
struct PollLifecycleTests {
    @Test func ccProbeOffTearsDownCCStateAndOnRestores() {
        let r = SessionRegistry.shared
        r.resetForTesting()
        let ref = SessionRef(hostID: "local", name: "acr")
        _ = r.newTab(on: "local", title: "acr")
        r.apply(ref, .probe(blocked: false, busy: true, sig: .init(tempo: nil, needs: nil)))
        #expect(r.panes[ref]?.ccBusy == true)
        r.setCCProbeEnabled(true)
        r.setCCProbeEnabled(false)
        // Probe off ⇒ ccBusy cleared (nothing else ever clears it → the .working wedge).
        #expect(r.panes[ref]?.ccBusy == false)
        r.resetForTesting()
    }

    @Test func pollingLeversAreIndependent() {
        // The list poll runs on window presence, not on the CC toggle; the probe is a
        // flag on that loop. Both directions of both levers are idempotent.
        let r = SessionRegistry.shared
        r.resetForTesting()
        r.setCCProbeEnabled(true)      // probe wanted before any window
        #expect(r.ccProbeOn && !r.isPolling)
        r.setPolling(true)             // window up → loop runs (and probes)
        #expect(r.isPolling)
        r.setCCProbeEnabled(false)     // toggle off ≠ stop the loop
        #expect(!r.ccProbeOn && r.isPolling)
        r.setPolling(false)            // last window gone → loop stops
        #expect(!r.isPolling)
        r.resetForTesting()
    }
}
#endif
