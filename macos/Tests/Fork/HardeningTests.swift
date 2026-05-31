#if os(macOS)
import Foundation
import Testing
@testable import Ghostty

/// PR43 hardening contracts: argument-layer validation in the zmx adapter and the
/// fork.json load-path safety net. Pure value tests — no singleton, no Process.
struct ZmxHardeningTests {
    private let host = ForkHost(id: "h1", label: "box", transport: .local)

    @Test func partitionStripsPrefixAndDropsDashNames() {
        let out = """
            name=h1-acr\tpid=11\tclients=1\tcreated=1700000000
            name=other\tpid=12\tclients=0\tcreated=1700000000
            name=-Sevil\tpid=13\tclients=0\tcreated=1700000000
            name=dead\terr=stale socket
            """
        let r = ZmxAdapter.partition(out, hostID: "h1")
        #expect(r.managed.map(\.name) == ["acr"])
        #expect(r.managed.allSatisfy { !$0.external })
        #expect(r.external.map(\.name) == ["other"])   // err= and -Sevil dropped
    }

    @Test func partitionForgedPrefixStaysExternal() {
        // Anyone on the remote host can name a session `{hostID}-anything` (the hostID is
        // just a hash of user@host). Only names the fork could have created itself
        // (managed charset) are trusted as managed; forged names with shell-hostile
        // characters stay external under their full wire name — they must never become a
        // non-external SessionRef downstream code assumes is `isValid`.
        let out = """
            name=h1-good_name.1\tpid=1\tclients=0\tcreated=1700000000
            name=h1-evil name; rm -rf\tpid=2\tclients=0\tcreated=1700000000
            name=h1-spoof$(id)\tpid=3\tclients=0\tcreated=1700000000
            """
        let r = ZmxAdapter.partition(out, hostID: "h1")
        #expect(r.managed.map(\.name) == ["good_name.1"])
        #expect(r.external.map(\.name) == ["h1-evil name; rm -rf", "h1-spoof$(id)"])
    }

    @Test func expandRequiresAbsoluteCwd() {
        let ref = SessionRef(hostID: "h1", name: "shell-abc")
        // Absolute paths pass through; relative / dash-leading / URL-ish degrade to ".".
        #expect(ZmxAdapter.expand(["open", "{cwd}"], host: host, ref: ref, cwd: "/tmp/x")
                == ["open", "/tmp/x"])
        #expect(ZmxAdapter.expand(["open", "{cwd}"], host: host, ref: ref, cwd: "-RTFM")
                == ["open", "."])
        #expect(ZmxAdapter.expand(["open", "{cwd}"], host: host, ref: ref, cwd: "relative/path")
                == ["open", "."])
        #expect(ZmxAdapter.expand(["open", "{cwd}"], host: host, ref: ref, cwd: nil)
                == ["open", "."])
    }

    @Test func externalNameRule() {
        // The leading-dash rule applies to external names only (managed names are protected
        // structurally by the `{hostID}-` wire prefix; ssh argv always passes `--`).
        #expect(!isSafeExternalName("-Sevil"))
        #expect(!isSafeExternalName(""))
        #expect(isSafeExternalName("scratch"))
        #expect(isValidIdent("10.40.12.22"))
    }
}

/// fork.json load-path safety: a bad or newer file must never be silently destroyed by the
/// autosave, and a clean launch must not rotate `.bak` for identical bytes.
struct PersistenceSafetyTests {
    private func tempStore() -> (ForkPersistence, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fork-persist-\(UUID().uuidString)", isDirectory: true)
        return (ForkPersistence(directory: dir), dir)
    }
    private func write(_ s: String, to dir: URL, name: String = "fork.json") {
        try? Data(s.utf8).write(to: dir.appendingPathComponent(name))
    }

