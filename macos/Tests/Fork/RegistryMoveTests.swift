#if os(macOS)
import Combine
import Foundation
import Testing
@testable import Ghostty

/// PR21a — pure persisted-side pane/tab moves. Controller plumbing is tested
/// separately; here we lock in leaf conservation, per-pane state migration,
/// and the no-touch-refs invariant.
@MainActor
struct RegistryMoveTests {
    // Fresh registry per test. `resetForTesting()` clears the state the old removeHost/
    // removeTab loop missed: `refs`, the pending exit-stamp, local-host ccLive/ccSeenDetail,
    // focusedPaneIndex — all of which leaked across test cases before.
    private func reset() -> SessionRegistry {
        let r = SessionRegistry.shared
        r.resetForTesting()
        return r
    }

    private func makeTab(_ r: SessionRegistry, names: [String], host: String = "local") -> TabModel.ID {
        let t = r.newTab(on: host, title: names.first ?? "empty")
        let refs = names.map { SessionRef(hostID: host, name: $0) }
        let tree: PersistedTree = refs.reduce(.empty) { $0.appending(leaf: $1) }
        r.setPersistedTree(tree, for: t.id)
        return t.id
    }

    @Test func movePane_conservesLeafCount() {
        let r = reset()
        let src = makeTab(r, names: ["a", "b", "c"])
        let dst = makeTab(r, names: ["x"])
        let ref = SessionRef(hostID: "local", name: "b")
        #expect(r.movePanePersisted(from: src, ref: ref, to: dst) == true)
        let paneCount = { (id: TabModel.ID) in r.tabs.first { $0.id == id }!.tree.paneCount }
        #expect(paneCount(src) == 2)
        #expect(paneCount(dst) == 2)
    }

    @Test func movePane_migratesState() {
        let r = reset()
        let src = makeTab(r, names: ["a", "b"])
        let dst = makeTab(r, names: ["x"])
        r.setPaneLabel(tab: src, name: "b", to: "keeper")
        r.setPaneTag(tab: src, name: "b", to: PaneTag(text: "prod", hue: 0.3))
        r.touchPane(tab: src, name: "b")
        let ref = SessionRef(hostID: "local", name: "b")
        _ = r.movePanePersisted(from: src, ref: ref, to: dst)
        let srcTab = r.tabs.first { $0.id == src }!
        let dstTab = r.tabs.first { $0.id == dst }!
        #expect(srcTab.paneLabels["b"] == nil)
        #expect(srcTab.paneTags["b"] == nil)
        #expect(srcTab.lastActive["b"] == nil)
        #expect(dstTab.paneLabels["b"] == "keeper")
        #expect(dstTab.paneTags["b"]?.text == "prod")
        #expect(dstTab.lastActive["b"] != nil)
    }

    @Test func movePane_lastLeafLeavesSourceEmpty() {
        let r = reset()
        let src = makeTab(r, names: ["solo"])
        let dst = makeTab(r, names: ["other"])
        let ref = SessionRef(hostID: "local", name: "solo")
        _ = r.movePanePersisted(from: src, ref: ref, to: dst)
        #expect(r.tabs.first { $0.id == src }!.tree == .empty)
        // Registry itself does NOT auto-close; controller handles that.
        #expect(r.tabs.contains { $0.id == src })
    }

    @Test func movePane_rejectsCrossHost() {
        let r = reset()
        r.addHost(ForkHost(id: "remote", label: "r", transport: .local))
        let src = makeTab(r, names: ["a", "b"], host: "local")
        let dst = makeTab(r, names: ["x"], host: "remote")
        let ref = SessionRef(hostID: "local", name: "b")
        #expect(r.movePanePersisted(from: src, ref: ref, to: dst) == false)
        // State untouched.
        #expect(r.tabs.first { $0.id == src }!.tree.paneCount == 2)
        #expect(r.tabs.first { $0.id == dst }!.tree.paneCount == 1)
    }

    @Test func movePane_rejectsSameTab() {
        let r = reset()
        let t = makeTab(r, names: ["a", "b"])
        let ref = SessionRef(hostID: "local", name: "a")
        #expect(r.movePanePersisted(from: t, ref: ref, to: t) == false)
    }

