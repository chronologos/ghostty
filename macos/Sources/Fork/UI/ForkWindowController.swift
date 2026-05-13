#if os(macOS)
import AppKit
import SwiftUI
import Combine
import GhosttyKit
import UserNotifications

/// The fork's single window. Subclasses `TerminalController` so the inherited `surfaceTree`,
/// `TerminalSplitTreeView`, split IBActions and focus nav work unchanged (SPEC §2.1).
/// Tab switching = swapping which tree is assigned to `surfaceTree`.
final class ForkWindowController: TerminalController {
    private let registry = SessionRegistry.shared
    private var liveTabs: [TabModel.ID: SplitTree<Ghostty.SurfaceView>] = [:]
    private var cancellables: Set<AnyCancellable> = []

    /// Singleton: the fork is single-window in v1.
    private(set) static weak var instance: ForkWindowController?

    // MARK: Factory (called from seam #2 via ForkBootstrap.intercept)
    //
    // Registry seeding lives here, not in windowDidLoad, because windowDidLoad fires
    // *inside* super.init (BaseTerminalController.init:142 assigns surfaceTree → didSet
    // → TerminalController.surfaceTreeDidChange reads self.window → nib loads).

    static func newWindow(_ ghostty: Ghostty.App, intent: NewSessionIntent? = nil) -> ForkWindowController {
        if let existing = instance, existing.window != nil {
            existing.window?.makeKeyAndOrderFront(nil)
            // Scripting paths (Shortcuts/AppleScript/Finder open) carry a payload — open
            // it as a fresh tab instead of just raising the window.
            if let intent { existing.newForkTab(intent: intent) }
            return existing
        }
        let registry = SessionRegistry.shared
        let c: ForkWindowController
        if registry.tabs.isEmpty {
            let host: ForkHost = intent.flatMap { registry.host(id: $0.hostID) } ?? .local
            let ref = SessionRef(hostID: host.id, name: intent?.name ?? registry.uniqueAutoName())
            let cfg = ZmxAdapter.surfaceConfig(host: host, ref: ref,
                                               initialCmd: intent?.cmd, cwd: intent?.cwd)
            c = ForkWindowController(ghostty, withBaseConfig: cfg)
            if case let .leaf(view) = c.surfaceTree.root {
                registry.bind(surface: view.id, to: ref)
                c.observeProgress(view)
                let tab = registry.newTab(on: host.id, title: ref.name)
                c.liveTabs[tab.id] = c.surfaceTree
                c.activate(tab: tab.id)
            }
        } else {
            c = ForkWindowController(ghostty, withSurfaceTree: .init())
            if let intent {
                c.newForkTab(intent: intent)
            } else if let active = registry.activeTabID ?? registry.tabs.first?.id {
                c.activate(tab: active)
            }
        }
        instance = c
        c.showWindow(nil)
        return c
    }

