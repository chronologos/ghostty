#if os(macOS)
import Foundation
import Testing
@testable import Ghostty

/// `ZmxAdapter.run` liveness contract. These spawn real `/bin/sh` children on purpose —
/// the bug class they pin (a wedged CC poll loop) only exists at the process boundary.
struct RunCommandTests {
    @Test func capturesStdoutOnZeroExit() async throws {
        let out = try await ZmxAdapter.run(argv: ["/bin/sh", "-c", "printf hello"], timeout: 5)
        #expect(out == "hello")
        // zmx kill's normal shape: zero bytes of stdout is still a success.
        let empty = try await ZmxAdapter.run(argv: ["/usr/bin/true"], timeout: 5)
        #expect(empty == "")
    }

    @Test func largeOutputArrivesCompleteAndOrdered() async throws {
        // ~1.5MB across many 64KB pipe chunks — ⌘⇧K history must arrive intact and in order.
        let out = try await ZmxAdapter.run(argv: ["/bin/sh", "-c", "/usr/bin/seq 1 200000"], timeout: 10)
        let lines = out.split(separator: "\n")
        #expect(lines.count == 200_000)
        #expect(lines.first == "1")
        #expect(lines.last == "200000")
    }

    @Test func missingExecutableThrowsCommandError() async {
        do {
            _ = try await ZmxAdapter.run(argv: ["/nonexistent/fork-test-\(UUID().uuidString)"], timeout: 5)
            Issue.record("expected CommandError")
        } catch let e as ZmxAdapter.CommandError {
            #expect(e.status == 127)   // env: command not found
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func taskCancellationPropagatesPromptly() async {
        let t0 = Date()
        let task = Task { try await ZmxAdapter.run(argv: ["/bin/sleep", "30"], timeout: 30) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        if case .failure(let error) = await task.result {
            #expect(error is CancellationError)
        } else {
            Issue.record("expected CancellationError")
        }
        // run()'s own timeout is 30s — finishing fast proves the cancellation did it.
        #expect(Date().timeIntervalSince(t0) < 5)
    }

    /// The anti-wedge contract itself: stdout closes but the exit is never observed (here the
    /// child genuinely hasn't exited). After the grace the group is killed and the call
    /// reports "exit status unobserved" as a failure — never a hang, never fake success.
    @Test func unobservedExitResolvesAsFailureAfterGrace() async {
        let t0 = Date()
        do {
            _ = try await ZmxAdapter.run(
                argv: ["/bin/sh", "-c", "printf out; exec 1>&-; sleep 30"], timeout: 10)
            Issue.record("expected CommandError")
        } catch let e as ZmxAdapter.CommandError {
            #expect(e.status == -1)
            #expect(e.stderr.contains("unobserved"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(Date().timeIntervalSince(t0) < 5)   // via the grace, not the deadline or the sleep
    }

    @Test func nonZeroExitThrowsWithStderrTail() async {
        do {
            _ = try await ZmxAdapter.run(argv: ["/bin/sh", "-c", "echo oops >&2; exit 3"], timeout: 5)
            Issue.record("expected CommandError")
        } catch let e as ZmxAdapter.CommandError {
            #expect(e.status == 3)
            #expect(e.stderr.contains("oops"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func timeoutKillsAndThrowsPromptly() async {
        let t0 = Date()
        do {
            _ = try await ZmxAdapter.run(argv: ["/bin/sleep", "30"], timeout: 0.5)
            Issue.record("expected timeout")
        } catch {
            #expect(error is CancellationError)
        }
        // The point is liveness, not precision: well under the old wedge, never 30s.
        #expect(Date().timeIntervalSince(t0) < 5)
    }

    /// A grandchild that inherits the stdout write-end (ssh ControlMaster masters,
    /// ProxyCommand helpers) must not stall completion past the grace window — and must
    /// not be killed either, since a surviving helper is often the point (a freshly
    /// established master). The marker file pins the survival half: it's only written
    /// after `run` has already returned.
    @Test func backgroundedGrandchildDoesNotStallCompletionAndSurvives() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("fork-run-grandchild-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let t0 = Date()
        let out = try await ZmxAdapter.run(
            argv: ["/bin/sh", "-c", "(sleep 3; touch \(marker.path)) & printf held"], timeout: 10)
        #expect(out == "held")
        #expect(Date().timeIntervalSince(t0) < 5)   // settled via the grace, not the sleep
        var survived = false
        for _ in 0..<40 where !survived {
            if FileManager.default.fileExists(atPath: marker.path) { survived = true; break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        #expect(survived)
    }
}
#endif
