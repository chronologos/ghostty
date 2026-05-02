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

    /// Seam #1 fires at AppDelegate.swift:215 but upstream sets `center.delegate = self`
    /// at :289 — defer one tick so we wrap (not get overwritten by) it. Hop to main for
    /// `SessionRegistry`/`NSApp` too; `ForkBootstrap.install` isn't `@MainActor`.
    func install() {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                let center = UNUserNotificationCenter.current()
                wrapped = center.delegate
                center.delegate = self
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
                let waiting = { SessionRegistry.shared.paneState.values.lazy
                                  .filter { $0 == .waiting }.count }
                badgeSub = SessionRegistry.shared.$paneState
                    .map { _ in waiting() }
                    .removeDuplicates()
                    .sink { NSApp.dockTile.badgeLabel = $0 > 0 ? "\($0)" : nil }
                // Upstream's `setDockBadge` (AppDelegate.swift:745) writes the same label on
                // bell-change. We're registered later (post-seam-#1-tick), so re-asserting here
                // wins; when waiting==0 we leave upstream's bell label alone.
                NotificationCenter.default.addObserver(
                    forName: .init("com.mitchellh.ghostty.terminalWindowBellDidChange"),
                    object: nil, queue: .main
                ) { _ in
                    MainActor.assumeIsolated {
                        let n = waiting()
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