    /// Fork keeps the window open with an empty tree (= "no tabs"); upstream would `.close()` it.
    override func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        guard !to.isEmpty else { focusedSurface = nil; return }
        super.surfaceTreeDidChange(from: from, to: to)
    }

    /// ⌘W on the last pane → `removeSurfaceNode` → `replaceSurfaceTree(empty)` (`:197`) →
    /// `closeTabImmediately()` (`:672`) → `closeWindowImmediately()` since the fork is single-
    /// window. Intercept at the choke point and route to sidebar tab close instead.
    override func closeTabImmediately(registerRedo: Bool = true) {
        guard let active = registry.activeTabID else { return }
        closeForkTab(active)
    }

    // MARK: Detached panes — when a bound surface's child exits, swap in a placeholder
    // that prints "press ⏎ to reattach" and execs `zmx attach` on ⏎ (SPEC §5).

    private var detachedPlaceholders: Set<UUID> = []

    private func makeDetachedPlaceholder(for dead: Ghostty.SurfaceView) -> Ghostty.SurfaceView? {
        guard dead.processExited,
              !detachedPlaceholders.contains(dead.id),
              let ref = registry.refs[dead.id],
              let host = registry.host(id: ref.hostID),
              let app = ghostty.app else { return nil }
        let ccName = registry.tabs.lazy
            .first { $0.tree.leafRefs.contains(ref) }?.ccNames[ref.key]
        var cfg = Ghostty.SurfaceConfiguration()
        cfg.command = ZmxAdapter.detachedScript(host: host, ref: ref, ccName: ccName)
        let placeholder = Ghostty.SurfaceView(app, baseConfig: cfg)
        detachedPlaceholders.insert(placeholder.id)
        registry.bind(surface: placeholder.id, to: ref)
        observeProgress(placeholder)
        registry.unbind(surface: dead.id)
        stopObservingProgress(dead.id)
        return placeholder
    }

    /// `BaseTerminalController.ghosttyDidCloseSurface` (`:585`) is `@objc private` and
    /// guards on `surfaceTree`, so a parked tab's pty-exit is dropped before our
    /// `closeSurface` override sees it. This second observer covers that case.
    @objc private func parkedSurfaceDidExit(_ note: Notification) {
        guard let dead = note.object as? Ghostty.SurfaceView,
              surfaceTree.root?.node(view: dead) == nil,
              let (tabID, tree) = liveTabs.first(where: {
                  $0.key != registry.activeTabID && $0.value.contains { $0.id == dead.id }
              }),
              let placeholder = makeDetachedPlaceholder(for: dead),
              let deadNode = tree.root?.node(view: dead),
              let newTree = try? tree.replacing(node: deadNode, with: .leaf(view: placeholder))
        else { return }
        liveTabs[tabID] = newTree
        registry.setPersistedTree(project(newTree.root), for: tabID)
    }

    override func closeSurface(_ node: SplitTree<Ghostty.SurfaceView>.Node, withConfirmation: Bool = true) {
        // `withConfirmation` is libghostty's `needsConfirmQuit()`, which is false for both
        // process-death AND user ⌘W on an idle shell. `processExited` is the discriminator.
        if !withConfirmation,
           case let .leaf(dead) = node,
           let placeholder = makeDetachedPlaceholder(for: dead) {
            do {
                surfaceTree = try surfaceTree.replacing(node: node, with: .leaf(view: placeholder))
                focusedSurface = placeholder
                return
            } catch {}
        }

        // A re-reattached placeholder dying (`detachedPlaceholders.contains` blocks the
        // swap above), or any unbound dead leaf — close silently. PR23 dropped the
        // `withConfirmation` gate on the branches below, so without this a background
        // pty death would pop the Detach/Kill sheet for an already-exited process.
        // Root case must route to `closeForkTab` — `super` on root → `closeWindow(nil)`.
        if case let .leaf(dead) = node, dead.processExited {
            if surfaceTree.root == node, let tab = registry.activeTab {
                closeForkTab(tab.id)
            } else {
                super.closeSurface(node, withConfirmation: false)
            }
            return
        }

        // ⌘W on the last pane → tab-level Detach/Kill. `TerminalController.closeSurface`
        // (`:656-669`) would route this to `closeWindow(nil)`; we route to the sidebar tab.
        if surfaceTree.root == node, let tab = registry.activeTab,
           let host = registry.host(id: tab.hostID) {
            let live = liveTabs[tab.id]?.compactMap { registry.refs[$0.id] } ?? []
            let refs = Array(Set(live.isEmpty ? tab.tree.leafRefs : live))
            confirmDetachOrKill(
                messageText: "Close tab '\(tab.title)'?",
                informativeText: refs.isEmpty
                    ? "No zmx sessions are bound to this tab."
                    : "Detach leaves \(refs.count) zmx session\(refs.count == 1 ? "" : "s") running. Reattach from ⌘T or the split picker.",
                killTitle: refs.count > 1 ? "Kill \(refs.count) Sessions" : "Kill Session",
                killEnabled: !refs.isEmpty,
                onDetach: { [weak self] in self?.closeForkTab(tab.id) },
                onKill: { [weak self] in
                    for ref in refs { Task { try? await ZmxAdapter.kill(host: host, ref: ref) } }
                    self?.closeForkTab(tab.id)
                }
            )
            return
        }

        // ⌘W on one pane of several → per-pane Detach/Kill.
        if case let .leaf(surface) = node, let ref = registry.refs[surface.id],
           let host = registry.host(id: ref.hostID), let tab = registry.activeTab {
            confirmDetachOrKill(
                messageText: "Close pane '\(ref.name)'?",
                informativeText: "Detach leaves the zmx session running. Reattach from ⌘T or the split picker.",
                onDetach: { [weak self] in self?.dropPane(tab: tab, ref: ref, surface: surface) },
                onKill: { [weak self] in
                    guard let self else { return }
                    // Unbind first so the pty-death → placeholder path short-circuits.
                    self.registry.unbind(surface: surface.id)
                    self.stopObservingProgress(surface.id)
                    Task { try? await ZmxAdapter.kill(host: host, ref: ref) }
                    self.dropPane(tab: tab, ref: ref, surface: surface)
                }
            )
            return
        }

        super.closeSurface(node, withConfirmation: false)
    }

    /// ⌘W sheet: Detach (⏎, default) / Kill (K, destructive) / Cancel (Esc).
    private func confirmDetachOrKill(
        messageText: String,
        informativeText: String,
        killTitle: String = "Kill Session",
        killEnabled: Bool = true,
        onDetach: @escaping () -> Void,
        onKill: @escaping () -> Void
    ) {
        guard let window else { onDetach(); return }
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText + "\n\n⏎ Detach · K Kill · Esc Cancel"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Detach")
        let kill = alert.addButton(withTitle: killTitle)
        kill.keyEquivalent = "k"
        kill.hasDestructiveAction = true
        kill.isEnabled = killEnabled
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { resp in
            alert.window.orderOut(nil)
            switch resp {
            case .alertFirstButtonReturn: onDetach()
            case .alertSecondButtonReturn: onKill()
            default: break
            }
        }
    }

    // MARK: ⌘[/⌘]/⌘1-9/⌘⌥1-9 — sidebar-tab navigation (SPEC §10).

    private var navMonitor: Any?
    private var cheatMonitor: Any?
    private weak var cheatsheetHost: NSView?
    private var cheatsheetCenterX: NSLayoutConstraint?
    private var cheatsheetTimer: Timer?
    private func setCheatsheet(_ on: Bool) {
        cheatsheetTimer?.invalidate(); cheatsheetTimer = nil
        cheatsheetHost?.isHidden = !on
    }

    /// Set by SidebarView's per-row `.onHover`; read only by the navMonitor's bare-key
    /// branch below. `sid` resolves the surface in `handleHoverKey` — `index` drifts when
    /// a lower-index sibling is removed, and `ref` is ambiguous when split-picker attached
    /// the same session twice (PR26). `index` is kept for the row's `.onHover`/`.onDisappear`
    /// identity guards only. `sid` is nil for cold-restored rows; surface-dependent actions
    /// no-op there until the user re-hovers post-activate. Not @Published.
    var hoveredPane: (tab: TabModel.ID, index: Int, ref: SessionRef, sid: UUID?)?

    /// Fork-owned panel for `.overlay` hover-commands. Lazy so a user with no overlay
    /// bindings never instantiates it.
    private lazy var overlayController = ForkOverlayController(ghostty)

    /// `charactersIgnoringModifiers` does not strip Option (it's a character-producing
    /// modifier), so ⌥-digit must be matched by physical keyCode.
    private static let digitKeyCodes: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]

    private func installNavMonitor() {
        navMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, ev.window === self.window, self.sheetPanel == nil else { return ev }
            // Any keystroke = chord completed (or non-⌘ typing) → hide/cancel cheatsheet.
            self.setCheatsheet(false)
            let mods = ev.modifierFlags.intersection([.command, .shift, .option, .control])
            // Bare-key hover shortcuts (k/r/c/t/p). Only when the mouse is on a sidebar row
            // and a rename field isn't focused — `firstResponder is NSTextView` covers that.
            // Hazard: terminal is usually firstResponder, so a stray letter while the mouse
            // rests on a row will intercept; the actions are confirm-gated or trivially
            // reversible.
            if mods.isEmpty, let h = self.hoveredPane,
               !(self.window?.firstResponder is NSTextView),
               self.handleHoverKey(ev.charactersIgnoringModifiers?.lowercased(), on: h) {
                return nil
            }
            if let n = Self.digitKeyCodes[ev.keyCode] {
                switch mods {
                case [.command, .option]: self.gotoHost(index: n); return nil
                case .command: self.gotoTab(index: n); return nil
                default: return ev
                }
            }
            // ⌘I (`prompt_surface_title`) dispatches straight to `SurfaceView.promptTitle()`
            // (Ghostty.App.swift:1669) which doesn't persist; intercept to drive the
            // sidebar's per-pane label instead. ⌘⇧I goes via `promptTabTitle()`.
            if mods == .command, ev.charactersIgnoringModifiers == "i" {
                self.promptPaneTitle(); return nil
            }
            // ⌘⌥A — one-shot watch on focused pane. keyCode 0 = kVK_ANSI_A;
            // `charactersIgnoringModifiers` doesn't strip Option (see digit comment above).
            if mods == [.command, .option], ev.keyCode == 0 {
                self.toggleWatch(); return nil
            }
            // ⌘K / ⌘⇧K — pane palette / scrollback search. keyCode 40 = kVK_ANSI_K.
            // Shadows upstream's `clear_screen` (Config.zig:6927).
            if ev.keyCode == 40 {
                if mods == .command { self.showPanePalette(); return nil }
                if mods == [.command, .shift] { self.showScrollbackSearch(); return nil }
            }
            // ⌘[/⌘] are upstream's `goto_split:previous/next` (Config.zig:7016).
            // Sidebar tab nav uses ⌘⇧[/⌘⇧] (upstream's `previous_tab`/`next_tab`).
            guard mods == [.command, .shift] else { return ev }
            switch ev.charactersIgnoringModifiers {
            case "{", "[": self.stepTab(-1); return nil
            case "}", "]": self.stepTab(1); return nil
            case "b", "B": self.toggleSidebar(); return nil
            default: return ev
            }
        }
        // ⌘-hold cheatsheet: arm 600ms after ⌘-down (so quick chords don't flash it),
        // hide on ⌘-up. Stuck-state guards: the keyDown
        // monitor above hides on any chord-completion via `setCheatsheet(false)` calls
        // baked into the goto/step/toggle handlers, and `windowDidResignKey` covers
        // app-switch swallowing the flagsChanged release.
        cheatMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] ev in
            guard let self, ev.window === self.window else { return ev }
            let cmd = ev.modifierFlags.contains(.command)
            cheatsheetTimer?.invalidate(); cheatsheetTimer = nil
            if cmd, ev.modifierFlags.intersection([.shift, .option, .control]).isEmpty {
                cheatsheetTimer = .scheduledTimer(withTimeInterval: 0.6, repeats: false) {
                    [weak self] _ in MainActor.assumeIsolated { self?.setCheatsheet(true) }
                }
            } else {
                setCheatsheet(false)
            }
            return ev
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(parkedSurfaceDidExit(_:)),
            name: Ghostty.Notification.ghosttyCloseSurface, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(bellDidRing(_:)),
            name: .ghosttyBellDidRing, object: nil)
    }

    private func handleHoverKey(_ key: String?,
                                on h: (tab: TabModel.ID, index: Int, ref: SessionRef, sid: UUID?)) -> Bool {
        guard let key, let tab = registry.tabs.first(where: { $0.id == h.tab }),
              tab.tree.leafRefs.contains(where: { $0.key == h.ref.key }) else { return false }
        let surface = liveTabs[h.tab].flatMap { Array($0).first { $0.id == h.sid } }
        // User config first → can shadow built-ins (rebind `k` away from kill, etc.).
        if let cmd = registry.hoverCommands[key] {
            runHoverCommand(cmd, on: h, surface: surface)
            return true
        }
        switch key {
        case "k": confirmKillPane(tab: tab, ref: h.ref, surface: surface)
        case "r": surface.map(forkWigglePane)
        case "c": registry.setPaneTag(tab: h.tab, name: h.ref.key, to: nil)
        case "t": registry.taggingPane = (h.tab, h.ref.key)
        case "p": registry.setPinned(h.tab, !tab.pinned)
        case "n" where registry.ccLive[h.ref.hostID]?[h.ref.key]?.sock != nil:
            syncCCName(tab: tab, ref: h.ref)
        case "h" where UserDefaults.standard.bool(forKey: SessionRegistry.kFocusMode):
            registry.dismissFromFocus(h.tab)
            // Row diffs out unless it's the active tab (which `focusTabs` always keeps).
            if h.tab != registry.activeTabID { hoveredPane = nil }
        default: return false
        }
        return true
    }

    /// Set the CC session name to the pane's display title (`paneLabel ?? ref.name`, same
    /// chain the sidebar shows) via its control UDS. No-op when CCProbe has no live `sock`
    /// for this pane (probe toggle off, no CC running, or remote registry didn't write
    /// `messagingSocketPath`).
    func syncCCName(tab: TabModel, ref: SessionRef) {
        guard let host = registry.host(id: ref.hostID),
              let sock = registry.ccLive[ref.hostID]?[ref.key]?.sock else { return }
        let name = tab.paneLabels[ref.key] ?? ref.name
        Task { await CCProbe.rename(host: host, sock: sock, to: name) }
    }

    private func runHoverCommand(_ cmd: HoverCommand,
                                 on h: (tab: TabModel.ID, index: Int, ref: SessionRef, sid: UUID?),
                                 surface: Ghostty.SurfaceView?) {
        guard let host = registry.host(id: h.ref.hostID) else { return }
        // OSC 7 (real-time, needs shell integration) › CCProbe poll (3s lag, no integration needed).
        let cwd = surface?.pwd ?? registry.ccLive[h.ref.hostID]?[h.ref.key]?.cwd
        let argv = ZmxAdapter.expand(cmd.cmd, host: host, ref: h.ref, cwd: cwd)
        switch cmd.mode {
        case .local:
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = argv
            try? p.run()
        case .overlay:
            // Ephemeral — run argv directly (no zmx) in a fork-owned quick-terminal panel.
            // We do NOT touch `AppDelegate.quickController`: its lazy getter's
            // `windowDidLoad`→`animateIn` creates a throwaway default-shell surface that we'd
            // immediately swap out, and dealloc'ing that mid-spawn `_exit(1)`s the process in
            // ReleaseLocal (termio fork race; see PR31 commit msg). `ForkOverlayController`
            // gates `animateIn` until we've set the tree, so no default surface is ever created.
            guard let app = ghostty.app else { return }
            let cfg = ZmxAdapter.ephemeralConfig(host: host, argv: argv, cwd: cwd)
            DispatchQueue.main.async { [weak self] in
                self?.overlayController.present(Ghostty.SurfaceView(app, baseConfig: cfg))
            }
        case .pane:
            // `super.newSplit` operates on `surfaceTree` (the active tab's tree), so the
            // hovered tab must be active and its surface live. Cold-restored never-activated
            // tabs have no `liveTabs` entry → no-op rather than spawning unbound.
            guard let surface else { return }
            if registry.activeTabID != h.tab { activate(tab: h.tab) }
            // External `ref.name` may carry chars outside the validated set; only seed the
            // derived name from validated refs so the new (non-external) ref stays `isValid`.
            let seed = h.ref.isValid ? h.ref.name : nil
            let ref = SessionRef(hostID: host.id, name: registry.uniqueAutoName(derivedFrom: seed))
            _ = completeSplit(at: surface, direction: .right, host: host, ref: ref,
                              initialCmd: argv)
        }
    }

    // MARK: Watch (⌘⌥A) — one-shot alert on completion (PR24).
    //
    // ⌘⌥A one-shot watch: now only `registry.watchedSurfaces` membership. The OSC 9;4
    // edge is handled by the always-on `paneDidSettle` (which checks the set and posts
    // even for the active tab when watched, then clears it). The watch keeps its own
    // BEL trigger for the non-OSC path (`.ghosttyBellDidRing` — also posted by
    // upstream's OSC 133;D handler when `notify-on-command-finish-action` includes
    // `bell`, and by any raw `\a`). The old undebounced `$progressReport` sub here
    // pre-dated `observeProgress`'s 250ms debounce and would mis-fire on CC's
    // per-tool-call state:0 flicker.

    func toggleWatch(on target: Ghostty.SurfaceView? = nil) {
        guard let surface = target ?? focusedSurface else { return }
        registry.setWatching(surface.id, !registry.watchedSurfaces.contains(surface.id))
    }

    @objc private func bellDidRing(_ n: Notification) {
        guard let surface = n.object as? Ghostty.SurfaceView,
              registry.watchedSurfaces.contains(surface.id),
              let tab = owningTab(of: surface) else { return }
        registry.setWatching(surface.id, false)
        ForkNotify.shared.post(tab: tab.id,
                               title: "\(paneDisplayLabel(tab: tab, surface: surface)) finished",
                               body: "Tab '\(tab.title)'")
    }

    // MARK: Pane state (OSC 9;4) — always-on; ⌘⌥A watch piggybacks via `watchedSurfaces`.
    //
    // Upstream's `progressReport` didSet (SurfaceView_AppKit.swift:31) auto-nils after
    // 15s of no fresh OSC 9;4 — that's the stuck-spinner heartbeat. The 250ms debounce
    // on the nil edge here absorbs CC's per-tool-call clear/set flicker (state:0 fires
    // between tool calls mid-turn).

    private var progressSubs: [UUID: AnyCancellable] = [:]
    private var settleTimers: [UUID: Timer] = [:]

    private func observeProgress(_ surface: Ghostty.SurfaceView) {
        progressSubs[surface.id] = surface.$progressReport
            .dropFirst()
            .sink { [weak self, weak surface] report in
                guard let self, let surface else { return }
                settleTimers.removeValue(forKey: surface.id)?.invalidate()
                guard report == nil else { registry.setPaneState(surface.id, .working); return }
                guard registry.paneState[surface.id] == .working else { return }
                settleTimers[surface.id] = .scheduledTimer(withTimeInterval: 0.25, repeats: false) {
                    [weak self, weak surface] _ in
                    MainActor.assumeIsolated {
                        guard let self, let surface else { return }
                        self.settleTimers[surface.id] = nil
                        self.paneDidSettle(surface)
                    }
                }
            }
    }

    /// Surfaces that have already posted their settle banner and not yet been viewed.
    /// `paneState` itself can't gate this — a chatty watcher (cargo watch, npm dev, multi-
    /// turn CC with >250ms gaps) cycles `.working`↔`.waiting`, and the dot/badge SHOULD
    /// reflect that, but the banner shouldn't re-fire until the user actually views the tab.
    private var notifiedSurfaces: Set<UUID> = []

    private func paneDidSettle(_ surface: Ghostty.SurfaceView) {
        // Orphan check first: a Detach-ed surface (retained by upstream's undo stack) can
        // still get its 15s `progressReport` auto-nil → settle, but `owningTab` is nil.
        // Writing `.waiting` before this guard would stick the dock badge +1 forever.
        guard let tab = owningTab(of: surface) else {
            registry.setPaneState(surface.id, nil); return
        }
        let watched = registry.watchedSurfaces.contains(surface.id)
        if watched { registry.setWatching(surface.id, false) }
        guard watched || tab.id != registry.activeTabID else {
            registry.setPaneState(surface.id, nil); return
        }
        let active = tab.id == registry.activeTabID
        registry.setPaneState(surface.id, active ? nil : .waiting)
        // Watched-on-active: post but don't arm the one-per-view gate — there's no
        // future `activate(tab:)` of this tab to clear it (user is already here).
        guard active || notifiedSurfaces.insert(surface.id).inserted else { return }
        ForkNotify.shared.post(tab: tab.id,
                               title: "\(paneDisplayLabel(tab: tab, surface: surface)) — done",
                               body: "Tab '\(tab.title)'")
    }

    private func stopObservingProgress(_ id: UUID) {
        progressSubs.removeValue(forKey: id)
        settleTimers.removeValue(forKey: id)?.invalidate()
        notifiedSurfaces.remove(id)
        registry.dropPaneState(id)
        registry.setWatching(id, false)
    }

    private func owningTab(of surface: Ghostty.SurfaceView) -> TabModel? {
        registry.tabs.first { surfaces(for: $0.id).contains { $0 === surface } }
    }

    private func paneDisplayLabel(tab: TabModel?, surface: Ghostty.SurfaceView) -> String {
        let ref = registry.refs[surface.id]
        let osc = (surface.title.isEmpty || surface.title == "👻") ? nil : surface.title
        return ref.flatMap { tab?.paneLabels[$0.key] } ?? osc ?? ref?.name ?? "Pane"
    }

    // MARK: Sidebar visibility

    private static let sidebarWidth: CGFloat = 248
    private weak var sidebarHost: NSView?
    private weak var sidebarReveal: NSButton?
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var terminalLeadingConstraint: NSLayoutConstraint?

    func toggleSidebar() {
        guard let sidebarHost, let sidebarWidthConstraint, let terminalLeadingConstraint else { return }
        // Row removal via subtree-swap or width→0 doesn't reliably fire `.onHover(false)`;
        // a stale `hoveredPane` would keep bare k/r/c/t/p armed while typing in the pty.
        hoveredPane = nil
        let hide = sidebarWidthConstraint.constant > 0
        let w: CGFloat = hide ? 0 : Self.sidebarWidth
        if !hide { sidebarHost.isHidden = false }
        sidebarReveal?.isHidden = !hide
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            sidebarWidthConstraint.animator().constant = w
            terminalLeadingConstraint.animator().constant = w
            cheatsheetCenterX?.animator().constant = w / 2
            sidebarHost.superview?.layoutSubtreeIfNeeded()
        } completionHandler: {
            sidebarHost.isHidden = sidebarWidthConstraint.constant == 0
        }
    }

    @objc private func revealSidebar(_ sender: Any?) { toggleSidebar() }

    private func stepTab(_ delta: Int) {
        guard let active = registry.activeTab else { return }
        let siblings = registry.tabs(on: active.hostID)
        guard let i = siblings.firstIndex(where: { $0.id == active.id }) else { return }
        let n = siblings.count
        activate(tab: siblings[((i + delta) % n + n) % n].id)
    }

    /// ⌘N indexes whatever the sidebar is currently rendering: per-host order in normal
    /// mode, the cross-host pinned-then-MRU list in focus mode. The two @AppStorage keys
    /// live in `SidebarView`; reading UserDefaults directly avoids threading view state
    /// back through the controller for a one-shot key handler.
    func gotoTab(index n: Int) {
        let d = UserDefaults.standard
        let tagged = d.bool(forKey: SessionRegistry.kFilterTagged)
        let tabs: [TabModel]
        if d.bool(forKey: SessionRegistry.kFocusMode) {
            tabs = registry.focusTabs(taggedOnly: tagged)
        } else {
            let host = registry.activeHost?.id ?? ForkHost.local.id
            let all = registry.tabs(on: host)
            tabs = tagged ? all.filter(\.hasTag) : all
        }
        guard tabs.indices.contains(n - 1) else { return }
        activate(tab: tabs[n - 1].id)
    }

    private func moveActiveTab(by amount: Int) {
        guard amount != 0, let active = registry.activeTab else { return }
        let siblings = registry.tabs(on: active.hostID)
        guard let i = siblings.firstIndex(where: { $0.id == active.id }) else { return }
        let j = max(0, min(siblings.count - 1, i + amount))
        guard j != i else { return }
        registry.moveTab(active.id, before: siblings[j].id)
    }

    /// Intercept palette tab actions — `Ghostty.App.gotoTab/moveTab` guard on
    /// `tabGroup.windows.count > 1`, which is never true with `tabbingMode = .disallowed`.
    override func performAction(_ action: String, on surfaceView: Ghostty.SurfaceView) {
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "previous_tab": stepTab(-1)
        case "next_tab": stepTab(1)
        case "last_tab":
            let host = registry.activeHost?.id ?? ForkHost.local.id
            if let last = registry.tabs(on: host).last { activate(tab: last.id) }
        case "goto_tab":
            if parts.count == 2, let n = Int(parts[1]) { gotoTab(index: n) }
        case "move_tab":
            if parts.count == 2, let d = Int(parts[1]) { moveActiveTab(by: d) }
        case "prompt_surface_title": promptPaneTitle()
        case "prompt_tab_title": promptTabTitle()
        default:
            super.performAction(action, on: surfaceView)
        }
    }

    /// ⌘⇧I and View → Change Tab Title both land here. Upstream pops an NSAlert that
    /// writes `titleOverride` (which we already drive from `syncWindowTitle()`); redirect
    /// to the sidebar's heading inline field instead.
    override func promptTabTitle() {
        guard !ForkBootstrap.noSidebar, let tab = registry.activeTab else {
            return super.promptTabTitle()
        }
        revealRow(on: tab.hostID)
        registry.setRenaming(.tab(tab.id))
    }

    /// ⌘I — sidebar's persisted per-pane label for the focused pane. Upstream's
    /// `SurfaceView.promptTitle()` writes `surface.title`, which is per-instance and lost
    /// on restart; `paneLabels` (keyed by `ref.key`) survives via fork.json.
    func promptPaneTitle() {
        guard !ForkBootstrap.noSidebar, let tab = registry.activeTab else { return }
        // `tab.tree` lags `surfaceTree` by ≤80ms (debounced persistActive); `focusedPaneIndex`
        // is from the live tree, so a fresh split would index past the stale `leafRefs`.
        let refs = Array(surfaceTree).compactMap { registry.refs[$0.id] }
        let i = registry.focusedPaneIndex ?? 0
        guard i < refs.count else { return }
        revealRow(on: tab.hostID)
        registry.setRenaming(.pane(tab.id, name: refs[i].key))
    }

    private func revealRow(on hostID: ForkHost.ID) {
        if sidebarWidthConstraint?.constant == 0 { toggleSidebar() }
        registry.setExpanded(hostID, true)
    }

    @IBAction override func changeTabTitle(_ sender: Any) { promptTabTitle() }

    /// Live surfaces for a tab in depth-first-leaf order (matches `PersistedTree.leafRefs`).
    /// Empty for tabs never activated this session — those rebuild lazily on first `activate()`.
    func surfaces(for tabID: TabModel.ID) -> [Ghostty.SurfaceView] {
        Array(tabID == registry.activeTabID ? surfaceTree : (liveTabs[tabID] ?? .init()))
    }

    /// Worst-child state for a collapsed header, via `registry.paneStatus` per live pane so
    /// a pane that's actively working masks a stale probe `.blocked` (see `paneStatus`).
    /// Cold tabs have no live surfaces — fall back to the ref-keyed `.blocked` check so they
    /// still show red; `.working`/`.waiting` are surface-keyed and don't exist pre-attach.
    func rollup(tab: TabModel) -> PaneState? {
        let live = surfaces(for: tab.id)
        guard !live.isEmpty else { return registry.tabBlocked(tab) ? .blocked : nil }
        return live.lazy.compactMap { s -> PaneState? in
            guard let ref = self.registry.refs[s.id] else { return self.registry.paneState[s.id] }
            return self.registry.paneStatus(ref: ref, surfaceID: s.id)
        }.max()
    }

    func rollup(hostID: ForkHost.ID) -> PaneState? {
        registry.tabs(on: hostID).lazy.compactMap { self.rollup(tab: $0) }.max()
    }

    func gotoHost(index n: Int) {
        guard registry.hosts.indices.contains(n - 1) else { return }
        let host = registry.hosts[n - 1]
        registry.setExpanded(host.id, true)
        if let first = registry.tabs(on: host.id).first {
            activate(tab: first.id)
        }
    }

    func removeHost(_ id: ForkHost.ID) {
        // dropLiveTab (not closeForkTab) — closeForkTab's positional-neighbour pick
        // would `activate` a dormant same-host sibling mid-loop and spawn its ssh/zmx
        // sessions for one frame each, on the host we're tearing down.
        for tab in registry.tabs(on: id) { dropLiveTab(tab.id) }
        registry.removeHost(id)
        guard registry.activeTabID == nil else { return }
        if let next = registry.tabs.first?.id {
            activate(tab: next)
        } else {
            surfaceTree = .init()
        }
    }

    func confirmKillPane(tab: TabModel, ref: SessionRef, surface: Ghostty.SurfaceView?) {
        guard let window, let host = registry.host(id: tab.hostID) else { return }
        let alert = NSAlert()
        alert.messageText = "Kill zmx session '\(ref.name)'?"
        let n = tab.id == registry.activeTabID ? Array(surfaceTree).count : tab.tree.paneCount
        alert.informativeText = n > 1
            ? "Other panes in '\(tab.title)' stay attached."
            : "This is the only pane; the tab will close."
        alert.addButton(withTitle: "Kill")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let self else { return }
            // Unbind first so the pty-death → placeholder path short-circuits.
            if let surface { registry.unbind(surface: surface.id); stopObservingProgress(surface.id) }
            Task { try? await ZmxAdapter.kill(host: host, ref: ref) }
            dropPane(tab: tab, ref: ref, surface: surface)
        }
    }

    private func dropPane(tab: TabModel, ref: SessionRef, surface: Ghostty.SurfaceView?) {
        // Live count for the active tab — `tab.tree` lags `surfaceTree` by up to 80ms via
        // the debounced `persistActive`, so a ⌘W landing right after a split would see
        // paneCount==1 and closeForkTab the freshly-split tree (see movePane :568-570).
        let count = tab.id == registry.activeTabID ? Array(surfaceTree).count : tab.tree.paneCount
        guard count > 1 else { closeForkTab(tab.id); return }
        // Sub deliberately NOT dropped on Detach: ⌘Z restores the surface into the tree
        // and re-observe has no hook. `paneDidSettle`'s `owningTab==nil` guard makes a
        // detached fire harmless; the `progressSubs` entry leaks like `refs` does
        // (in-memory, swept on `windowWillClose`).
        if let live = liveTabs[tab.id], let surface,
           let node = live.root?.node(view: surface) {
            if tab.id == registry.activeTabID {
                super.closeSurface(node, withConfirmation: false)
            } else {
                let pruned = live.removing(node)
                liveTabs[tab.id] = pruned
                registry.setPersistedTree(project(pruned.root), for: tab.id)
            }
        } else {
            registry.setPersistedTree(tab.tree.removing(ref), for: tab.id)
        }
    }

    func confirmKill(_ tab: TabModel) {
        guard let window, let host = registry.host(id: tab.hostID) else { return }
        let live = liveTabs[tab.id]?.compactMap { registry.refs[$0.id] } ?? []
        let refs = Array(Set(live.isEmpty ? tab.tree.leafRefs : live))
        guard !refs.isEmpty else { closeForkTab(tab.id); return }
        let alert = NSAlert()
        alert.messageText = "Kill \(refs.count) zmx session\(refs.count == 1 ? "" : "s")?"
        alert.informativeText = refs.map(\.name).joined(separator: ", ")
        alert.addButton(withTitle: "Kill")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            for ref in refs { Task { try? await ZmxAdapter.kill(host: host, ref: ref) } }
            self?.closeForkTab(tab.id)
        }
    }

    // MARK: Move pane / merge tab (PR21b)

    /// Move a pane from one tab into another (same host). `to == nil` creates a
    /// new destination tab. The live `SurfaceView` is reparented — its pty (zmx
    /// attach) keeps running since `registry.refs` isn't touched.
    ///
    /// Sequencing nuances: write `liveTabs[src]` / `liveTabs[dst]` BEFORE any
    /// `surfaceTree =` so `closeForkTab` (if src empties) reads the post-move
    /// state and doesn't unbind the moved surface. Skip `surfaceTree =` for the
    /// active-and-empty case — the sibling `activate(tab:)` inside closeForkTab
    /// will replace surfaceTree wholesale, avoiding an in-flight debounced
    /// `persistActive(empty)` landing under the newly-active sibling's id.
    func movePane(from src: TabModel.ID, ref: SessionRef, to dstOrNil: TabModel.ID?) {
        guard let srcTab = registry.tabs.first(where: { $0.id == src }),
              srcTab.tree.leafRefs.contains(ref) else { return }

        // Resolve destination.
        let dst: TabModel.ID
        if let existing = dstOrNil {
            guard let dstTab = registry.tabs.first(where: { $0.id == existing }),
                  dstTab.hostID == srcTab.hostID, existing != src else { return }
            dst = existing
        } else {
            dst = registry.newTab(on: srcTab.hostID, title: ref.name).id
            // Fresh tab has tree == .empty and no liveTabs entry. Without this seed,
            // `liveTree(for: dst)` below falls into rebuildTree → `revive(.empty) ??
            // revive(.leaf(nil))` and spawns a stray auto-named zmx session that the
            // moved pane gets inserted *alongside* (2 live leaves, 1 persisted).
            liveTabs[dst] = .init()
        }

        let srcLive = liveTree(for: src)
        // Live surface is required. Operating off persisted alone would let the
        // closeForkTab(src) check below unbind live panes that weren't moved — the
        // persisted ↔ live divergence window before the 80ms debounce settles.
        guard let surface = srcLive.first(where: { registry.refs[$0.id] == ref }),
              let srcNode = srcLive.root?.node(view: surface) else { return }

        let prunedSrc = srcLive.removing(srcNode)
        let dstLive = liveTree(for: dst)
        let extendedDst: SplitTree<Ghostty.SurfaceView>
        // Rightmost leaf + `.right` makes the depth-first-left traversal yield
        // `[...existing, moved]` — matches PersistedTree.appending(leaf:) so live
        // and persisted shapes agree even when dst is inactive (no debounced
        // persistActive.project() to paper over a mismatch).
        if let anchor = Array(dstLive).last {
            extendedDst = (try? dstLive.inserting(view: surface, at: anchor, direction: .right)) ?? dstLive
        } else {
            extendedDst = .init(view: surface)
        }
        liveTabs[src] = prunedSrc
        liveTabs[dst] = extendedDst
        if src == registry.activeTabID && !prunedSrc.isEmpty {
            surfaceTree = prunedSrc
        } else if dst == registry.activeTabID {
            surfaceTree = extendedDst
        }

        registry.movePanePersisted(from: src, ref: ref, to: dst)
        undoManager?.removeAllActions(withTarget: self)
        // Close src off LIVE state (prunedSrc), not the persisted tree. Persisted
        // can lag by up to 80ms after a recent split; reading it would auto-close
        // a tab whose live state still has panes.
        if prunedSrc.isEmpty {
            // Land on dst BEFORE closing src so closeForkTab's positional-neighbour
            // pick never runs — it would `rebuildTree` a dormant sibling and spawn its
            // zmx/ssh sessions for one frame. `nil` (not the empty tree) so
            // `activate(dst)`'s outgoing-snapshot guard and `closeForkTab`'s unbind
            // loop both skip src; the moved surface lives in dst now.
            liveTabs[src] = nil
            activate(tab: dst)
            closeForkTab(src)
        }
    }

    /// Fold every pane from `src` into `dst` (same host). Src auto-closes after.
    /// Iterates the LIVE tree (matches `movePane`'s surface requirement) and skips
    /// external (`@`-keyed) refs — moving an external reattaches someone else's
    /// session under a different tab, which is the split/merge-externals rabbit
    /// hole we're deliberately deferring per Fork/CLAUDE.md §Gotchas.
    func mergeTab(from src: TabModel.ID, into dst: TabModel.ID) {
        guard src != dst,
              let srcTab = registry.tabs.first(where: { $0.id == src }),
              let dstTab = registry.tabs.first(where: { $0.id == dst }),
              srcTab.hostID == dstTab.hostID else { return }
        let refs = Array(liveTree(for: src)).compactMap { registry.refs[$0.id] }.filter { !$0.external }
        for ref in refs {
            movePane(from: src, ref: ref, to: dst)
        }
    }

    // MARK: ⌘T / ⌘W — replace upstream's native-NSWindow-tab actions with sidebar tabs.

    @IBAction override func newTab(_ sender: Any?) {
        showSessionPicker(on: registry.activeHost ?? .local)
    }

    @IBAction override func closeTab(_ sender: Any?) {
        guard let active = registry.activeTabID else { return }
        closeForkTab(active)
    }

    private var sheetPanel: NSWindow?
    private var sheetResignSub: Any?

    func showNewSessionSheet() {
        presentSheet(size: .init(width: 640, height: 320)) { [weak self] in
            NewSessionView(defaultHostID: self?.registry.activeHost?.id ?? ForkHost.local.id,
                           onSubmit: { intent in self?.newForkTab(intent: intent); self?.endSheet() },
                           onCancel: { self?.endSheet() })
        }
    }

    /// Compact picker (same as ⌘D split) for the host context-menu — name or attach,
    /// no cwd/cmd fields. Use `showNewSessionSheet` for the full form.
    func showSessionPicker(on host: ForkHost) {
        let placeholder = registry.uniqueAutoName()
        presentSheet(size: .init(width: 280, height: 280)) { [weak self] in
            SplitPickerView(
                title: "New session on \(host.label)",
                host: host, placeholder: placeholder,
                onSubmit: { ref in
                    self?.newForkTab(intent: .init(hostID: ref.hostID, name: ref.name,
                                                   external: ref.external))
                    self?.endSheet()
                },
                onCancel: { self?.endSheet() })
        }
    }

    func showNewHostSheet() {
        presentSheet(size: .init(width: 360, height: 210)) { [weak self] in
            NewHostView(onDone: { self?.endSheet() })
        }
    }

    /// `id` not `ForkHost`: the only call site is a `.contextMenu` closure, which on macOS
    /// caches its content past body re-renders, so a captured struct goes stale and the
    /// sheet opens showing the pre-edit hue/icon. The id is immutable; look up fresh here.
    func showHostDetail(_ id: ForkHost.ID) {
        guard let host = registry.host(id: id) else { return }
        presentSheet(size: .init(width: 420, height: 420)) { [weak self] in
            HostDetailView(host: host, onDone: { self?.endSheet() })
        }
    }

    func showPanePalette() {
        // `CommandPaletteView` is a self-chromed card (material bg + rounded stroke +
        // .shadow(32) + .padding()) meant to float over `TerminalView`. macOS sheets
        // wrap content in a system `NSVisualEffectView` that `backgroundColor = .clear`
        // can't suppress, so present as a borderless child window instead. 620×460
        // leaves ~60pt clear margin so the card's shadow doesn't clip at the panel edge.
        presentSheet(size: .init(width: 620, height: 460), bare: true) { [weak self] in
            ForkPanePalette(controller: self, onDone: { self?.endSheet() })
        }
    }

    func showScrollbackSearch() {
        presentSheet(size: .init(width: 600, height: 420)) { [weak self] in
            ScrollbackSearchView(controller: self, onDone: { self?.endSheet() })
        }
    }

    private func presentSheet<V: View>(size: CGSize, bare: Bool = false,
                                       @ViewBuilder _ content: () -> V) {
        guard let window, sheetPanel == nil else { return }
        let host = NSHostingController(rootView: content().environmentObject(registry))
        host.sizingOptions = []  // honor `size`, not SwiftUI's ideal — else padding/shadow inflate the panel
        host.view.frame = .init(origin: .zero, size: size)
        let panel = ForkSheetPanel(contentViewController: host)
        sheetPanel = panel
        guard bare else { window.beginSheet(panel); return }
        panel.styleMask = .borderless
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // CommandPaletteView draws its own
        let parent = window.frame
        panel.setFrameOrigin(.init(x: parent.midX - size.width / 2,
                                   y: parent.midY - size.height / 2))
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        sheetResignSub = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in self?.endSheet() }
    }

    private func endSheet() {
        guard let panel = sheetPanel else { return }
        if let sub = sheetResignSub {
            NotificationCenter.default.removeObserver(sub)
            sheetResignSub = nil
        }
        if panel.isSheet {
            window?.endSheet(panel)
        } else {
            window?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        sheetPanel = nil
    }

    // MARK: Window setup — wrap upstream's contentView in a sidebar split.

    override func windowDidResignKey(_ notification: Notification) {
        super.windowDidResignKey(notification)
        setCheatsheet(false)
    }

    override func windowWillClose(_ notification: Notification) {
        // Run-loop / NSEvent retain these independently of `self`; weak-self in the
        // closures makes the firings no-ops, but the timers/monitors themselves leak.
        navMonitor.map(NSEvent.removeMonitor); navMonitor = nil
        cheatMonitor.map(NSEvent.removeMonitor); cheatMonitor = nil
        cheatsheetTimer?.invalidate(); cheatsheetTimer = nil
        // `paneState` lives on the singleton and `ForkNotify.badgeSub` outlives this
        // controller; reopen mints fresh surface UUIDs so the old `.waiting` entries
        // would be unreachable and the dock badge stuck.
        for id in Array(progressSubs.keys) { stopObservingProgress(id) }
        endSheet()  // drops sheetResignSub; child-window auto-close doesn't guarantee resign-key fires first
        super.windowWillClose(notification)
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        guard let window, let terminalContent = window.contentView else { return }

        window.tabbingMode = .disallowed
        window.isRestorable = false

        if ForkBootstrap.noSidebar {
            $surfaceTree
                .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
                .sink { [weak self] tree in self?.persistActive(tree) }
                .store(in: &cancellables)
            installNavMonitor()
            return
        }

        // Upstream's `BaseTerminalController.terminalViewContainer` is
        // `window?.contentView as? TerminalViewContainer`, and `SurfaceRepresentable`
        // re-creates its `SurfaceScrollView` wrapper whenever the split-tree's
        // `.id(structuralIdentity)` changes — both assume the container is
        // contentView. Reparenting it into an NSSplitView broke split rendering.
        // Instead: keep `terminalContent` as `window.contentView`, add the sidebar
        // as a sibling subview of the container, and re-pin the container's inner
        // hosting view to start after the sidebar.
        let sidebar = NSHostingView(rootView: SidebarView(controller: self).environmentObject(registry))
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        terminalContent.addSubview(sidebar)
        sidebarHost = sidebar
        sidebarWidthConstraint = sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: terminalContent.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: terminalContent.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: terminalContent.bottomAnchor),
            sidebarWidthConstraint!,
        ])
        // Shift the existing terminal hosting view (first subview, pinned to all
        // edges by TerminalViewContainer.setup()) to the right of the sidebar.
        // Pin to a constant offset, NOT `sidebar.trailingAnchor`, so SwiftUI re-renders
        // inside the sidebar's NSHostingView can't cascade into terminal autolayout
        // and re-set surface frames mid-SIGWINCH.
        if let hosting = terminalContent.subviews.first(where: { $0 !== sidebar }) {
            terminalContent.constraints
                .filter { ($0.firstItem === hosting && $0.firstAttribute == .leading)
                       || ($0.secondItem === hosting && $0.secondAttribute == .leading) }
                .forEach { $0.isActive = false }
            terminalLeadingConstraint = hosting.leadingAnchor.constraint(
                equalTo: terminalContent.leadingAnchor, constant: Self.sidebarWidth)
            terminalLeadingConstraint!.isActive = true
        }

        let cheatsheet = NSHostingView(rootView: CheatsheetView(hoverCommands: registry.hoverCommands))
        cheatsheet.translatesAutoresizingMaskIntoConstraints = false
        cheatsheet.isHidden = true
        terminalContent.addSubview(cheatsheet)
        cheatsheetHost = cheatsheet
        cheatsheetCenterX = cheatsheet.centerXAnchor.constraint(
            equalTo: terminalContent.centerXAnchor, constant: Self.sidebarWidth / 2)
        NSLayoutConstraint.activate([
            cheatsheetCenterX!,
            cheatsheet.centerYAnchor.constraint(equalTo: terminalContent.centerYAnchor),
        ])

        let reveal = NSButton(image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Show sidebar")!,
                              target: self, action: #selector(revealSidebar(_:)))
        reveal.isBordered = false
        reveal.isHidden = true
        reveal.translatesAutoresizingMaskIntoConstraints = false
        terminalContent.addSubview(reveal)
        NSLayoutConstraint.activate([
            reveal.leadingAnchor.constraint(equalTo: terminalContent.leadingAnchor, constant: 8),
            reveal.topAnchor.constraint(equalTo: terminalContent.topAnchor, constant: 8),
        ])
        sidebarReveal = reveal

        $surfaceTree
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] tree in self?.persistActive(tree) }
            .store(in: &cancellables)
        registry.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.syncWindowTitle() }
            .store(in: &cancellables)
        syncWindowTitle()
        installNavMonitor()
    }

    /// `BaseTerminalController.titleOverride` (`:94`) wins over `focusedSurface.title`.
    /// zmx is OSC-transparent, so shell title *does* reach `SurfaceView.title`; we just
    /// prefer the registry-derived "{tab} — {host}" for the window chrome.
    private func syncWindowTitle() {
        guard let tab = registry.activeTab else { titleOverride = nil; return }
        let host = registry.host(id: tab.hostID)?.label ?? tab.hostID
        titleOverride = "\(tab.title) — \(host)"
    }

    // MARK: Tab management

    func activate(tab id: TabModel.ID, paneIndex: Int? = nil) {
        // ForkNotify.didReceive can pass a stale banner's tab ID; setting `activeTabID`
        // to a dead ID dangles `surfaceTree` (rebuildTree bails) and breaks split/stepTab.
        guard registry.tabs.contains(where: { $0.id == id }) else { return }
        let current = registry.activeTabID
        if current != id {
            // Snapshot the outgoing tab ONLY if it's been hydrated this session. On
            // cold start `current` is the disk-loaded id but `surfaceTree` is the
            // placeholder `.init()` — snapshotting that would set `current`'s persisted
            // tree to `.empty` and prune its labels/tags/lastActive.
            if let current, liveTabs[current] != nil {
                liveTabs[current] = surfaceTree
                registry.setPersistedTree(project(surfaceTree.root), for: current)
            }
            // Upstream's undo closures capture a *tree*, not a tab. Clear on every real
            // switch — including `current == nil`, which closeForkTab/removeHost produce.
            undoManager?.removeAllActions(withTarget: self)
            registry.setActive(tab: id)
        }
        // Relaunch arrives with `current == id` (registry loads activeTabID from disk) but
        // no `liveTabs` entry — must still rebuild AND assign, or `persistActive(.init())`
        // wipes it. `cold` discriminates that from a warm re-click on the active tab.
        let cold = liveTabs[id] == nil
        if cold { rebuildTree(for: id) }
        if current != id || cold, let tree = liveTabs[id] { surfaceTree = tree }
        // `surfaceTree.leaves()` and `PersistedTree.leafRefs` are both depth-first-left,
        // so the sidebar's pane-row offset addresses the matching live SurfaceView.
        // Write the highlight index in the same tick as `setActive` above; the async
        // focus roundtrip lands a frame later and would briefly show the prior tab's index.
        let leaves = Array(surfaceTree)
        registry.clearWaiting(surfaces: leaves.lazy.map(\.id))
        registry.ackBlocked(refs: leaves.lazy.compactMap { self.registry.refs[$0.id] })
        notifiedSurfaces.subtract(leaves.lazy.map(\.id))
        // Synchronous MRU touch: `focusedSurfaceDidChange` → `touchPane` is async via
        // `@FocusedValue.onChange`, and the `paneIndex == nil` path below never sets
        // `focusedSurface`, so a new tab could be switched away from with `lastActive`
        // still empty (drops off focus-mode's 16h list).
        let touchIdx = paneIndex ?? 0
        if leaves.indices.contains(touchIdx), let key = registry.refs[leaves[touchIdx].id]?.key {
            registry.touchPane(tab: id, name: key)
        }
        registry.setFocusedPane(index: paneIndex)
        guard let paneIndex else { return }
        guard leaves.indices.contains(paneIndex) else { return }
        let target = leaves[paneIndex]
        // The sidebar click already stole firstResponder; writing `focusedSurface` (even
        // to the same value) fires its `didSet → syncFocusToSurfaceTree()`, which checks
        // `isFirstResponder` and would mark every pane unfocused mid-transition.
        if focusedSurface !== target { focusedSurface = target }
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(target)
        }
    }

    override func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {
        super.focusedSurfaceDidChange(to: to)
        // nil = focus left the split tree (sidebar click, sheet, etc.) — keep last-known
        // index so the highlight doesn't snap to head and back. `activate()` writes nil
        // explicitly when it actually wants the head fallback.
        guard let to else { return }
        registry.setFocusedPane(index: Array(surfaceTree).firstIndex { $0 === to })
        if let tab = registry.activeTabID, let key = registry.refs[to.id]?.key {
            registry.touchPane(tab: tab, name: key)
        }
    }

    func newForkTab(intent: NewSessionIntent) {
        guard let host = registry.host(id: intent.hostID), let app = ghostty.app else { return }
        let ref = SessionRef(hostID: host.id, name: intent.name ?? registry.uniqueAutoName(),
                             external: intent.external)
        let cfg = ZmxAdapter.surfaceConfig(host: host, ref: ref, initialCmd: intent.cmd, cwd: intent.cwd)
        let surface = Ghostty.SurfaceView(app, baseConfig: cfg)
        registry.bind(surface: surface.id, to: ref)
        observeProgress(surface)
        let tab = registry.newTab(on: host.id, title: ref.name)
        liveTabs[tab.id] = .init(view: surface)
        // Match `gotoHost`/`revealRow`: force-expand so the new row is visible. Without this,
        // ⌘T onto a collapsed host swaps the terminal in but the sidebar shows nothing new.
        registry.setExpanded(host.id, true)
        activate(tab: tab.id)
    }

    /// Per-surface unbind + watch teardown for a tab's live tree, then drop the tree.
    /// Shared by `closeForkTab` and `removeHost` — the latter must NOT go through
    /// `closeForkTab` (see `removeHost` for the dormant-sibling-spawn hazard).
    private func dropLiveTab(_ id: TabModel.ID) {
        guard let tree = liveTabs.removeValue(forKey: id) else { return }
        for surface in tree {
            registry.unbind(surface: surface.id)
            stopObservingProgress(surface.id)
        }
    }

    func closeForkTab(_ id: TabModel.ID) {
        dropLiveTab(id)
        let wasActive = registry.activeTabID == id
        let host = registry.tabs.first { $0.id == id }?.hostID
        let i = host.flatMap { h in registry.tabs(on: h).firstIndex { $0.id == id } }
        registry.removeTab(id)
        guard wasActive else { return }
        let siblings = host.map(registry.tabs(on:)) ?? []
        let next = i.flatMap { siblings.indices.contains($0) ? siblings[$0].id : siblings.last?.id }
            ?? registry.tabs.first?.id
        if let next {
            activate(tab: next)
        } else {
            surfaceTree = .init()
        }
    }

    // MARK: Split — picker first (new vs attach-existing), then split (SPEC §5).

    private var pendingSplit: (at: Ghostty.SurfaceView, dir: SplitTree<Ghostty.SurfaceView>.NewDirection)?

    @discardableResult
    override func newSplit(
        at oldView: Ghostty.SurfaceView,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
        baseConfig config: Ghostty.SurfaceConfiguration? = nil
    ) -> Ghostty.SurfaceView? {
        guard sheetPanel == nil, let host = registry.activeHost else {
            // ⌘D leaks past an open sheet via the responder chain (same path as the ⌘V
            // gotcha). super.newSplit would spawn a non-zmx, unbound pane; swallow instead.
            return nil
        }
        let placeholder = registry.uniqueAutoName(derivedFrom: registry.refs[oldView.id]?.name)
        if ForkBootstrap.noPicker {
            return completeSplit(at: oldView, direction: direction, host: host,
                                 ref: .init(hostID: host.id, name: placeholder))
        }
        pendingSplit = (oldView, direction)
        presentSheet(size: .init(width: 280, height: 280)) { [weak self] in
            SplitPickerView(
                title: "Split on \(host.label)",
                host: host, placeholder: placeholder,
                onSubmit: { ref in
                    guard let self, let p = self.pendingSplit else { return }
                    self.pendingSplit = nil
                    _ = self.completeSplit(at: p.at, direction: p.dir, host: host, ref: ref)
                    self.endSheet()
                },
                onCancel: { self?.pendingSplit = nil; self?.endSheet() })
        }
        return nil
    }

    /// `super.` won't resolve inside the SwiftUI button-action closure above.
    private func completeSplit(
        at oldView: Ghostty.SurfaceView,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
        host: ForkHost, ref: SessionRef, initialCmd: [String]? = nil
    ) -> Ghostty.SurfaceView? {
        let cfg = ZmxAdapter.surfaceConfig(host: host, ref: ref, initialCmd: initialCmd)
        guard let view = super.newSplit(at: oldView, direction: direction, baseConfig: cfg) else { return nil }
        registry.bind(surface: view.id, to: ref)
        observeProgress(view)
        return view
    }

    // MARK: Persistence projection

    private func persistActive(_ tree: SplitTree<Ghostty.SurfaceView>) {
        guard let active = registry.activeTabID else { return }
        liveTabs[active] = tree
        // Intentionally no `pruneRefs` here: upstream's undo (`replaceSurfaceTree`
        // registers Close-Terminal undo) holds a strong ref to the closed SurfaceView;
        // pruning then ⌘Z → `project()` reads `refs[id] == nil` → persists `.leaf(nil)`.
        registry.setPersistedTree(project(tree.root), for: active)
    }

    private func project(_ node: SplitTree<Ghostty.SurfaceView>.Node?) -> PersistedTree {
        guard let node else { return .empty }
        switch node {
        case .leaf(let v):
            return .leaf(registry.refs[v.id])
        case .split(let s):
            return .split(
                horizontal: s.direction == .horizontal,
                ratio: s.ratio,
                a: project(s.left),
                b: project(s.right))
        }
    }

    /// Lazy reattach (SPEC §7): rebuild a live tree from a persisted one.
    private func rebuildTree(for tabID: TabModel.ID) {
        guard let tab = registry.tabs.first(where: { $0.id == tabID }),
              let host = registry.host(id: tab.hostID),
              let app = ghostty.app else { return }
        func revive(_ p: PersistedTree) -> SplitTree<Ghostty.SurfaceView>.Node? {
            switch p {
            case .empty: return nil
            case .leaf(let ref):
                let r = ref ?? SessionRef(hostID: host.id, name: registry.uniqueAutoName())
                let cfg = ZmxAdapter.surfaceConfig(host: host, ref: r,
                                                   initialCmd: tab.ccNames[r.key].map(ZmxAdapter.restoreCmd))
                let v = Ghostty.SurfaceView(app, baseConfig: cfg)
                registry.bind(surface: v.id, to: r)
                observeProgress(v)
                return .leaf(view: v)
            case .split(let h, let ratio, let a, let b):
                let na = revive(a), nb = revive(b)
                guard let na, let nb else { return na ?? nb }
                return .split(.init(direction: h ? .horizontal : .vertical, ratio: ratio, left: na, right: nb))
            }
        }
        let root = revive(tab.tree) ?? revive(.leaf(nil))
        liveTabs[tabID] = SplitTree<Ghostty.SurfaceView>(root: root, zoomed: nil)
    }

    /// Live tree for a tab, hydrating from persisted if it's never been activated this
    /// session. Distinguishes the three states: active → `surfaceTree`, parked-inactive
    /// → cached `liveTabs[id]`, never-activated → `rebuildTree` then return the cache.
    /// Never returns the `?? .init()` lie that lets a single-leaf write later poison
    /// `persistActive` — see PR21 review (movePane into dormant dst dropped panes).
    private func liveTree(for id: TabModel.ID) -> SplitTree<Ghostty.SurfaceView> {
        if id == registry.activeTabID { return surfaceTree }
        if liveTabs[id] == nil { rebuildTree(for: id) }
        return liveTabs[id] ?? .init()
    }
}

