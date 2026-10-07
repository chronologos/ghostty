#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// Renders the fork's real views offscreen, over a seeded registry, to PNGs — the only way to
/// *look* at a visual change without quitting the running app (a second instance exits at
/// the fork.json guard). Asserts nothing about pixels; it exists to be read by eye.
///
///     TEST_RUNNER_FORK_SNAPSHOT_DIR=/tmp/shots xcodebuild test … \
///       -only-testing:GhosttyTests/ForkSnapshotTests
///
/// Skipped unless that variable is set. `TEST_RUNNER_FORK_SNAPSHOT_FONT=<family>` sets the face
/// (otherwise the system mono, as with no `window-title-font-family`). What it can't show:
/// anything that needs a live surface (`controller` is nil, so no OSC titles, no DETACHED cue
/// on rows, no pane actions in the palette), hover, focus rings, or motion.
@MainActor
struct ForkSnapshotTests {
    private static let dir = ProcessInfo.processInfo.environment["FORK_SNAPSHOT_DIR"]
    private static let font = ProcessInfo.processInfo.environment["FORK_SNAPSHOT_FONT"]

    private struct Scheme { let name: String, fg: UInt32, bg: UInt32 }
    private static let schemes = [
        Scheme(name: "green", fg: 0x00A645, bg: 0x000000),
        Scheme(name: "amber", fg: 0xFFBF00, bg: 0x000000),
        Scheme(name: "paper", fg: 0x000000, bg: 0xFFFFFF),
    ]

    private func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private func tokens(_ s: Scheme) -> ForkTokens {
        let bg = color(s.bg)
        return ForkTheme.resolve(fg: color(s.fg), bg: bg, appearanceIsDark: !bg.isLightColor,
                                 increaseContrast: false)!
    }

