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
}
#endif
