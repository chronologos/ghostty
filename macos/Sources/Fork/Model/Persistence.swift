#if os(macOS)
import Foundation

/// Atomic-write JSON store for the fork's state (SPEC §6).
struct ForkPersistence {
    struct State: Codable {
        var version = 1
        var hosts: [ForkHost] = []
        var tabs: [TabModel] = []
        var activeTabID: TabModel.ID?
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
        try? FileManager.default.copyItem(at: url, to: bakURL)
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
            case .ssh(let t), .et(let t): return t.isValid
            }
        }
        let validIDs = Set(out.hosts.map(\.id))
        out.tabs = s.tabs.filter { validIDs.contains($0.hostID) }
        return out
    }
}
#endif
