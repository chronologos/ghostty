#if os(macOS)
import AppKit
import Combine
import UserNotifications

/// UN delegate proxy: fork notifications carry `userInfo["forkTab"]` and short-circuit
/// here (foreground banner + click→`activate(tab:)`); everything else forwards to the
/// wrapped upstream `AppDelegate`. Upstream's own chain (`shouldPresentNotification`
/// Ghostty.App.swift:449, `handleUserNotification` :2248) gates on `findSurface(forUUID:)`
/// which only walks the *active* `surfaceTree`, so a parked-tab pane would otherwise be
/// dropped at both `willPresent` and `didReceive`.
final class ForkNotify: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForkNotify()
    // Set once on main during `install()`, read from delegate callbacks (arbitrary queue).
    nonisolated(unsafe) private weak var wrapped: UNUserNotificationCenterDelegate?
    @MainActor private var badgeSub: AnyCancellable?

    /// Seam #1 fires in `applicationWillFinishLaunching`, but upstream sets
    /// `center.delegate = self` later, inside `applicationDidFinishLaunching` — the fork
    /// must wrap that assignment, not get overwritten by it. A bare main-queue dispatch
    /// from the seam is NOT safe: the run loop can drain the queue *between* will- and
    /// did-FinishLaunching (Apple Event delivery spins it), which lands the wrap too early
    /// on a measurable fraction of launches. Anchor on the didFinishLaunching notification
    /// + one more tick instead — that runs strictly after the whole launch sequence,
    /// regardless of queue-drain timing. fork-check.sh verifies the static ordering.
    /// Hop to main for `SessionRegistry`/`NSApp` too; `ForkBootstrap.install` isn't
    /// `@MainActor`.
    func install() {
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in
            token.map(NotificationCenter.default.removeObserver)
            // One more tick: observer order within the posting (us vs. the app delegate's
            // own applicationDidFinishLaunching) is undefined, but a block enqueued *during*
            // the posting runs after every observer has returned.
            DispatchQueue.main.async { ForkNotify.shared.wrapUpstreamDelegate() }
        }
    }

    private func wrapUpstreamDelegate() {
        MainActor.assumeIsolated {
            let center = UNUserNotificationCenter.current()
            wrapped = center.delegate
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            // "Needs you" = finished-unread OR probe-blocked. Not `dot == .waiting`: `dot`
            // demotes `.waiting` to `.blocked` when the probe flags the pane, which would
            // drop it from a waiting-only count one probe-tick after it settled — badge
            // flashes then vanishes while the pane still needs input. Counting `blocked`
            // directly closes the inverse gap: the most urgent state (red rail) previously
            // never reached the badge at all. `!ccBusy` is the only `dot`-ism that belongs
            // here (a busy pane renders a working rail; badging "needs you" at the same
            // time would contradict it — and `ccBusy` also masks `blocked` in `dot`).
            let needsYou = { (p: [SessionRef: PaneMachine]) in
                p.values.lazy.filter { ($0.phase == .waiting || $0.blocked) && !$0.ccBusy }.count
            }
            // Upstream's `setDockBadge` (AppDelegate) is the second writer; it's `private`,
            // so on the 1→0 edge we re-derive its bell label locally instead of writing
            // nil and clobbering a pending bell. Match its gate (the user-disableable
            // `bell-features = attention`) and its 99+ cap so the fork can never show a
            // bell badge upstream itself wouldn't.
            let bellLabel = { () -> String? in
                guard ForkWindowController.instance?.ghostty.config.bellFeatures
                    .contains(.attention) ?? false else { return nil }
                let c = NSApp.windows
                    .compactMap { $0.windowController as? BaseTerminalController }
                    .reduce(0) { $0 + ($1.bell ? 1 : 0) }
                return c > 0 ? (c > 99 ? "99+" : "\(c)") : nil
            }
            badgeSub = SessionRegistry.shared.$panes
                .map(needsYou)
                .removeDuplicates()
                .sink { NSApp.dockTile.badgeLabel = $0 > 0 ? "\($0)" : bellLabel() }
            NotificationCenter.default.addObserver(
                forName: .terminalWindowBellDidChangeNotification,
                object: nil, queue: .main
            ) { _ in
                // Upstream's writer on this same notification defers behind a
                // getNotificationSettings async IPC + a main.async hop (syncDockBadge →
                // setDockBadge), so a re-assert at post time ALWAYS loses that race — the
                // badge would show the bell count (or nothing, on the bell-clear edge)
                // until the needs-you count next *changes value* (removeDuplicates gates
                // the Combine path). Re-assert after a beat that outlasts the IPC
                // roundtrip: upstream's value shows for under a second, then ours wins.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    MainActor.assumeIsolated {
                        let n = needsYou(SessionRegistry.shared.panes)
                        if n > 0 { NSApp.dockTile.badgeLabel = "\(n)" }
                    }
                }
            }
        }
    }

    @MainActor func post(tab: TabModel.ID, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["forkTab": tab.uuidString]
        content.threadIdentifier = "fork-\(tab.uuidString)"
        UNUserNotificationCenter.current().add(
            .init(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler done: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        guard let s = info["forkTab"] as? String, let id = UUID(uuidString: s) else {
            wrapped?.userNotificationCenter?(center, didReceive: response,
                                             withCompletionHandler: done) ?? done()
            return
        }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            ForkWindowController.instance?.window?.makeKeyAndOrderFront(nil)
            ForkWindowController.instance?.activate(tab: id)
        }
        done()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent n: UNNotification,
        withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        guard n.request.content.userInfo["forkTab"] == nil else { done([.banner, .sound]); return }
        wrapped?.userNotificationCenter?(center, willPresent: n,
                                         withCompletionHandler: done) ?? done([])
    }
}
#endif
