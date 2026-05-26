#if os(macOS)
import Foundation
import Testing
@testable import Ghostty

/// PR21a — pure persisted-side pane/tab moves. Controller plumbing is tested
/// separately; here we lock in leaf conservation, per-pane state migration,
/// and the no-touch-refs invariant.
@MainActor
struct RegistryMoveTests {
    // Fresh registry per test — `SessionRegistry.shared` is a singleton but all
    // @Published state resets via the helpers below.
    private func reset() -> SessionRegistry {
        let r = SessionRegistry.shared
        // Remove every non-local host (trailing tabs too, via removeHost).
        for h in r.hosts where h.id != ForkHost.local.id { r.removeHost(h.id) }
        // Close all tabs on local.
        for t in r.tabs { r.removeTab(t.id) }
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
}
#endif
