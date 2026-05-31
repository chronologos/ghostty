#if os(macOS)
import Foundation

/// Atomic-write JSON store for the fork's state (SPEC §6). A class so `save` can keep the
/// last-written bytes for the no-op gate below.
final class ForkPersistence {
    struct State: Codable {
        var version = 1
        var hosts: [ForkHost] = []
        var tabs: [TabModel] = []
        var activeTabID: TabModel.ID?
        var recentTags: [PaneTag] = []
        var hoverCommands: [String: HoverCommand] = [:]

        init(version: Int = 1, hosts: [ForkHost] = [], tabs: [TabModel] = [],
             activeTabID: TabModel.ID? = nil, recentTags: [PaneTag] = [],
             hoverCommands: [String: HoverCommand] = [:]) {
            self.version = version; self.hosts = hosts; self.tabs = tabs
            self.activeTabID = activeTabID; self.recentTags = recentTags
            self.hoverCommands = hoverCommands
        }

        /// Lenient: drops individually-undecodable hosts/tabs instead of failing the whole
        /// state (e.g. an unknown `Transport` enum case from a schema change).
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            hosts = (try? c.decode([Lossy<ForkHost>].self, forKey: .hosts))?.compactMap(\.value) ?? []
            tabs = (try? c.decode([Lossy<TabModel>].self, forKey: .tabs))?.compactMap(\.value) ?? []
            activeTabID = try c.decodeIfPresent(TabModel.ID.self, forKey: .activeTabID)
            // Lossy like its siblings: one malformed hand-edited tag (e.g. a hue typed as a
            // string) must not fail the whole State decode — that would route fork.json
            // through the "undecodable" path and load .bak / empty. A dropped recent tag is
            // harmless: the MRU list is rebuilt from live paneTags by pruneRecentTags.
            recentTags = (try? c.decode([Lossy<PaneTag>].self, forKey: .recentTags))?
                .compactMap(\.value) ?? []
            hoverCommands = (try? c.decode([String: Lossy<HoverCommand>].self, forKey: .hoverCommands))?
                .compactMapValues(\.value) ?? [:]
        }
    }

    /// Per-element error sink so one bad array entry doesn't poison its siblings.
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from d: Decoder) throws { value = try? T(from: d) }
    }

    private let url: URL
    private var bakURL: URL { url.appendingPathExtension("bak") }
    /// Last successfully-written encoding. The autosave is driven by `objectWillChange`,
    /// which also fires for state that isn't persisted (ccLive poll ticks, pane status) —
    /// without this gate an actively-working CC session rewrites a byte-identical
    /// fork.json + .bak every few seconds for as long as it runs. `.sortedKeys` makes the
    /// encoding deterministic, so a byte compare is a content compare.
    private var lastWritten: Data?
    /// Set when this launch's `load()` couldn't read or decode the *primary* — the first
    /// `save()` must then skip the `.bak` rotation, or it would copy the bad primary over
    /// a possibly-good `.bak` (the exact recovery copy `load()` just fell back to) before
    /// writing. Cleared once a write succeeds (the primary is good again).
    private var primaryWasBad = false

    convenience init() {
        // Unsandboxed test host resolves `.applicationSupportDirectory` to the real
        // home — `xcodebuild test` would clobber the developer's fork.json via the
        // singleton's debounced save sink. Redirect under XCTest.
        let base = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            ? FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-fork-tests", isDirectory: true)
            : FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        self.init(directory: base)
    }

    /// Test seam: persistence rooted in an arbitrary directory.
    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.url = directory.appendingPathComponent("fork.json")
    }

    func load() -> State {
        for candidate in [url, bakURL] {
            guard let data = try? Data(contentsOf: candidate) else {
                if candidate == url { primaryWasBad = true }
                continue
            }
            guard let s = try? JSONDecoder().decode(State.self, from: data) else {
                // Undecodable (corrupt / hand-edit gone wrong / future top-level change):
                // copy it aside *now* — the debounced autosave would otherwise overwrite
                // it with whatever loads next, and the save after that rotates the same
                // loss into `.bak`, making it permanent.
                preserve(candidate, reason: "undecodable")
                if candidate == url { primaryWasBad = true }
                continue
            }
            if s.version > State().version {
                // Written by a newer build. The lenient decoder may have silently dropped
                // fields it doesn't know; keep the original so the newer build can still
                // read its own state back after a downgrade-then-upgrade round trip.
                preserve(candidate, reason: "newer")
            } else if lossyDropCount(in: data, decoded: s) > 0 {
                // Per-element decode failures (the unknown-`Transport`-case class of schema
                // change): the state still loads, minus those entries — preserve the
                // original before the autosave makes the loss permanent.
                preserve(candidate, reason: "partial")
            }
            // Seed the no-op gate with what's actually on disk so the first debounced save
            // after launch doesn't rotate `.bak` for a byte-identical file.
            if candidate == url { lastWritten = data }
            // Validation drops (ssh host with an invalid target → that host and every tab on
            // it; shell-unsafe ref names → nil'd leaves) are the same loss class as decode
            // drops — the autosave makes them permanent within seconds — but they happen
            // *after* the decode-level preserve checks above. Copy aside before returning
            // the reduced state.
            let v = validated(s)
            if v.hosts.count < s.hosts.count || v.tabs.count < s.tabs.count
                || leafCount(v.tabs) < leafCount(s.tabs) {
                preserve(candidate, reason: "invalid")
            }
            return v
        }
        return State()
    }

    private func leafCount(_ tabs: [TabModel]) -> Int {
        tabs.reduce(0) { $0 + $1.tree.leafRefs.count }
    }

    /// Copy a problematic state file aside (e.g. `fork.json.undecodable`,
    /// `fork.json.bak.partial`) so the autosave can't destroy the only good copy. Keyed on
    /// the *source* file so a bad primary and a bad `.bak` in the same load don't clobber
    /// each other's copy; overwrites a previous copy of the same kind — one generation per
    /// failure class is enough to recover by hand.
    private func preserve(_ file: URL, reason: String) {
        let dest = file.appendingPathExtension(reason)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: file, to: dest)
        ForkBootstrap.logger.error(
            "fork state \(file.lastPathComponent) is \(reason); copied aside to \(dest.lastPathComponent)")
    }

    /// How many elements the lenient decoder dropped, judged against the raw JSON — the
    /// signal that a schema change (or hand-edit typo) is silently eating state.
    /// `hoverCommands` counts too: they're hand-edited with no other source of truth, so a
    /// dropped one (e.g. an unknown `mode`) is unrecoverable once the autosave runs.
    private func lossyDropCount(in data: Data, decoded: State) -> Int {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        let rawHosts = (obj["hosts"] as? [Any])?.count ?? 0
        let rawTabs = (obj["tabs"] as? [Any])?.count ?? 0
        let rawHover = (obj["hoverCommands"] as? [String: Any])?.count ?? 0
        return max(0, rawHosts - decoded.hosts.count)
            + max(0, rawTabs - decoded.tabs.count)
            + max(0, rawHover - decoded.hoverCommands.count)
    }

    func save(_ state: State?) {
        guard let state else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(state) else { return }
        guard data != lastWritten else { return }
        // Never rotate a primary this launch couldn't decode over the `.bak` we may have
        // just recovered from — if the write below then failed, no good copy would remain.
        if FileManager.default.fileExists(atPath: url.path), !primaryWasBad {
            try? FileManager.default.removeItem(at: bakURL)
            try? FileManager.default.copyItem(at: url, to: bakURL)
        }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            // Only on success — a failed write must retry on the next tick.
            lastWritten = data
            primaryWasBad = false
        } catch {
            ForkBootstrap.logger.error("fork.json write failed: \(error.localizedDescription)")
        }
    }

    /// Re-validate decoded state before any spawn (SPEC §4). Drops invalid hosts/refs.
    private func validated(_ s: State) -> State {
        var out = s
        out.hosts = s.hosts.filter {
            switch $0.transport {
            case .local: return true
            case .ssh(let t): return t.isValid
            }
        }
        let validIDs = Set(out.hosts.map(\.id))
        out.tabs = s.tabs.compactMap { tab in
            guard validIDs.contains(tab.hostID) else { return nil }
            var t = tab
            t.tree = scrub(tab.tree)
            return t
        }
        if let id = out.activeTabID, !out.tabs.contains(where: { $0.id == id }) {
            out.activeTabID = out.tabs.first?.id
        }
        return out
    }

    /// `isValid` is the managed-name regex; external refs only get the `isSafeExternalName`
    /// rule (shared with `ZmxAdapter.partition`) — `shq` covers them at the shell boundary.
    private func scrub(_ tree: PersistedTree) -> PersistedTree {
        switch tree {
        case .empty: return .empty
        case .leaf(let ref):
            return .leaf(ref.flatMap {
                ($0.external ? isSafeExternalName($0.name) : $0.isValid) ? $0 : nil
            })
        case .split(let h, let r, let a, let b): return .split(horizontal: h, ratio: r, a: scrub(a), b: scrub(b))
        }
    }
}
#endif