    /// `size` nil = whatever the view asks for (panels that size themselves).
    private func shoot(_ view: some View, _ s: Scheme, size: CGSize? = nil, as name: String) throws {
        let host = NSHostingView(rootView: view.environment(\.forkTokens, tokens(s))
            .environment(\.forkFontFamily, Self.font))
        host.appearance = NSAppearance(named: color(s.bg).isLightColor ? .aqua : .darkAqua)
        let size = size ?? host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        // Never ordered in: it only has to give the hosting view a window to lay out in.
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // `onAppear`, the scroll view's first layout and the rows' `TimelineView`s all land on
        // later turns of the run loop.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = URL(fileURLWithPath: Self.dir!).appendingPathComponent("\(name)-\(s.name).png")
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    // MARK: Sample fleet — made-up names, one of every state a cold row can show.

    private func tab(_ r: SessionRegistry, _ host: String, _ names: [String], title: String? = nil) -> TabModel.ID {
        let t = r.newTab(on: host, title: title ?? names[0])
        r.setPersistedTree(names.map { SessionRef(hostID: host, name: $0) }
            .reduce(.empty) { $0.appending(leaf: $1) }, for: t.id)
        return t.id
    }

    private func seed() -> SessionRegistry {
        let r = SessionRegistry.shared
        r.resetForTesting()
        // `.local` transport on every host: nothing here may reach a network even by accident.
        for id in ["atlas", "borei", "delta"] { r.addHost(ForkHost(id: id, label: id, transport: .local)) }

        let deputy = tab(r, "local", ["deputy", "deputy-wbd5"])
        let ledger = tab(r, "local", ["ledger", "ledger-djzu"])
        let ghostty = tab(r, "local", ["ghostty"])
        let azure = tab(r, "atlas", ["azure", "azure-ge1o"], title: "azure")
        r.renameTab(azure, to: "cloud")
        let foundry = tab(r, "borei", ["foundry"])
        _ = tab(r, "borei", ["pr-loop"])
        _ = tab(r, "borei", ["build-box"])
        _ = tab(r, "borei", ["adsum"])
        _ = tab(r, "delta", ["xtalk-setup", "scratch"])

        func ref(_ h: String, _ n: String) -> SessionRef { SessionRef(hostID: h, name: n) }
        func entry(_ n: String, _ cwd: String) -> ZmxAdapter.ListEntry {
            .init(name: n, clients: 1, created: Date(), external: false, cwd: cwd)
        }
        // Live surfaces on three of four hosts; `delta` shows the quiet frame.
        for (h, n) in [("local", "ghostty"), ("atlas", "azure"), ("borei", "foundry")] {
            r.bind(surface: UUID(), to: ref(h, n))
        }
        r.noteList(hostID: "local", list: .init(managed: [
            entry("deputy", "/Users/me/code/proxy-trial"), entry("deputy-wbd5", "/Users/me/code/proxy-trial"),
            entry("ledger", "/Users/me/Desktop"), entry("ledger-djzu", "/Users/me/Desktop"),
            entry("ghostty", "/Users/me/src/ghostty")]))
        r.noteList(hostID: "atlas", list: .init(managed: [
            entry("azure", "/root/src/app"), entry("azure-ge1o", "/root/src/app")]))
        r.noteList(hostID: "borei", list: .init(
            managed: [entry("foundry", "/root/src/app"), entry("pr-loop", "/root/src/app"),
                      entry("adsum", "/root/src/app")],
            unresponsive: [.init(name: "build-box", external: false, err: "Timeout")]))
        // Two misses = ended.
        for _ in 0..<2 {
            r.noteList(hostID: "delta", list: .init(managed: [entry("xtalk-setup", "/root/src/app")]))
        }

        // Read text first, swept; then the same slices again with something new on top.
        let seenLocal: [String: CCProbe.Info] = [
            "ledger": .init(name: "ledger-prime", detail: "Reconciled September; two rows still open"),
            "ghostty": .init(name: "ghostty-a3", detail: "PR68 rebased & tested"),
        ]
        r.applyProbeResult(hostID: "local", result: seenLocal)
        r.applyProbeResult(hostID: "borei", result: [
            "foundry": .init(detail: "Showing the new reply in the thread")])
        r.applyProbeResult(hostID: "delta", result: [
            "xtalk-setup": .init(detail: "harness up since 21:02Z; checking console bind")])
        r.markAllCCRead()
        r.applyProbeResult(hostID: "local", result: seenLocal.merging([
            "deputy": .init(tempo: "blocked", needs: "quit the trial app, then type `go`"),
        ]) { $1 })
        r.applyProbeResult(hostID: "atlas", result: [
            "azure": .init(detail: "az logins verified healthy; both tenants answer and the token cache is warm")])
        r.applyProbeResult(hostID: "borei", result: [
            "foundry": .init(detail: "Showing the new reply in the thread"),
            "pr-loop": .init(status: "busy", detail: "Re-seeding the deputy, local lanes only"),
        ])
        _ = r.apply(ref("atlas", "azure"), .progress)
        _ = r.apply(ref("atlas", "azure"), .settled(isActive: false))
        _ = r.apply(ref("borei", "adsum"), .watch(true))
        _ = r.apply(ref("borei", "pr-loop"), .watch(true))

        // One, two, three, four, and past the limit.
        let hues: [(String, Double)] = [("ops", 0), ("cloud", 0.08), ("wip", 0.5), ("env", 0.3), ("x", 0.75)]
        for (t, name, n) in [(deputy, "deputy", 1), (deputy, "deputy-wbd5", 2), (ledger, "ledger", 3),
                             (ledger, "ledger-djzu", 4), (azure, "azure", 5)] {
            for (text, hue) in hues.prefix(n) { r.addPaneTag(tab: t, name: name, PaneTag(text: text, hue: hue)) }
        }

        // Visits (they mark status text read); the last one is where "you" are.
        for (t, n) in [(foundry, "foundry"), (ledger, "ledger"), (azure, "azure"), (ghostty, "ghostty")] {
            r.setActive(tab: t)
            r.touchPane(tab: t, name: n)
        }
        r.setFocusedPane(index: 0)
        return r
    }

    private func withDefaults(_ values: [String: Any], _ body: () throws -> Void) rethrows {
        let d = UserDefaults.standard
        let old = values.keys.map { ($0, d.object(forKey: $0)) }
        for (k, v) in values { d.set(v, forKey: k) }
        defer { for (k, v) in old { d.set(v, forKey: k) } }
        try body()
    }

    @Test(.enabled(if: dir != nil))
    func sidebar() throws {
        let r = seed()
        defer { r.resetForTesting() }
        try FileManager.default.createDirectory(atPath: Self.dir!, withIntermediateDirectories: true)
        for s in Self.schemes {
            try withDefaults(["forkSidebarShowCC": true, SessionRegistry.kFocusMode: false,
                              SessionRegistry.kFilterTagged: false]) {
                try shoot(SidebarView(controller: nil, polls: false).environmentObject(r), s,
                          size: CGSize(width: 300, height: 792), as: "hosts")
            }
        }
        try withDefaults(["forkSidebarShowCC": true, SessionRegistry.kFocusMode: true,
                          SessionRegistry.kFilterTagged: false]) {
            try shoot(SidebarView(controller: nil, polls: false).environmentObject(r), Self.schemes[0],
                      size: CGSize(width: 300, height: 792), as: "focus")
        }
        // The floor the sidebar can be dragged to.
        try withDefaults(["forkSidebarShowCC": true, SessionRegistry.kFocusMode: false,
                          SessionRegistry.kFilterTagged: false]) {
            try shoot(SidebarView(controller: nil, polls: false).environmentObject(r), Self.schemes[0],
                      size: CGSize(width: 248, height: 792), as: "narrow")
        }
    }

    /// Every lamp, enlarged, including the ones a cold row can't reach.
    @Test(.enabled(if: dir != nil))
    func lamps() throws {
        let kinds: [(Lamp.Kind, String)] = [
            (.unlit, "unlit"), (.working, "working"), (.finished, "finished"),
            (.blocked, "blocked"), (.detached, "detached"), (.ended, "ended"),
            (.unresponsive, "unresponsive"), (.watching, "watching"),
        ]
        try FileManager.default.createDirectory(atPath: Self.dir!, withIntermediateDirectories: true)
        for s in Self.schemes {
            let t = tokens(s)
            try shoot(HStack(spacing: 14) {
                ForEach(kinds, id: \.1) { kind, name in
                    VStack(spacing: 6) {
                        Lamp(kind).scaleEffect(3).frame(width: 30, height: 30)
                        Text(name).font(.system(size: 8, design: .monospaced)).foregroundStyle(t.inactive)
                    }
                    .frame(width: 56)
                }
            }
            .padding(12).background(t.ground), s, size: CGSize(width: 660, height: 72), as: "lamps")
            try shoot(SidebarRevealKey {}.padding(8).background(t.ground), s, as: "reveal")
        }
    }

    // MARK: Panels

    private func ago(_ s: TimeInterval) -> Date { Date(timeIntervalSinceNow: -s) }

    /// One of every kind of row the session lists can show.
    private var cannedList: ZmxAdapter.ListResult {
        .init(
            managed: [
                .init(name: "deputy", clients: 1, created: ago(7200), external: false, cwd: "/Users/me/code/proxy-trial"),
                .init(name: "shell-k7w", clients: 0, created: ago(90_000), external: false,
                      alias: "release notes", cwd: "/Users/me/src/notes"),
                .init(name: "ghostty", clients: 2, created: ago(400), external: false, cwd: "/Users/me/src/ghostty"),
                .init(name: "nightly", clients: 0, created: ago(30_000), external: false, cwd: "/Users/me/src/app",
                      cmd: "zig build test", ended: ago(1200), exitCode: 1),
            ],
            external: [.init(name: "scratch", clients: 0, created: ago(600_000), external: true, cwd: "/tmp")],
            unresponsive: [.init(name: "build-box", external: false, err: "Timeout")])
    }

    /// A panel floats over the terminal, so shoot it over the ground with room for its corners.
    private func floating(_ v: some View, _ s: Scheme) -> some View { v.padding(16).background(tokens(s).ground) }

    @Test(.enabled(if: dir != nil))
    func panels() throws {
        let r = seed()
        defer { r.resetForTesting() }
        try FileManager.default.createDirectory(atPath: Self.dir!, withIntermediateDirectories: true)
        let canned = cannedList
        let lister: ZmxAdapter.Lister = { _ in .success(canned) }
        let local = try #require(r.host(id: "local"))
        let atlas = try #require(r.host(id: "atlas"))

        for s in Self.schemes {
            try shoot(floating(ForkPanePalette(controller: nil, onDone: {}).environmentObject(r)
                .frame(width: 620, height: 460), s), s, as: "palette")
            try shoot(floating(NewSessionView(host: local, placeholder: "shell-x3f", lister: lister,
                                              onSubmit: { _, _, _ in }, onCancel: {}).environmentObject(r), s),
                      s, as: "picker-host")
            try shoot(floating(NewSessionView(title: "Split on localhost", host: local, locked: true,
                                              placeholder: "shell-x3f", lister: lister,
                                              onSubmit: { _, _, _ in }, onCancel: {}).environmentObject(r), s),
                      s, as: "picker-session")
            try shoot(floating(HostsView(select: atlas.id, lister: lister, onRemove: { _ in }, onDone: {})
                .environmentObject(r), s), s, as: "hosts-detail")
            try shoot(floating(ConfirmView(
                title: "Close", chord: "⌘W", headline: "Close pane 'release notes'?",
                detail: "zmx session shell-k7w. Detach leaves the zmx session running. Reattach from ⌘T or the split picker.",
                choices: [
                    .init(label: "Detach", chord: "⏎", kind: .primary, keys: [.return]) {},
                    .init(label: "Kill Session", chord: "K · ⌘W", kind: .destructive, keys: []) {},
                    .init(label: "Cancel", chord: "esc", keys: [.escape]) {},
                ]), s), s, as: "confirm")
        }
        let s = Self.schemes[0]
        try shoot(floating(HostsView(lister: lister, onRemove: { _ in }, onDone: {}).environmentObject(r), s),
                  s, as: "hosts-add")
        try shoot(floating(ScrollbackSearchView(controller: nil, onDone: {}).environmentObject(r), s),
                  s, as: "search")
        try shoot(floating(CheatsheetView(hoverCommands: ["g": .init(cmd: ["lazygit", "-p", "{cwd}"], mode: .pane)]), s),
                  s, as: "cheatsheet")
        try shoot(TagEditView(seed: PaneTag(text: "ops", hue: 0.08)) { _ in }, s, as: "tag")
        // The tag mark, enlarged: 1…5 tags.
        try shoot(HStack(spacing: 16) {
            ForEach(1...5, id: \.self) { n in
                TagMark(tags: [0, 0.08, 0.5, 0.3, 0.75].prefix(n).map { PaneTag(text: "t", hue: $0) })
                    .frame(width: 9, height: 9).scaleEffect(4).frame(width: 36, height: 36)
            }
        }.padding(12).background(tokens(s).ground), s, as: "tagmarks")
    }
}
#endif
