#if os(macOS)
import Foundation
import CryptoKit

/// Shell-safety identifier check. CLAUDE.md §Security: only validated names reach `Transport.wrap`.
private let identPattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9._-]+$"#)
func isValidIdent(_ s: String) -> Bool {
    identPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

/// A machine zmx sessions can run on.
struct ForkHost: Codable, Identifiable, Hashable {
    let id: String
    var label: String
    var transport: Transport
    var expanded: Bool = true
    var accentHue: Double?

    static let local = ForkHost(id: "local", label: "localhost", transport: .local)

    init(id: String, label: String, transport: Transport,
         expanded: Bool = true, accentHue: Double? = nil) {
        self.id = id; self.label = label; self.transport = transport
        self.expanded = expanded; self.accentHue = accentHue
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        transport = try c.decode(Transport.self, forKey: .transport)
        expanded = try c.decodeIfPresent(Bool.self, forKey: .expanded) ?? true
        accentHue = try c.decodeIfPresent(Double.self, forKey: .accentHue)
    }

    enum Transport: Codable, Hashable {
        case local
        case ssh(SSHTarget)

        var isLocal: Bool { if case .local = self { return true } else { return false } }
    }

    struct SSHTarget: Codable, Hashable {
        var user: String?
        var host: String

        var isValid: Bool { isValidIdent(host) && (user.map(isValidIdent) ?? true) }

        var connectionString: String { user.map { "\($0)@\(host)" } ?? host }
    }

    static func id(for target: SSHTarget) -> String {
        let digest = SHA256.hash(data: Data(target.connectionString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }
}

/// Stable reference to a zmx session. For fork-managed refs `name` is unprefixed and
/// `ZmxAdapter.wireName` adds `{hostID}-`; `external` refs use `name` verbatim.
struct SessionRef: Codable, Hashable {
    let hostID: ForkHost.ID
    let name: String
    var external: Bool

    init(hostID: ForkHost.ID, name: String, external: Bool = false) {
        self.hostID = hostID; self.name = name; self.external = external
    }

    /// Per-tab dict key — `name` alone collides when an external session shadows a
    /// tab-owned one with the same short name (zmx prefix is stripped). `@` is outside
    /// the validated charset so old non-external keys are unchanged.
    var key: String { external ? "@\(name)" : name }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        hostID = try c.decode(ForkHost.ID.self, forKey: .hostID)
        name = try c.decode(String.self, forKey: .name)
        external = try c.decodeIfPresent(Bool.self, forKey: .external) ?? false
    }

    var isValid: Bool { isValidIdent(name) }
}

/// A sidebar tab. The live `SplitTree<SurfaceView>` lives on the controller; this holds
/// only persistable shape (SPEC §6).
struct PaneTag: Codable, Hashable {
    var text: String
    var hue: Double
}

struct TabModel: Codable, Identifiable, Hashable {
    let id: UUID
    var hostID: ForkHost.ID
    var title: String
    var tree: PersistedTree
    /// Last-focused timestamp per pane, keyed by `SessionRef.key` (indices renumber, keys don't).
    var lastActive: [String: Date]
    /// User-set per-pane labels (⌘I / "Rename Pane…"), keyed by `SessionRef.key`. Shown in
    /// the sidebar over `surface.title`, which is per-`SurfaceView`-instance and lost on restart.
    var paneLabels: [String: String]
    var paneTags: [String: PaneTag]
    var collapsed: Bool

    init(id: UUID = UUID(), hostID: ForkHost.ID, title: String, tree: PersistedTree = .empty) {
        self.id = id
        self.hostID = hostID
        self.title = title
        self.tree = tree
        self.lastActive = [:]
        self.paneLabels = [:]
        self.paneTags = [:]
        self.collapsed = false
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        hostID = try c.decode(ForkHost.ID.self, forKey: .hostID)
        title = try c.decode(String.self, forKey: .title)
        tree = try c.decode(PersistedTree.self, forKey: .tree)
        lastActive = try c.decodeIfPresent([String: Date].self, forKey: .lastActive) ?? [:]
        paneLabels = try c.decodeIfPresent([String: String].self, forKey: .paneLabels) ?? [:]
        paneTags = try c.decodeIfPresent([String: PaneTag].self, forKey: .paneTags) ?? [:]
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
    }
}

/// Pure-value projection of a `SplitTree<Ghostty.SurfaceView>` for fork.json. Leaves carry
/// only the session ref — the live `SurfaceView` is reconstructed on activation (SPEC §7).
indirect enum PersistedTree: Codable, Hashable {
    case empty
    case leaf(SessionRef?)
    case split(horizontal: Bool, ratio: Double, a: PersistedTree, b: PersistedTree)

    var paneCount: Int {
        switch self {
        case .empty: 0
        case .leaf: 1
        case .split(_, _, let a, let b): a.paneCount + b.paneCount
        }
    }

    var leafRefs: [SessionRef] {
        switch self {
        case .empty: []
        case .leaf(let r): r.map { [$0] } ?? []
        case .split(_, _, let a, let b): a.leafRefs + b.leafRefs
        }
    }

    func removing(_ ref: SessionRef) -> PersistedTree {
        switch self {
        case .empty: .empty
        case .leaf(let r): r == ref ? .empty : self
        case .split(let h, let ratio, let a, let b):
            switch (a.removing(ref), b.removing(ref)) {
            case (.empty, let s), (let s, .empty): s
            case (let na, let nb): .split(horizontal: h, ratio: ratio, a: na, b: nb)
            }
        }
    }
}
#endif
