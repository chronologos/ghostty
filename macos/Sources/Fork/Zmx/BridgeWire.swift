#if os(macOS)
import Foundation

/// One line from `zmx-bridge` (the zmx fork's `bridge/README.md`, protocol 1). Only what the
/// sidebar uses is decoded; the protocol says readers ignore the rest.
///
/// Every string here was chosen by whatever runs in a pane on that host. The bridge has already
/// checked and defused it, which is no reason to trust the bridge's host: everything is stripped
/// and capped again on the way in.
enum BridgeMsg: Equatable {
    /// First line of every connection: forget what was known about this host.
    case hello(proto: Int, bridge: String)
    /// The whole current state of one session, replacing what was known about it.
    case set(BridgeSession)
    /// The session has ended.
    case del(name: String)
    /// Every session that exists has now been sent.
    case ready

    static let proto = 1

    /// nil for a line that isn't one of ours — malformed, or a kind from a later protocol.
    static func decode(_ line: Data) -> BridgeMsg? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: line) else { return nil }
        switch raw.t {
        case "hello":
            guard let proto = raw.proto else { return nil }
            return .hello(proto: proto, bridge: stripControl(raw.bridge ?? "", max: 32))
        case "set":
            return raw.session.flatMap(BridgeSession.init).map(BridgeMsg.set)
        case "del":
            return raw.name.flatMap(BridgeSession.wireName).map { .del(name: $0) }
        case "ready":
            return .ready
        default:
            return nil
        }
    }

    fileprivate struct Raw: Decodable {
        var t: String
        var proto: Int?
        var bridge: String?
        var name: String?
        var session: Session?

        struct Session: Decodable {
            var name: String
            var born: UInt64
            var seq: UInt64
            var now: Status?
        }
        struct Status: Decodable {
            var state: String
            var kind: String?
            var app: String?
            var msg: String?
            var source: String?
            var seq: UInt64
            var at: Int64
        }
    }
}

struct BridgeSession: Equatable {
    /// zmx's own name for it (`ZmxAdapter.wireName`), not a `SessionRef` name.
    var name: String
    var born: UInt64
    var seq: UInt64
    /// The one status the bridge picked to stand for the session.
    var now: BridgeStatus?

    /// A name is only ever *compared* with the wire names of sessions already in the sidebar,
    /// never turned into a `SessionRef`, so this needs to bound it, not validate it.
    fileprivate static func wireName(_ s: String) -> String? {
        s.isEmpty || s.utf8.count > 255 ? nil : s
    }

    fileprivate init?(_ r: BridgeMsg.Raw.Session) {
        guard let name = Self.wireName(r.name) else { return nil }
        self.init(name: name, born: r.born, seq: r.seq, now: r.now.flatMap(BridgeStatus.init))
    }

    init(name: String, born: UInt64, seq: UInt64, now: BridgeStatus?) {
        self.name = name; self.born = born; self.seq = seq; self.now = now
    }

    var link: PaneMachine.Link? {
        now.map { .init(state: $0.state, inferred: $0.inferred, stamp: .init(born: born, seq: $0.seq)) }
    }
}

struct BridgeStatus: Equatable {
    var state: PaneMachine.Link.State
    /// `permission` / `question` / `auth`, with `blocked` only.
    var kind: String?
    var app: String?
    var msg: String?
    /// Read into an OSC 9;4 progress bar rather than said by the program.
    var inferred: Bool
    var seq: UInt64
    var at: Date

    init(state: PaneMachine.Link.State, kind: String? = nil, app: String? = nil, msg: String? = nil,
         inferred: Bool = false, seq: UInt64, at: Date = .distantPast) {
        self.state = state; self.kind = kind; self.app = app; self.msg = msg
        self.inferred = inferred; self.seq = seq; self.at = at
    }

    /// An unknown state drops the status rather than guessing at it.
    fileprivate init?(_ r: BridgeMsg.Raw.Status) {
        let state: PaneMachine.Link.State
        switch r.state {
        case "idle": state = .idle
        case "done": state = .done
        case "working": state = .working
        case "error": state = .error
        case "blocked": state = .blocked
        default: return nil
        }
        func clean(_ s: String?, _ max: Int) -> String? {
            s.map { stripControl($0, max: max) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        self.init(state: state, kind: clean(r.kind, 16), app: clean(r.app, 32), msg: clean(r.msg, 512),
                  inferred: r.source != "status", seq: r.seq,
                  at: Date(timeIntervalSince1970: Double(r.at) / 1000))
    }

    /// The same facts in the shape every status view already reads. What the program says about
    /// itself replaces what the probe worked out from outside; what only the probe knows
    /// (the agent's name, cwd and control socket) stays.
    func overlaid(on base: CCProbe.Info?) -> CCProbe.Info {
        var i = base ?? .init()
        i.status = state == .working ? "busy" : state == .error ? "failed" : "idle"
        i.tempo = state == .blocked ? "blocked" : state == .working ? "active" : "idle"
        i.needs = state == .blocked ? msg : nil
        i.waitingFor = nil
        i.detail = state == .blocked ? nil : msg
        i.updatedAt = at
        return i
    }
}
#endif
