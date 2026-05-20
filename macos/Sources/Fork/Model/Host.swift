#if os(macOS)
import Foundation
import CryptoKit

/// Shell-safety identifier check. CLAUDE.md §Security: only validated names reach `Transport.wrap`.
/// `\A…\z` not `^…$` — ICU `$` matches before a trailing line terminator, so `"foo\n"` would pass.
private let identPattern = try! NSRegularExpression(pattern: #"\A[A-Za-z0-9._-]+\z"#)
func isValidIdent(_ s: String) -> Bool {
    identPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

/// A machine zmx sessions can run on.
struct ForkHost: Codable, Identifiable, Hashable {
    let id: String
    var label: String
    var transport: Transport
    var expanded: Bool = true
    /// `palette` index pair encoded as `a*N+b`; `a==b` ⇒ solid. Resolved at add/load time
    /// (`resolveAutoSlots`) so deleting host A can't shift host B's color.
    var accentSlot: Int?

    static let local = ForkHost(id: "local", label: "localhost", transport: .local)

    /// 10 hand-picked hue stops; rendered at sat 0.45 / bright 0.7. Slot space = N², solids
    /// on the diagonal (`i*N+i`).
    static let palette: [Double] = [0.00, 0.08, 0.13, 0.24, 0.34, 0.45, 0.54, 0.63, 0.74, 0.88]
    static let N = palette.count, slotCount = N * N
    static func pair(_ s: Int) -> (a: Int, b: Int) { ((s / N) % N, s % N) }
    var slot: Int { accentSlot ?? Self.autoSlot(for: id, avoiding: []) }

    /// FNV-1 → preferred solid, probe the diagonal (hosts 1–N get clean solids), then
    /// linear over the whole space (revisits diagonals harmlessly). Storage is what makes
    /// the result stable — see `resolveAutoSlots`.
    static func autoSlot(for id: String, avoiding taken: Set<Int>) -> Int {
        let h = Int(id.utf8.reduce(UInt32(2166136261)) { ($0 &* 16777619) ^ UInt32($1) })
        let c = h % N
        for i in 0..<N { let d = (c+i) % N; if !taken.contains(d*N + d) { return d*N + d } }
        for i in 0..<slotCount { let s = (c*N + c + i) % slotCount; if !taken.contains(s) { return s } }
        return c*N + c
    }

    init(id: String, label: String, transport: Transport,
         expanded: Bool = true, accentSlot: Int? = nil) {
        self.id = id; self.label = label; self.transport = transport
        self.expanded = expanded; self.accentSlot = accentSlot
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, transport, expanded, accentSlot
        case accentHue   // phantom — legacy migration only; drop with `encode(to:)` once
                         // every fork.json has been re-saved (one release)
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        transport = try c.decode(Transport.self, forKey: .transport)
        expanded = try c.decodeIfPresent(Bool.self, forKey: .expanded) ?? true
        // Clamp — fork.json is hand-editable; an out-of-range slot would reach
        // `palette[-1]` via `pair().a` (Swift `%` keeps the dividend's sign) and trap on
        // launch. nil → `resolveAutoSlots` re-derives. Migrate legacy `accentHue` →
        // nearest-palette solid.
        if let s = try c.decodeIfPresent(Int.self, forKey: .accentSlot) {
            accentSlot = (0..<Self.slotCount).contains(s) ? s : nil
        } else if let h = try c.decodeIfPresent(Double.self, forKey: .accentHue) {
            let i = Self.palette.enumerated().min { abs($0.1 - h) < abs($1.1 - h) }!.0
            accentSlot = i * Self.N + i
        }
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(label, forKey: .label)
        try c.encode(transport, forKey: .transport); try c.encode(expanded, forKey: .expanded)
        try c.encodeIfPresent(accentSlot, forKey: .accentSlot)
    }

    enum Transport: Codable, Hashable {
        case local
        case ssh(SSHTarget)

        var isLocal: Bool { if case .local = self { return true } else { return false } }
        var displayConnection: String {
            switch self { case .local: "local"; case .ssh(let t): t.connectionString }
        }
    }

    struct SSHTarget: Codable, Hashable {
        var user: String?
        var host: String

        var isValid: Bool { isValidIdent(host) && (user.map(isValidIdent) ?? true) }

        var connectionString: String { user.map { "\($0)@\(host)" } ?? host }

        /// Inverse of `connectionString`. nil if `!isValid`.
        init?(parsing s: String) {
            let s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let p = s.split(separator: "@", maxSplits: 1).map(String.init)
            self = p.count == 2 ? .init(user: p[0], host: p[1]) : .init(user: nil, host: s)
            guard isValid else { return nil }
        }
        init(user: String? = nil, host: String) { self.user = user; self.host = host }
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

/// User-defined hover-key action (`fork.json` `hoverCommands`). `cmd` is an argv array;
/// `{cwd}`/`{ref}`/`{host}` placeholders are whole-token-substituted by `ZmxAdapter.expand`
/// — never string-interpolated into a shell line (CLAUDE.md §Security).
struct HoverCommand: Codable, Hashable {
    enum Mode: String, Codable { case pane, local, overlay }
    var cmd: [String]
    var mode: Mode
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
    /// Last-seen CC session name per pane (CCProbe write-through). Shown dimmed when the
    /// live probe has nothing — i.e. the agent has exited but the zmx shell remains.
    var ccNames: [String: String]
    var collapsed: Bool
    var pinned: Bool
    /// Set by `dismissFromFocus`; `focusTabs` hides the tab while non-nil and `> mru`.
    /// Cleared by `touchPane` on activate (and by `setPinned(true)`).
    var dismissedAt: Date?

    var hasTag: Bool { tree.leafRefs.contains { paneTags[$0.key] != nil } }

    init(id: UUID = UUID(), hostID: ForkHost.ID, title: String, tree: PersistedTree = .empty) {
        self.id = id
        self.hostID = hostID
        self.title = title
        self.tree = tree
        self.lastActive = [:]
        self.paneLabels = [:]
        self.paneTags = [:]
        self.ccNames = [:]
        self.collapsed = false
        self.pinned = false
        self.dismissedAt = nil
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
        ccNames = try c.decodeIfPresent([String: String].self, forKey: .ccNames) ?? [:]
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        dismissedAt = try c.decodeIfPresent(Date.self, forKey: .dismissedAt)
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

    /// Remove the first (leftmost depth-first) leaf matching `ref`. The split-picker lets a
    /// tab attach the same session twice, so remove-all would over-prune `[a,a]` → `.empty`
    /// and desync `movePanePersisted`/`mergeTab` from the controller's single-surface move.
    func removing(_ ref: SessionRef) -> PersistedTree {
        switch self {
        case .empty: return .empty
        case .leaf(let r): return r == ref ? .empty : self
        case .split(let h, let ratio, let a, let b):
            let na = a.removing(ref)
            let nb = na == a ? b.removing(ref) : b
            switch (na, nb) {
            case (.empty, let s), (let s, .empty): return s
            case (let na, let nb): return .split(horizontal: h, ratio: ratio, a: na, b: nb)
            }
        }
    }

    /// Append a leaf to the right. Empty → `.leaf(ref)`; non-empty → horizontal split
    /// 50/50 with `self` on the left. Matches the ⌘D `newSplit(direction: .right)` shape
    /// so "move pane into tab" feels like "split off the right".
    func appending(leaf ref: SessionRef) -> PersistedTree {
        switch self {
        case .empty: .leaf(ref)
        default: .split(horizontal: true, ratio: 0.5, a: self, b: .leaf(ref))
        }
    }

    /// Concat `other`'s leaves into `self` via repeated `appending(leaf:)`. Preserves
    /// `self`'s internal shape; `other`'s shape is flattened. Merging with both shapes
    /// intact would nest into an unreadable tree — explicit flatten is the lesser evil.
    func merging(_ other: PersistedTree) -> PersistedTree {
        other.leafRefs.reduce(self) { $0.appending(leaf: $1) }
    }
}
#endif
