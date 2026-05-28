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