    @Test func movePane_rejectsMissingRef() {
        let r = reset()
        let src = makeTab(r, names: ["a"])
        let dst = makeTab(r, names: ["x"])
        let bogus = SessionRef(hostID: "local", name: "nope")
        #expect(r.movePanePersisted(from: src, ref: bogus, to: dst) == false)
    }

    @Test func movePane_ownedKeyCollisionSrcWins() {
        // Two tabs each hosting an owned leaf named "acr" — moving src's acr into
        // dst silently overwrites dst's dict entries. Locks in "src wins" as the
        // current contract so a future fix is a conscious decision, not a regression.
        let r = reset()
        let src = makeTab(r, names: ["acr"])
        let dst = makeTab(r, names: ["acr"])
        r.setPaneLabel(tab: src, name: "acr", to: "src-label")
        r.setPaneLabel(tab: dst, name: "acr", to: "dst-label")
        let ref = SessionRef(hostID: "local", name: "acr")
        _ = r.movePanePersisted(from: src, ref: ref, to: dst)
        #expect(r.tabs.first { $0.id == dst }!.paneLabels["acr"] == "src-label")
    }

    @Test func externalKeyDisambiguation() {
        // Owned `acr` in src and external `@acr` shadow in dst must not collide
        // on dict keys when `acr` moves into dst.
        let r = reset()
        let src = makeTab(r, names: ["acr"])
        let dst = r.newTab(on: "local", title: "dst")
        let owned = SessionRef(hostID: "local", name: "acr")
        let external = SessionRef(hostID: "local", name: "acr", external: true)
        r.setPersistedTree(.leaf(external), for: dst.id)
        r.setPaneLabel(tab: dst.id, name: external.key, to: "shadow-label")
        r.setPaneLabel(tab: src, name: owned.key, to: "owned-label")
        #expect(owned.key == "acr")
        #expect(external.key == "@acr")
        _ = r.movePanePersisted(from: src, ref: owned, to: dst.id)
        let dstTab = r.tabs.first { $0.id == dst.id }!
        #expect(dstTab.paneLabels["acr"] == "owned-label")
        #expect(dstTab.paneLabels["@acr"] == "shadow-label")
    }

    @Test func recentTags_prunedWhenLastUserCleared() {
        let r = reset()
        let t = makeTab(r, names: ["a", "b"])
        let wip = PaneTag(text: "wip", hue: 0.5)
        r.setPaneTag(tab: t, name: "a", to: wip)
        r.setPaneTag(tab: t, name: "b", to: wip)
        #expect(r.recentTags == [wip])
        r.setPaneTag(tab: t, name: "a", to: nil)
        #expect(r.recentTags == [wip])           // b still has it
        r.setPaneTag(tab: t, name: "b", to: nil)
        #expect(r.recentTags.isEmpty)
    }

    @Test func recentTags_prunedWhenPaneClosed() {
        let r = reset()
        let t = makeTab(r, names: ["a", "b"])
        r.setPaneTag(tab: t, name: "b", to: PaneTag(text: "hot", hue: 0.0))
        #expect(r.recentTags.count == 1)
        r.setPersistedTree(.leaf(SessionRef(hostID: "local", name: "a")), for: t)
        #expect(r.recentTags.isEmpty)
    }

    @Test func dismissThenTouch_resurfaces() {
        let r = reset()
        let t = makeTab(r, names: ["a"])
        r.dismissFromFocus(t)
        #expect(r.tabs.first { $0.id == t }?.dismissedAt != nil)
        r.touchPane(tab: t, name: "a")
        #expect(r.tabs.first { $0.id == t }?.dismissedAt == nil)
        r.dismissFromFocus(t)
        r.setPinned(t, true)
        #expect(r.tabs.first { $0.id == t }?.dismissedAt == nil)
    }

    @Test func moveHost_reorders() {
        let r = reset()
        r.addHost(ForkHost(id: "a", label: "a", transport: .ssh(.init(host: "a"))))
        r.addHost(ForkHost(id: "b", label: "b", transport: .ssh(.init(host: "b"))))
        #expect(r.hosts.map(\.id) == ["local", "a", "b"])
        // Drag-swap semantics (matches moveTab): moved host lands at target's slot.
        r.moveHost("b", before: "local")
        #expect(r.hosts.map(\.id) == ["b", "local", "a"])
        r.moveHost("b", before: "a")
        #expect(r.hosts.map(\.id) == ["local", "a", "b"])
    }