    @Test func validationDropsArePreservedAside() {
        let (p, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var state = ForkPersistence.State()
        // The ssh target decodes fine but fails validation — the load must drop the host
        // and its tab (never hand an unvalidated string to a spawn) AND copy the original
        // aside so the drop is recoverable, not silently made permanent by the autosave.
        state.hosts = [ForkHost(id: "ok", label: "ok", transport: .local),
                       ForkHost(id: "bad", label: "bad", transport: .ssh(.init(host: "host;rm -rf /")))]
        state.tabs = [TabModel(id: UUID(), hostID: "bad", title: "doomed",
                               tree: .leaf(SessionRef(hostID: "bad", name: "work")))]
        p.save(state)
        let p2 = ForkPersistence(directory: dir)
        let loaded = p2.load()
        #expect(loaded.hosts.map(\.id) == ["ok"])
        #expect(loaded.tabs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("fork.json.invalid").path))
    }

    @Test func roundTripAndNoOpGate() {
        let (p, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var state = ForkPersistence.State()
        state.hosts = [ForkHost(id: "h1", label: "box", transport: .local)]
        state.tabs = [TabModel(id: UUID(), hostID: "h1", title: "t",
                               tree: .leaf(SessionRef(hostID: "h1", name: "acr")))]
        p.save(state)
        // Fresh instance: load seeds the no-op gate from disk, so re-saving the same state
        // must not create/rotate a .bak.
        let p2 = ForkPersistence(directory: dir)
        let loaded = p2.load()
        #expect(loaded.hosts.map(\.id) == ["h1"])
        #expect(loaded.tabs.count == 1)
        p2.save(loaded)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("fork.json.bak").path))
    }

