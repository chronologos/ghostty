#if os(macOS)
import Foundation
import Combine

/// Single source of truth for hosts, tabs, and the surface→session map. Sidebar and
/// controller observe this; all mutations route through it (SPEC §3).
@MainActor
final class SessionRegistry: ObservableObject {
    static let shared = SessionRegistry()

    @Published private(set) var hosts: [ForkHost]
    @Published private(set) var tabs: [TabModel]
    @Published private(set) var refs: [UUID: SessionRef] = [:]
    @Published private(set) var activeTabID: TabModel.ID?

    private let persistence = ForkPersistence()
    private var saveDebounce: AnyCancellable?

    private init() {
        let state = persistence.load()
        self.hosts = state.hosts.isEmpty ? [.local] : state.hosts
        self.tabs = state.tabs
        self.activeTabID = state.activeTabID
        saveDebounce = objectWillChange
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.persistence.save(self?.snapshot()) }
    }

    // MARK: Queries

    func host(id: ForkHost.ID) -> ForkHost? { hosts.first { $0.id == id } }
    func tabs(on hostID: ForkHost.ID) -> [TabModel] { tabs.filter { $0.hostID == hostID } }
    var activeTab: TabModel? { activeTabID.flatMap { id in tabs.first { $0.id == id } } }
    var activeHost: ForkHost? { activeTab.flatMap { host(id: $0.hostID) } }

    /// `connected` iff ≥1 surface bound to a session on this host (SPEC §3: status is computed).
    func isConnected(_ hostID: ForkHost.ID) -> Bool {
        refs.values.contains { $0.hostID == hostID }
    }

    // MARK: Mutations

    func addHost(_ h: ForkHost) {
        guard host(id: h.id) == nil else { return }
        hosts.append(h)
    }

    func setExpanded(_ hostID: ForkHost.ID, _ v: Bool) {
        guard let i = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        hosts[i].expanded = v
    }

    @discardableResult
    func newTab(on hostID: ForkHost.ID, title: String) -> TabModel {
        let t = TabModel(hostID: hostID, title: title)
        tabs.append(t)
        return t
    }

    func renameTab(_ id: TabModel.ID, to title: String) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[i].title = title
    }

    func removeTab(_ id: TabModel.ID) {
        tabs.removeAll { $0.id == id }
        if activeTabID == id { activeTabID = nil }
    }

    func setActive(tab id: TabModel.ID) { activeTabID = id }

    func bind(surface: UUID, to ref: SessionRef) { refs[surface] = ref }
    func unbind(surface: UUID) { refs.removeValue(forKey: surface) }

    func setPersistedTree(_ tree: PersistedTree, for tabID: TabModel.ID) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[i].tree = tree
    }

    // MARK: Persistence

    func snapshot() -> ForkPersistence.State {
        .init(hosts: hosts, tabs: tabs, activeTabID: activeTabID)
    }

    static func autoName() -> String {
        let alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
        let suffix = String((0..<3).map { _ in alphabet.randomElement()! })
        return "shell-\(suffix)"
    }
}
#endif