    // MARK: - touchPane exit-stamp ("lastActive = last time this pane WAS the focused one")
    // Each test seeds `lastTouched` with its own first touch — the singleton carries the
    // previous test's value, which the prev-tab guards neutralize but assertions shouldn't
    // assume away.

    @Test func touchPane_exitStampsPreviousPane() {
        let r = reset()
        let t = makeTab(r, names: ["a", "b"])
        r.touchPane(tab: t, name: "a")
        let arrival = r.tabs.first { $0.id == t }!.lastActive["a"]!
        r.touchPane(tab: t, name: "b")
        let tab = r.tabs.first { $0.id == t }!
        #expect(tab.lastActive["a"]! > arrival)   // departure stamp, not arrival time
        #expect(tab.lastActive["b"] != nil)
    }

    @Test func touchPane_exitStampDoesNotResurfaceDismissedTab() {
        let r = reset()
        let t1 = makeTab(r, names: ["a"])
        let t2 = makeTab(r, names: ["x"])
        r.touchPane(tab: t1, name: "a")
        r.dismissFromFocus(t1)
        // Departing t1/a must NOT undo Hide: the watermark (`mru >= dismissedAt`) stays unmet.
        r.touchPane(tab: t2, name: "x")
        let hidden = r.tabs.first { $0.id == t1 }!
        #expect(hidden.dismissedAt != nil)
        #expect(hidden.lastActive["a"]! < hidden.dismissedAt!)
    }

    @Test func touchPane_exitStampDoesNotResurrectPrunedPane() {
        let r = reset()
        let t = makeTab(r, names: ["a", "b"])
        r.touchPane(tab: t, name: "a")
        // "a" leaves the tree (closed) — setPersistedTree prunes its lastActive entry.
        r.setPersistedTree(.leaf(SessionRef(hostID: "local", name: "b")), for: t)
        r.touchPane(tab: t, name: "b")
        #expect(r.tabs.first { $0.id == t }!.lastActive["a"] == nil)
    }

    @Test func touchPane_repeatTouchExitStampsOnce() {
        let r = reset()
        let t1 = makeTab(r, names: ["a"])
        let t2 = makeTab(r, names: ["x"])
        r.touchPane(tab: t1, name: "a")
        r.touchPane(tab: t2, name: "x")
        let stamped = r.tabs.first { $0.id == t1 }!.lastActive["a"]!
        // One real switch drives touchPane twice (activate + async focus settlement) — the
        // repeat of the same pane must not exit-stamp the departed pane again.
        r.touchPane(tab: t2, name: "x")
        #expect(r.tabs.first { $0.id == t1 }!.lastActive["a"]! == stamped)
    }

    @Test func touchPane_vanishedTabIsNoOp() {
        let r = reset()
        let t = makeTab(r, names: ["a", "b"])
        r.touchPane(tab: t, name: "a")
        let before = r.tabs.first { $0.id == t }!.lastActive["a"]!
        r.touchPane(tab: TabModel.ID(), name: "ghost")   // unknown destination: nothing stamped
        #expect(r.tabs.first { $0.id == t }!.lastActive["a"]! == before)
        // ...and the pending exit-stamp still targets "a": the next real switch stamps it.
        r.touchPane(tab: t, name: "b")
        #expect(r.tabs.first { $0.id == t }!.lastActive["a"]! > before)
    }

    @Test func movePane_focusedPaneKeepsPendingExitStamp() {
        let r = reset()
        let src = makeTab(r, names: ["a", "b"])
        let dst = makeTab(r, names: ["x"])
        r.touchPane(tab: src, name: "b")                 // "b" is the focused pane
        let arrival = r.tabs.first { $0.id == src }!.lastActive["b"]!
        let ref = SessionRef(hostID: "local", name: "b")
        _ = r.movePanePersisted(from: src, ref: ref, to: dst)   // pending exit-stamp follows the move
        r.touchPane(tab: dst, name: "x")                 // focus finally leaves "b"
        #expect(r.tabs.first { $0.id == dst }!.lastActive["b"]! > arrival)
    }

