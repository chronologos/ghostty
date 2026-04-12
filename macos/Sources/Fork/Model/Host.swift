#if os(macOS)
import Foundation
import CryptoKit

/// A machine zmx sessions can run on.
struct ForkHost: Codable, Identifiable, Hashable {
    let id: String
    var label: String
    var transport: Transport
    var expanded: Bool = true

    static let local = ForkHost(id: "local", label: "localhost", transport: .local)

    enum Transport: Codable, Hashable {
        case local
        case ssh(SSHTarget)

        var isLocal: Bool { if case .local = self { return true } else { return false } }
    }

    struct SSHTarget: Codable, Hashable {
        var user: String?
        var host: String

        private static let pattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9._-]+$"#)
        var isValid: Bool {
            let okHost = Self.pattern.firstMatch(in: host, range: NSRange(host.startIndex..., in: host)) != nil
            let okUser = user.map { Self.pattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil } ?? true
            return okHost && okUser
        }

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

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        hostID = try c.decode(ForkHost.ID.self, forKey: .hostID)
        name = try c.decode(String.self, forKey: .name)
        external = try c.decodeIfPresent(Bool.self, forKey: .external) ?? false
    }

    private static let pattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9._-]+$"#)
    var isValid: Bool {
        Self.pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }
}

/// A sidebar tab. The live `SplitTree<SurfaceView>` lives on the controller; this holds
/// only persistable shape (SPEC §6).
struct TabModel: Codable, Identifiable, Hashable {
    let id: UUID
    var hostID: ForkHost.ID
    var title: String
    var tree: PersistedTree

    init(id: UUID = UUID(), hostID: ForkHost.ID, title: String, tree: PersistedTree = .empty) {
        self.id = id
        self.hostID = hostID
        self.title = title
        self.tree = tree
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
}
#endif