/// `.overlay` hover-command panel. Subclasses `QuickTerminalController` to inherit the
/// slide-in panel + auto-close-on-exit, but gates `animateIn` until `ready` so the lazy
/// `windowDidLoad` (which fires inside `super.init` via the same chain documented in
/// CLAUDE.md §Gotchas) doesn't create a default-shell surface we'd immediately swap out —
/// dealloc'ing that mid-spawn `_exit(1)`s the process in optimized builds.
final class ForkOverlayController: QuickTerminalController {
    private var ready = false
    private var exitSub: AnyCancellable?

    convenience init(_ ghostty: Ghostty.App) {
        self.init(ghostty, position: .center, restorationState: nil)
    }

    override func animateIn() {
        guard ready else { return }
        super.animateIn()
    }

    /// Show `surface` and slide out when its process exits. `embedded.zig:534` forces
    /// `wait-after-command = true` whenever `command` is set, so `Surface.zig:1298` returns
    /// before `self.close()` and QTC's `closeSurface` path never fires. `processExited` is
    /// computed (not @Published); `childExitedMessage` is the @Published proxy set by
    /// `showChildExited` (Ghostty.App.swift:1653) on the same path.
    func present(_ surface: Ghostty.SurfaceView) {
        exitSub = surface.$childExitedMessage.compactMap { $0 }.first()
            .sink { [weak self] _ in self?.surfaceTree = .init() }
        surfaceTree = .init(view: surface)
        ready = true
        if !visible { animateIn() }
    }
}
#endif