    @Test func flushPaneExit_stampsAndClears() {
        let r = reset()
        let t = makeTab(r, names: ["a", "b"])
        r.touchPane(tab: t, name: "a")
        let arrival = r.tabs.first { $0.id == t }!.lastActive["a"]!
        r.flushPaneExit()                                // window closes: departure recorded now
        let flushed = r.tabs.first { $0.id == t }!.lastActive["a"]!
        #expect(flushed >= arrival)
        // The pending target was cleared — the next touch must not stamp "a" again.
        r.touchPane(tab: t, name: "b")
        #expect(r.tabs.first { $0.id == t }!.lastActive["a"]! == flushed)
    }

    // MARK: - Pane GC (PaneMachine lifecycle on tab close — dup-attach + ⌘W→⌘Z contracts)

    @Test func paneGC_dupAttachSurvivesFirstTabClose() {
        let r = reset()
        let ref = SessionRef(hostID: "local", name: "shared")
        let a = makeTab(r, names: ["shared"])
        let b = makeTab(r, names: ["shared"])      // same session attached in two tabs (PR26)
        r.apply(ref, .watch(true))
        #expect(r.panes[ref] != nil)
        // Closing one tab must keep the machine — the other tab still renders it.
        r.removeTab(a)
        #expect(r.panes[ref]?.watched == true)
        // Closing the last tab is the drop point.
        r.removeTab(b)
        #expect(r.panes[ref] == nil)
    }

    @Test func paneGC_detachPreservesMachineForUndo() {
        let r = reset()
        let detached = SessionRef(hostID: "local", name: "a")
        let kept = SessionRef(hostID: "local", name: "b")
        let t = makeTab(r, names: ["a", "b"])
        r.apply(detached, .watch(true))
        // Per-pane Detach = setPersistedTree without the ref — machine must survive (⌘W→⌘Z
        // restores the pane and its watch/blockSig must still be there).
        r.setPersistedTree(.leaf(kept), for: t)
        #expect(r.panes[detached]?.watched == true)
        // Tab close drops in-tree refs; the already-detached ref's machine stays until
        // host-remove or quit — pin the documented leak policy so a "fix" is conscious.
        r.removeTab(t)
        #expect(r.panes[kept] == nil)
        #expect(r.panes[detached]?.watched == true)
    }

    @Test func paneGC_removeHostDropsAllItsMachines() {
        let r = reset()
        r.addHost(ForkHost(id: "rh", label: "r", transport: .ssh(.init(host: "rh"))))
        _ = makeTab(r, names: ["x"], host: "rh")
        _ = makeTab(r, names: ["y"])               // local — must survive
        let remote = SessionRef(hostID: "rh", name: "x")
        let local = SessionRef(hostID: "local", name: "y")
        r.apply(remote, .watch(true))
        r.apply(local, .watch(true))
        r.removeHost("rh")
        #expect(r.panes[remote] == nil)
        #expect(r.panes[local] != nil)
    }

    // MARK: - focusTabs (what ⌘1-9 + focus mode address)

    @Test func focusTabs_pinnedFirstThenActiveThenMRU() {
        let r = reset()
        defer { UserDefaults.standard.removeObject(forKey: SessionRegistry.kFocusSortMRU) }
        UserDefaults.standard.set(true, forKey: SessionRegistry.kFocusSortMRU)
        let a = makeTab(r, names: ["a"])
        let b = makeTab(r, names: ["b"])
        let c = makeTab(r, names: ["c"])
        r.touchPane(tab: a, name: "a")
        r.touchPane(tab: b, name: "b")
        r.touchPane(tab: c, name: "c")
        r.setPinned(a, true)
        r.setActive(tab: b)
        let order = r.focusTabs(taggedOnly: false).map(\.id)
        // Pinned floats over everything; the active tab gets .distantFuture MRU next.
        #expect(order.first == a)
        #expect(order.dropFirst().first == b)
        #expect(Set(order) == Set([a, b, c]))
    }