    /// Full-fidelity round trip: every State field, nested splits, per-pane dicts, tags,
    /// hover commands — field-level equality, not just id/count checks. A Codable key
    /// dropped from any nested type shows up here.
    @Test func fullStateRoundTripsLosslessly() {
        let (p, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostID = "h1"
        let a = SessionRef(hostID: hostID, name: "left")
        let b = SessionRef(hostID: hostID, name: "right")
        let ext = SessionRef(hostID: hostID, name: "watcher", external: true)
        var tab = TabModel(id: UUID(), hostID: hostID, title: "work",
                           tree: .split(horizontal: true, ratio: 0.33,
                                        a: .leaf(a),
                                        b: .split(horizontal: false, ratio: 0.5,
                                                  a: .leaf(b), b: .leaf(ext))))
        tab.lastActive = ["left": Date(timeIntervalSince1970: 1_700_000_000)]
        tab.paneLabels = ["left": "build", "@watcher": "logs"]
        tab.paneTags = ["right": PaneTag(text: "prod", hue: 0.7)]
        tab.ccNames = ["left": "fixing-the-build"]
        tab.collapsed = true
        tab.pinned = true
        tab.dismissedAt = Date(timeIntervalSince1970: 1_700_000_100)
        var state = ForkPersistence.State()
        state.hosts = [ForkHost(id: hostID, label: "box",
                                transport: .ssh(.init(user: "me", host: "box")),
                                expanded: false, accentSlot: 42),
                       .local]
        state.tabs = [tab]
        state.activeTabID = tab.id
        state.recentTags = [PaneTag(text: "prod", hue: 0.7), PaneTag(text: "wip", hue: 0.1)]
        state.hoverCommands = ["g": HoverCommand(cmd: ["lazygit", "-p", "{cwd}"], mode: .pane)]
        p.save(state)
        let loaded = ForkPersistence(directory: dir).load()
        #expect(loaded.hosts == state.hosts)
        #expect(loaded.tabs == state.tabs)
        #expect(loaded.activeTabID == state.activeTabID)
        #expect(loaded.recentTags == state.recentTags)
        #expect(loaded.hoverCommands == state.hoverCommands)
    }

    @Test func undecodablePrimaryIsPreservedAndBakWins() {
        let (p, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A valid .bak behind a corrupt primary.
        let good = #"{"version":1,"hosts":[{"id":"h1","label":"box","transport":{"local":{}}}],"tabs":[]}"#
        write("{ not json", to: dir)
        write(good, to: dir, name: "fork.json.bak")
        let s = p.load()
        #expect(s.hosts.map(\.id) == ["h1"])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("fork.json.undecodable").path))
    }

    @Test func corruptPrimaryDoesNotRotateOverGoodBak() {
        let (p, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = #"{"version":1,"hosts":[{"id":"h1","label":"box","transport":{"local":{}}}],"tabs":[]}"#
        write("{ not json", to: dir)
        write(good, to: dir, name: "fork.json.bak")
        let s = p.load()
        #expect(s.hosts.map(\.id) == ["h1"])      // recovered from .bak
        // The first save after a .bak recovery must NOT rotate the still-corrupt primary
        // over the good .bak — if the new write then failed, no good copy would remain.
        p.save(s)
        let bak = (try? Data(contentsOf: dir.appendingPathComponent("fork.json.bak")))
            .map { String(decoding: $0, as: UTF8.self) }
        #expect(bak == good)
        // And the primary is valid again after that write.
        #expect(ForkPersistence(directory: dir).load().hosts.map(\.id) == ["h1"])
    }

    @Test func partialDecodeIsCopiedAside() {
        let (p, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Second host has an unknown transport case (the schema-change wipe class) — it is
        // dropped by the lenient decoder, and the original file must be preserved.
        let json = """
        {"version":1,"hosts":[
          {"id":"ok","label":"ok","transport":{"local":{}}},
          {"id":"bad","label":"bad","transport":{"warp":{"host":"x"}}}
        ],"tabs":[]}
        """
        write(json, to: dir)
        let s = p.load()
        #expect(s.hosts.map(\.id) == ["ok"])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("fork.json.partial").path))
    }

    @Test func newerVersionIsCopiedAside() {
        let (p, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"{"version":99,"hosts":[{"id":"h1","label":"box","transport":{"local":{}}}],"tabs":[]}"#
        write(json, to: dir)
        let s = p.load()
        #expect(s.hosts.map(\.id) == ["h1"])   // still loads best-effort
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("fork.json.newer").path))
    }

    @Test func bothUnreadableStartsFreshWithoutClobbering() {
        let (p, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        write("garbage", to: dir)
        write("also garbage", to: dir, name: "fork.json.bak")
        let s = p.load()
        #expect(s.hosts.isEmpty && s.tabs.isEmpty)
        // BOTH originals survive as their own copies (keyed on the source file) even though
        // the live files may be overwritten by the next save.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("fork.json.undecodable").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("fork.json.bak.undecodable").path))
    }
}

/// PATH export at install: inherited (launchd) entries keep the lead so system binaries
/// resolve exactly as before, login-shell entries append for everything launchd lacks,
/// nothing is duplicated, and only absolute segments survive.
struct BootstrapPATHTests {
    @Test func currentLeadsAndLoginAppends() {
        let merged = ForkBootstrap.mergedPATH(
            login: "/opt/homebrew/bin:/Users/u/code/bin:/usr/bin",
            current: "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(merged == "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/Users/u/code/bin")
    }

    @Test func emptyRelativeAndDuplicateSegmentsDrop() {
        // Empty (`::`) and relative (`bin`, `.`) segments never survive — a relative PATH
        // entry resolves against whatever cwd a child happens to have.
        #expect(ForkBootstrap.mergedPATH(login: ":/a/bin::bin:.:/b/bin:", current: "/a/bin:/usr/bin")
                == "/a/bin:/usr/bin:/b/bin")
        // Degenerate inputs stay sane (the caller skips export entirely on a failed probe).
        #expect(ForkBootstrap.mergedPATH(login: "", current: "/usr/bin:/bin") == "/usr/bin:/bin")
        #expect(ForkBootstrap.mergedPATH(login: "/a/bin:/b/bin:/a/bin", current: "") == "/a/bin:/b/bin")
    }
}
#endif
