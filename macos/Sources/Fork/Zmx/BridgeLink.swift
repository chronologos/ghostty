#if os(macOS)
import Foundation

/// One long-lived `zmx-bridge` per host: a child process locally, `ssh host zmx-bridge`
/// remotely. It pushes each session's state the moment it changes, which is what the 3s/15s poll
/// can't do. The link only carries lines; what they mean is `SessionRegistry.noteBridge`.
///
/// Everything here is allowed to fail. A host without the bridge (or with an older zmx, whose
/// daemons publish nothing) just never says anything, and the poll + `CCProbe` carry on as
/// before.
@MainActor
final class BridgeLink {
    enum Phase: Equatable {
        case stopped
        case connecting
        /// `ready` seen on this connection.
        case live
        case waiting
        /// Not installed there, or speaks a protocol we don't. Asked again rarely.
        case absent
    }

    private(set) var phase: Phase = .stopped
    private let argv: [String]
    private let label: String
    private let deliver: ([BridgeMsg]) -> Void
    private let down: () -> Void

    private var process: Process?
    private var stdin: FileHandle?
    private var retry: Task<Void, Never>?
    private var failures = 0
    /// Bumped on every start/stop, so a callback from a connection that is no longer the
    /// current one can tell.
    private var generation = 0

    /// One session is at most ~200 KB on the wire (64 records of 2 KB text, twice).
    private nonisolated static let maxLine = 1 << 20
    /// The bridge sends at most ~33 batches a second. Far past that is not a bridge.
    private nonisolated static let maxPerSecond = 5000
    static let absentRetry: TimeInterval = 600

    /// `argv` is run as-is (via `env`, like `ZmxAdapter.run`): build it with
    /// `ZmxAdapter.bridgeArgv`, the only place that knows the command.
    init(argv: [String], label: String,
         deliver: @escaping ([BridgeMsg]) -> Void, down: @escaping () -> Void) {
        self.argv = argv; self.label = label; self.deliver = deliver; self.down = down
    }

    func start() {
        guard phase == .stopped else { return }
        connect()
    }

    func stop() {
        generation += 1
        retry?.cancel(); retry = nil
        hangUp()
        phase = .stopped
        failures = 0
    }

    /// Closing its stdin is how the bridge is told to go (over ssh too); the signal is for an
    /// ssh that is stuck connecting.
    private func hangUp() {
        try? stdin?.close(); stdin = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    private func connect() {
        generation += 1
        let gen = generation
        phase = .connecting

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        /// Touched only on `q`.
        final class Reader: @unchecked Sendable {
            var buf = Data()
            var err = Data()
            var windowStart = DispatchTime.now()
            var inWindow = 0
            var poisoned = false
        }
        let q = DispatchQueue(label: "fork.bridge.read")
        let r = Reader()
        // Main-queue hops, not `Task { @MainActor }`: batches must arrive in the order read.
        let toMain: @Sendable (@escaping @MainActor (BridgeLink) -> Void) -> Void = { [weak self] body in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == gen else { return }
                    body(self)
                }
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            q.async {
                guard !r.poisoned else { return }
                r.buf.append(chunk)
                var msgs: [BridgeMsg] = []
                while let nl = r.buf.firstIndex(of: 0x0A) {
                    if let m = BridgeMsg.decode(r.buf[r.buf.startIndex..<nl]) { msgs.append(m) }
                    r.buf.removeSubrange(r.buf.startIndex...nl)
                }
                let now = DispatchTime.now()
                if now.uptimeNanoseconds - r.windowStart.uptimeNanoseconds > 1_000_000_000 {
                    r.windowStart = now; r.inWindow = 0
                }
                r.inWindow += msgs.count
                if r.buf.count > Self.maxLine || r.inWindow > Self.maxPerSecond {
                    r.poisoned = true
                    r.buf = Data()
                    toMain { $0.ended(status: nil, stderr: "flooding") }
                    return
                }
                if !msgs.isEmpty { toMain { $0.received(msgs) } }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            q.async { if r.err.count < 4096 { r.err.append(chunk) } }
        }
        p.terminationHandler = { t in
            let status = t.terminationStatus
            // Behind whatever the read handlers have already queued, so the last lines land
            // before the connection is declared over.
            q.asyncAfter(deadline: .now() + 0.05) {
                let msg = stripControl(String(decoding: r.err.suffix(256), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines), max: 256)
                toMain { $0.ended(status: status, stderr: msg) }
            }
        }

        do { try p.run() } catch {
            ended(status: 127, stderr: "\(error.localizedDescription)")
            return
        }
        try? inPipe.fileHandleForReading.close()
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        process = p
        stdin = inPipe.fileHandleForWriting
    }

    private func received(_ msgs: [BridgeMsg]) {
        for case .hello(let proto, _) in msgs where proto != BridgeMsg.proto {
            ended(status: nil, stderr: "protocol \(proto)", absent: true)
            return
        }
        if msgs.contains(.ready) { phase = .live; failures = 0 }
        deliver(msgs)
    }

    /// `status` nil = we are the ones ending it.
    private func ended(status: Int32?, stderr: String, absent: Bool = false) {
        generation += 1          // nothing more from that connection
        let wasTalking = phase == .live
        hangUp()
        down()
        // 127: no such command (`env` locally, the login shell over ssh). 2 / 64: it ran and
        // refused (no zmx beside it, a facts directory it won't trust, flags it doesn't know).
        // None of those gets better in a minute. Anything else (255 = ssh itself, a signal, a
        // dropped network) is worth coming back to soon.
        let gone = absent || status == 127 || status == 2 || status == 64
        failures = wasTalking ? 0 : failures + 1
        let delay = gone ? Self.absentRetry : min(60, pow(2, Double(min(failures, 6))))
        phase = gone ? .absent : .waiting
        ForkBootstrap.logger.info("""
            bridge \(self.label, privacy: .public): ended \
            status=\(status.map(String.init) ?? "-", privacy: .public) \
            \(stderr, privacy: .public); retry in \(Int(delay), privacy: .public)s
            """)
        let gen = generation
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.generation == gen else { return }
            self.connect()
        }
    }
}
#endif