    @Test func focusTabs_dismissedHiddenUntilTouched() {
        let r = reset()
        let a = makeTab(r, names: ["a"])
        let b = makeTab(r, names: ["b"])
        r.touchPane(tab: a, name: "a")
        r.touchPane(tab: b, name: "b")
        r.dismissFromFocus(a)
        #expect(!r.focusTabs(taggedOnly: false).map(\.id).contains(a))
        // Re-activating the tab (touchPane) clears the dismiss watermark.
        r.touchPane(tab: a, name: "a")
        #expect(r.focusTabs(taggedOnly: false).map(\.id).contains(a))
    }

    @Test func focusTabs_taggedOnlyFiltersUntagged() {
        let r = reset()
        let tagged = makeTab(r, names: ["t"])
        let plain = makeTab(r, names: ["p"])
        r.touchPane(tab: tagged, name: "t")
        r.touchPane(tab: plain, name: "p")
        r.setPaneTag(tab: tagged, name: "t", to: PaneTag(text: "wip", hue: 0.2))
        let ids = r.focusTabs(taggedOnly: true).map(\.id)
        #expect(ids.contains(tagged))
        #expect(!ids.contains(plain))
    }

    @Test func focusTabs_hostGroupedModeFollowsSidebarOrder() {
        let r = reset()
        defer { UserDefaults.standard.removeObject(forKey: SessionRegistry.kFocusSortMRU) }
        UserDefaults.standard.set(false, forKey: SessionRegistry.kFocusSortMRU)
        r.addHost(ForkHost(id: "zzz", label: "z", transport: .ssh(.init(host: "z"))))
        let remote = makeTab(r, names: ["r1"], host: "zzz")
        let local1 = makeTab(r, names: ["l1"])
        let local2 = makeTab(r, names: ["l2"])
        // Touch the remote tab last (most recent) — host-grouped order must still win.
        r.touchPane(tab: local1, name: "l1")
        r.touchPane(tab: local2, name: "l2")
        r.touchPane(tab: remote, name: "r1")
        let order = r.focusTabs(taggedOnly: false).map(\.id)
        #expect(order == [local1, local2, remote])
    }

    // MARK: - uniqueAutoName

    @Test func uniqueAutoName_collisionsAndDerivedStems() {
        let r = reset()
        _ = makeTab(r, names: ["api-prod"])
        // Always valid, never collides with an existing leaf.
        let fresh = r.uniqueAutoName()
        #expect(fresh != "api-prod" && SessionRef(hostID: "local", name: fresh).isValid)
        // Deriving from a live name appends one 4-char suffix.
        let derived = r.uniqueAutoName(derivedFrom: "api-prod")
        #expect(derived.hasPrefix("api-prod-") && derived.count == "api-prod".count + 5)
        // Chained splits don't grow names: deriving from the derived name strips its
        // auto-suffix back to the live stem.
        _ = makeTab(r, names: [derived])
        let chained = r.uniqueAutoName(derivedFrom: derived)
        #expect(chained.hasPrefix("api-prod-") && chained.count == derived.count)
        // A user name whose tail merely looks auto-generated keeps its full name as stem
        // (the stem "release" isn't a live session).
        #expect(r.uniqueAutoName(derivedFrom: "release-v123").hasPrefix("release-v123-"))
    }

    // MARK: - applyProbeResult (mergeCC body — first direct tests for the poll's merge)

    private func info(name: String? = nil, status: String? = nil, tempo: String? = nil,
                      needs: String? = nil) -> CCProbe.Info {
        .init(name: name, status: status, cwd: nil, updatedAt: nil, waitingFor: nil,
              tempo: tempo, needs: needs, detail: nil, sock: nil)
    }

    @Test func applyProbe_busyAndBlockedDriveDots() {
        let r = reset()
        _ = makeTab(r, names: ["agent"])
        let ref = SessionRef(hostID: "local", name: "agent")
        r.applyProbeResult(hostID: "local", result: ["agent": info(status: "busy")])
        #expect(r.dot(ref: ref) == .working)
        r.applyProbeResult(hostID: "local", result: ["agent": info(tempo: "blocked", needs: "answer?")])
        #expect(r.dot(ref: ref) == .blocked)
    }

