#if os(macOS)
import Foundation

/// Atomic-write JSON store for the fork's state (SPEC §6).
struct ForkPersistence {
    struct State: Codable {
        var version = 1
        var hosts: [ForkHost] = []
        var tabs: [TabModel] = []
        var activeTabID: TabModel.ID?

        init(version: Int = 1, hosts: [ForkHost] = [], tabs: [TabModel] = [],
             activeTabID: TabModel.ID? = nil) {
            self.version = version; self.hosts = hosts; self.tabs = tabs
            self.activeTabID = activeTabID
        }

        /// Lenient: drops individually-undecodable hosts/tabs instead of failing the whole
        /// state (e.g. an unknown `Transport` enum case from a schema change).
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            hosts = (try? c.decode([Lossy<ForkHost>].self, forKey: .hosts))?.compactMap(\.value) ?? []
            tabs = (try? c.decode([Lossy<TabModel>].self, forKey: .tabs))?.compactMap(\.value) ?? []
            activeTabID = try c.decodeIfPresent(TabModel.ID.self, forKey: .activeTabID)
        }
    }

    /// Per-element error sink so one bad array entry doesn't poison its siblings.
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from d: Decoder) throws { value = try? T(from: d) }
    }

    private let url: URL
    private var bakURL: URL { url.appendingPathExtension("bak") }

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("fork.json")
    }

    func load() -> State {
        for candidate in [url, bakURL] {
            guard let data = try? Data(contentsOf: candidate),
                  let s = try? JSONDecoder().decode(State.self, from: data) else { continue }
            return validated(s)
        }
        return State()
    }

    func save(_ state: State?) {
        guard let state else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(state) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: bakURL)
            try? FileManager.default.copyItem(at: url, to: bakURL)
        }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
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

    /// `isValid` is the managed-name regex; external refs come from `zmx list` verbatim
    /// and `shq` covers them at the shell boundary.
    private func scrub(_ tree: PersistedTree) -> PersistedTree {
        switch tree {
        case .empty: return .empty
        case .leaf(let ref): return .leaf(ref.flatMap { $0.external || $0.isValid ? $0 : nil })
        case .split(let h, let r, let a, let b): return .split(horizontal: h, ratio: r, a: scrub(a), b: scrub(b))
        }
    }
}
#endif