    @Test func applyProbe_nilResultKeepsLastKnownAndBlockedLatch() {
        let r = reset()
        _ = makeTab(r, names: ["agent"])
        let ref = SessionRef(hostID: "local", name: "agent")
        r.applyProbeResult(hostID: "local",
                           result: ["agent": info(name: "cc", tempo: "blocked", needs: "x")])
        #expect(r.dot(ref: ref) == .blocked)
        // Probe failure (nil): ccLive keeps last-known, blocked latch survives, busy clears.
        r.applyProbeResult(hostID: "local", result: nil)
        #expect(r.ccLive["local"]?["agent"] != nil)
        #expect(r.dot(ref: ref) == .blocked)
    }

    @Test func applyProbe_neverAttachedSessionsDoNotLeakMachines() {
        let r = reset()
        _ = makeTab(r, names: ["agent"])
        r.applyProbeResult(hostID: "local", result: [
            "agent": info(name: "ours"),
            "stranger": info(name: "not-ours"),
        ])
        // The stranger is in ccLive (whole-host slice — pickers read it) but must not get
        // a PaneMachine (panes is keyed by in-tree refs only).
        #expect(r.ccLive["local"]?["stranger"] != nil)
        #expect(r.panes[SessionRef(hostID: "local", name: "stranger")] == nil)
    }

    @Test func applyProbe_ccNamesWriteThroughOnlyForLiveKeys() {
        let r = reset()
        let t = makeTab(r, names: ["agent"])
        r.applyProbeResult(hostID: "local", result: [
            "agent": info(name: "fixing-tests"),
            "other": info(name: "stray"),
        ])
        let tab = r.tabs.first { $0.id == t }!
        #expect(tab.ccNames["agent"] == "fixing-tests")
        #expect(tab.ccNames["other"] == nil)
    }

    @Test func applyProbe_removedHostMidTickIsNoOp() {
        let r = reset()
        r.addHost(ForkHost(id: "gone", label: "g", transport: .ssh(.init(host: "g"))))
        _ = makeTab(r, names: ["x"], host: "gone")
        r.removeHost("gone")
        // An in-flight poll result draining after removeHost must not resurrect its ccLive.
        r.applyProbeResult(hostID: "gone", result: ["x": info(name: "ghost")])
        #expect(r.ccLive["gone"] == nil)
    }

    @Test func applyProbe_identicalResultDoesNotRepublish() {
        let r = reset()
        _ = makeTab(r, names: ["agent"])
        let payload = ["agent": info(name: "cc", status: "busy")]
        r.applyProbeResult(hostID: "local", result: payload)
        // The `!=` publish guard: a steady-state tick (value-identical result) must not
        // fire objectWillChange — that's what keeps the debounce-save and the sidebar
        // re-render off the 3s poll cadence.
        var publishes = 0
        let sub = r.objectWillChange.sink { _ in publishes += 1 }
        r.applyProbeResult(hostID: "local", result: payload)
        sub.cancel()
        #expect(publishes == 0)
    }

    // MARK: - Session-list presence (the "already open as a pane" cue)

    @Test func isInSidebar_externalFlagHostScopeAndColdPlaceholder() {
        let r = reset()
        _ = makeTab(r, names: ["acr"])                    // managed acr; never hydrated (cold)
        r.addHost(ForkHost(id: "remote", label: "r", transport: .ssh(.init(host: "r"))))
        let ext = r.newTab(on: "local", title: "ext")
        r.setPersistedTree(.leaf(SessionRef(hostID: "local", name: "logs", external: true)), for: ext.id)
        #expect(r.isInSidebar("acr", external: false, on: "local"))    // cold placeholder still counts
        #expect(!r.isInSidebar("acr", external: true, on: "local"))    // external shadow must not cross-match
        #expect(!r.isInSidebar("acr", external: false, on: "remote"))  // host-scoped
        #expect(r.isInSidebar("logs", external: true, on: "local"))
        #expect(!r.isInSidebar("logs", external: false, on: "local"))
        #expect(!r.isInSidebar("ghost", external: false, on: "local"))
    }
}
#endif
