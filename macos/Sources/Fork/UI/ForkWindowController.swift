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

    /// Upstream's close-window undo (`registerUndoForCloseWindow`) restores a plain
    /// `TerminalController` — no sidebar, no registry bindings — dup-attached to the same
    /// zmx sessions. Its undo target is `ghostty`, not this controller, so the
    /// `removeAllActions(withTarget: self)` idiom can't reach it; disable registration
    /// across the close so ⌘Z after closing the fork window is a no-op instead.
    override func closeWindowImmediately() {
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }
        super.closeWindowImmediately()
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
        // Tear the dead surface down BEFORE binding its replacement: with the placeholder
        // already bound to the same ref, `isLastSurface` sees a sibling, the `.detached`
        // phase-reset never fires, and a pane that died mid-turn keeps a wedged `.working`
        // spinner (the placeholder replays no OSC to settle it). Stop-then-unbind order
        // within the teardown still matters — stopObservingProgress reads `refs[id]`.
        stopObservingProgress(dead.id)
        registry.unbind(surface: dead.id)
        registry.bind(surface: placeholder.id, to: ref)
        observeProgress(placeholder)
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
            let refs = killableRefs(for: tab)
            confirmDetachOrKill(
                messageText: "Close tab '\(tab.title)'?",
                informativeText: refs.isEmpty
                    ? "No zmx sessions are bound to this tab."
                    : "Detach leaves \(refs.count) zmx session\(refs.count == 1 ? "" : "s") running. Reattach from ⌘T or the split picker.",
                killTitle: refs.count > 1 ? "Kill \(refs.count) Sessions" : "Kill Session",
                killEnabled: !refs.isEmpty,
                onDetach: { [weak self] in self?.closeForkTab(tab.id) },
                onKill: { [weak self] in
                    self?.killSessions(refs, on: host)
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
                    self.stopObservingProgress(surface.id)
                    self.registry.unbind(surface: surface.id)
                    self.killSessions([ref], on: host)
                    self.dropPane(tab: tab, ref: ref, surface: surface)
                }
            )
            return
        }

        super.closeSurface(node, withConfirmation: false)
    }

    /// ⌘W sheet: Detach (⏎, default) / Kill (K or a second ⌘W, destructive) / Cancel (Esc).
    private func confirmDetachOrKill(
        messageText: String,
        informativeText: String,
        killTitle: String = "Kill Session",
        killEnabled: Bool = true,
        onDetach: @escaping () -> Void,
        onKill: @escaping () -> Void
    ) {
        guard let window else { onDetach(); return }
        // A sheet is already up (⌘T/⌘D/Hosts panel, or an earlier close-confirm): a second
        // beginSheetModal on the same window queues *invisibly* behind it — nothing appears,
        // then a surprise close-confirm pops after the first sheet ends, where a reflexive ⏎
        // closes a tab the user never asked about. Refuse instead.
        guard sheetPanel == nil, window.attachedSheet == nil else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText + "\n\n⏎ Detach · K or ⌘W Kill · Esc Cancel"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Detach")
        let kill = alert.addButton(withTitle: killTitle)
        kill.keyEquivalent = "k"
        kill.hasDestructiveAction = true
        kill.isEnabled = killEnabled
        alert.addButton(withTitle: "Cancel")
        // ⌘W,⌘W = Kill: the second ⌘W lands on the alert panel (now key), where it would
        // otherwise just beep — treating it as "yes, really close it" keeps the whole
        // gesture on one chord. A button only carries one keyEquivalent, so K stays the
        // labelled shortcut and this monitor adds the ⌘W alias for the sheet's lifetime.
        let wMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            // `!isARepeat`: the alias must be a second deliberate press — a *held* ⌘W
            // auto-repeats into the just-presented sheet and would fire Kill (and then
            // chain into the next pane's sheet) with no chance to Esc.
            guard ev.window === alert.window,
                  !ev.isARepeat,
                  ev.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  ev.charactersIgnoringModifiers?.lowercased() == "w",
                  kill.isEnabled else { return ev }
            kill.performClick(nil)
            return nil
        }
        alert.beginSheetModal(for: window) { resp in
            wMonitor.map(NSEvent.removeMonitor)
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

    /// `charactersIgnoringModifiers` does not strip Option (it's a character-producing
    /// modifier), so ⌥-digit must be matched by physical keyCode.
    private static let digitKeyCodes: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]

    private func installNavMonitor() {
        navMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .swipe]
        ) { [weak self] ev in
            guard let self, ev.window === self.window else { return ev }
            // Mouse back/forward → tab visit history, window-wide (sidebar or terminal area
            // alike, matching browser behavior). Two delivery paths, because mouse drivers
            // differ in what the thumb buttons actually emit:
            //
            // 1. SWIPE gestures (deltaX +1 = back, -1 = forward — the Safari/WebKit
            //    convention). This is what SteerMouse / Logi Options+ / the system's
            //    "swipe between pages" translate thumb buttons into, and what trackpad
            //    page-swipes deliver. Vertical swipes pass through.
            // 2. Raw buttons 3/4 (.otherMouse*) for mice whose driver passes them through
            //    untranslated. ALL button-3/4 event types are swallowed, not just the down:
            //    a consumed press with a passed-through release would deliver an orphaned
            //    SGR button-8/9 *release* to whatever pane is under the cursor after the
            //    tab switch — clearing its selection and feeding a TUI a button it never
            //    saw pressed. Button 2 (middle-click paste) passes through untouched.
            //
            // Both paths are swallowed-but-inert while a fork sheet or the ⌘W alert
            // (`window.attachedSheet`) is up — navigating under a modal would swap the
            // content its confirmation text refers to.
            let modalUp = self.sheetPanel != nil || self.window?.attachedSheet != nil
            if ev.type == .swipe {
                guard ev.deltaX != 0 else { return ev }
                if !modalUp { self.navigateTabHistory(ev.deltaX > 0 ? -1 : +1) }
                return nil
            }
            if ev.type != .keyDown {
                switch ev.buttonNumber {
                case 3, 4:
                    if ev.type == .otherMouseDown, !modalUp {
                        self.navigateTabHistory(ev.buttonNumber == 3 ? -1 : +1)
                    }
                    return nil
                default: return ev
                }
            }
            guard self.sheetPanel == nil else { return ev }
            // Any keystroke = chord completed (or non-⌘ typing) → hide/cancel cheatsheet.
            self.setCheatsheet(false)
            let mods = ev.modifierFlags.intersection([.command, .shift, .option, .control])
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
            // ⌘⌥A / ⌘⌥P — one-shot watch on focused pane / pin active tab. keyCode 0 = A,
            // 35 = P; `charactersIgnoringModifiers` doesn't strip Option (digit comment above).
            if mods == [.command, .option] {
                if ev.keyCode == 0 { self.toggleWatch(); return nil }
                if ev.keyCode == 35, let id = self.registry.activeTabID,
                   let tab = self.registry.tabs.first(where: { $0.id == id }) {
                    self.registry.setPinned(id, !tab.pinned); return nil
                }
            }
            // ⌘⇧R — repaint focused surface (SurfaceWiggle). keyCode 15.
            if mods == [.command, .shift], ev.keyCode == 15,
               let s = self.focusedSurface { forkWigglePane(s); return nil }
            // ⌘⇧T — same two-stage session palette as ⌘T (the old full form's cwd/cmd
            // fields are gone, so it's now just an alias). keyCode 17 = kVK_ANSI_T.
            // Shadows upstream's `undo` alias (Config.zig:6934) — ⌘Z remains undo.
            if mods == [.command, .shift], ev.keyCode == 17 {
                self.showSessionPicker(); return nil
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

    /// ⌘K-palette entry point for `hoverCommands` — runs on the *focused* pane (the only
    /// caller now that bare-letter hover dispatch is gone).
    func runPaneCommand(_ cmd: HoverCommand) {
        guard let surface = focusedSurface, let ref = registry.refs[surface.id],
              let host = registry.host(id: ref.hostID) else { return }
        // OSC 7 (real-time, needs shell integration) › CCProbe poll (3s lag, no integration needed).
        let paneCwd = surface.pwd ?? registry.ccLive[ref.hostID]?[ref.key]?.cwd
        // `.local` executes on the Mac: a remote pane's cwd is remote-controlled (OSC 7 can
        // simply claim `localhost`; the CC probe's cwd field isn't validated at all) and
        // must not steer what a local tool opens or operates on. Remote panes degrade to
        // nil → `expand` substitutes ".". `.pane` runs on the pane's own host, where its
        // cwd is legitimate.
        let cwd = (cmd.mode == .pane || host.transport.isLocal) ? paneCwd : nil
        let argv = ZmxAdapter.expand(cmd.cmd, host: host, ref: ref, cwd: cwd)
        switch cmd.mode {
        case .local:
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = argv
            // launchd PATH means "tool not found" (env exits 127) is the common failure for
            // these bindings — without at least a log line it's indistinguishable from the
            // command doing nothing.
            p.terminationHandler = { proc in
                guard proc.terminationStatus != 0 else { return }
                ForkBootstrap.logger.warning(
                    "hover command \(argv.first ?? "?") exited \(proc.terminationStatus)")
            }
            do { try p.run() } catch {
                ForkBootstrap.logger.warning(
                    "hover command \(argv.first ?? "?") failed to launch: \(String(describing: error))")
            }
        case .pane:
            // External `ref.name` may carry chars outside the validated set; only seed the
            // derived name from validated refs so the new (non-external) ref stays `isValid`.
            let seed = ref.isValid ? ref.name : nil
            let new = SessionRef(hostID: host.id, name: registry.uniqueAutoName(derivedFrom: seed))
            _ = completeSplit(at: surface, direction: .right, host: host, ref: new,
                              initialCmd: argv)
        }
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

    // MARK: Watch (⌘⌥A) — one-shot alert on completion (PR24).
    //
    // MARK: Pane status — `PaneEvent` translators.
    //
    // The controller observes the surface-level inputs and translates each into a
    // `PaneEvent` on the surface's `SessionRef`; `PaneMachine.apply` decides the rest.
    // Upstream's `progressReport` didSet (SurfaceView_AppKit.swift:31) auto-nils after
    // 15s of no fresh OSC 9;4; the 250ms timer here absorbs CC's per-tool-call clear/set
    // flicker so `.settled` fires once per turn, not per gap.

    private var progressSubs: [UUID: AnyCancellable] = [:]
    private var settleTimers: [UUID: Timer] = [:]

    func toggleWatch() {
        guard let id = focusedSurface?.id, let ref = registry.refs[id] else { return }
        registry.apply(ref, .watch(!(registry.panes[ref]?.watched ?? false)))
    }

    @objc private func bellDidRing(_ n: Notification) {
        // `owningTab` BEFORE `apply(.bell)` — `.bell` consumes `watched`, so an orphan
        // surface (undo-stack-retained) would otherwise clear a dup-attached sibling's
        // watch without posting.
        guard let surface = n.object as? Ghostty.SurfaceView,
              let ref = registry.refs[surface.id], let tab = owningTab(of: surface) else { return }
        // Ref-wide active check (same shape as paneDidSettle): a bell in the visible tab
        // is interaction noise — PaneMachine ignores it entirely, so it can't consume the
        // watch or swallow a much-later completion banner.
        let isActive = liveRefs(for: registry.activeTabID ?? .init()).contains(ref)
        guard registry.apply(ref, .bell(isActive: isActive)) else { return }
        ForkNotify.shared.post(tab: tab.id,
                               title: "\(paneDisplayLabel(tab: tab, surface: surface)) finished",
                               body: "Tab '\(tab.title)'")
    }

    private func observeProgress(_ surface: Ghostty.SurfaceView) {
        progressSubs[surface.id] = surface.$progressReport
            .dropFirst()
            .sink { [weak self, weak surface] report in
                guard let self, let surface,
                      let ref = registry.refs[surface.id] else { return }
                settleTimers.removeValue(forKey: surface.id)?.invalidate()
                // Orphan (Detach-ed, undo-stack-retained — sub kept for ⌘Z): reset phase if
                // we're the last surface (else a dup-attached sibling owns it). `.detached`
                // is phase-only, so `watched`/`blockSig` survive ⌘W→⌘Z.
                guard owningTab(of: surface) != nil else {
                    if isLastSurface(for: ref, except: surface.id) {
                        registry.apply(ref, .detached)
                    }
                    return
                }
                guard report == nil else { registry.apply(ref, .progress); return }
                guard registry.panes[ref]?.phase == .working else { return }
                settleTimers[surface.id] = .scheduledTimer(withTimeInterval: 0.25, repeats: false) {
                    [weak self, weak surface] _ in
                    MainActor.assumeIsolated {
                        guard let self, let surface else { return }
                        self.settleTimers[surface.id] = nil
                        self.paneDidSettle(ref, surface: surface)
                    }
                }
            }
    }

    private func paneDidSettle(_ ref: SessionRef, surface: Ghostty.SurfaceView) {
        // Orphan reachable only if Detach raced the 250ms timer (armed-then-orphaned).
        guard let tab = owningTab(of: surface) else {
            if isLastSurface(for: ref, except: surface.id) { registry.apply(ref, .detached) }
            return
        }
        // Dup-attach (PR26): both surfaces fire .settled with their own tab's `isActive`
        // (last-writer-wins on the shared machine). Compute it ref-wide so both calls agree.
        let isActive = liveRefs(for: registry.activeTabID ?? .init()).contains(ref)
        if registry.apply(ref, .settled(isActive: isActive)) {
            // Same word as the bell banner — they're the same event to the user.
            ForkNotify.shared.post(tab: tab.id,
                                   title: "\(paneDisplayLabel(tab: tab, surface: surface)) finished",
                                   body: "Tab '\(tab.title)'")
        }
    }

    /// Reads `registry.refs[id]` — call BEFORE `registry.unbind(surface:)`.
    private func stopObservingProgress(_ id: UUID) {
        progressSubs.removeValue(forKey: id)
        settleTimers.removeValue(forKey: id)?.invalidate()
        // Only `.detached` when this was the *last* surface for the ref — dup-attached
        // refs (PR26) keep their machine while any surface remains.
        if let ref = registry.refs[id], isLastSurface(for: ref, except: id) {
            registry.apply(ref, .detached)
        }
    }
    private func isLastSurface(for ref: SessionRef, except id: UUID) -> Bool {
        !progressSubs.keys.contains { $0 != id && registry.refs[$0] == ref }
    }

    private func owningTab(of surface: Ghostty.SurfaceView) -> TabModel? {
        registry.tabs.first { surfaces(for: $0.id).contains { $0 === surface } }
    }

    private func paneDisplayLabel(tab: TabModel?, surface: Ghostty.SurfaceView) -> String {
        let ref = registry.refs[surface.id]
        let osc = (surface.title.isEmpty || surface.title == "👻") ? nil : surface.title
        let raw = ref.flatMap { tab?.paneLabels[$0.key] } ?? osc ?? ref?.name ?? "Pane"
        // OSC titles and external ref names are remote-controlled, and this string becomes
        // a UN notification title — strip control chars / cap length at the sink.
        return stripControl(raw, max: 96)
    }

    // MARK: Sidebar visibility & width

    /// Floor width — the classic fixed sidebar width. Drag the sidebar's right edge to
    /// widen (up to `sidebarMaxWidth` or half the window, whichever is smaller); the
    /// chosen width persists across launches and is what hide/show toggles back to.
    private static let sidebarMinWidth: CGFloat = 248
    private static let sidebarMaxWidth: CGFloat = 560
    private static let sidebarWidthKey = "ForkSidebarWidth"
    /// Persisted user width, clamped to [floor, max] AND the current window's half-width
    /// (a 560pt sidebar saved on a desktop display must not eat 70% of a laptop window
    /// at restore). The window cap never undercuts the floor — on a degenerate <496pt
    /// window the classic fixed width wins, same as it always did.
    private var sidebarWidth: CGFloat {
        let v = CGFloat(UserDefaults.standard.double(forKey: Self.sidebarWidthKey))
        guard v > 0 else { return Self.sidebarMinWidth }
        let cap = max(Self.sidebarMinWidth, (window?.frame.width ?? Self.sidebarMaxWidth * 2) / 2)
        return min(max(v, Self.sidebarMinWidth), Self.sidebarMaxWidth, cap)
    }
    private weak var sidebarHost: NSView?
    private weak var sidebarReveal: NSButton?
    private weak var sidebarHandle: NSView?
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var terminalLeadingConstraint: NSLayoutConstraint?

    func toggleSidebar() {
        guard let sidebarHost, let sidebarWidthConstraint, let terminalLeadingConstraint else { return }
        let hide = sidebarWidthConstraint.constant > 0
        let w: CGFloat = hide ? 0 : sidebarWidth
        if !hide { sidebarHost.isHidden = false }
        sidebarReveal?.isHidden = !hide
        // Hide the resize handle immediately on collapse (it must not stay grabbable over
        // the terminal's left edge); reappears with the sidebar.
        sidebarHandle?.isHidden = hide
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

    /// Applies a proposed sidebar width (from the drag handle) to all three dependent
    /// constraints. Live drags don't persist (`commit: false`); mouse-up does.
    private func setSidebarWidth(_ proposed: CGFloat, commit: Bool) {
        let cap = min(Self.sidebarMaxWidth, (window?.frame.width ?? 1200) / 2)
        let w = min(max(proposed, Self.sidebarMinWidth), cap)
        sidebarWidthConstraint?.constant = w
        terminalLeadingConstraint?.constant = w
        cheatsheetCenterX?.constant = w / 2
        if commit { UserDefaults.standard.set(Double(w), forKey: Self.sidebarWidthKey) }
    }

    @objc private func revealSidebar(_ sender: Any?) { toggleSidebar() }

    /// The tab list the sidebar is currently rendering — the single contract for every
    /// list-relative navigation (⌘1-9, ⌘⇧[/⌘⇧], last_tab, move_tab). One accessor so a
    /// filter added to one side can't silently desync keyboard order from screen order
    /// (the original bug: only gotoTab was upgraded to the filtered accessors; stepTab/
    /// last_tab/move_tab kept cycling through tabs hidden by focus mode / the tag filter).
    private func visibleTabs() -> [TabModel] {
        let d = UserDefaults.standard
        let tagged = d.bool(forKey: SessionRegistry.kFilterTagged)
        if d.bool(forKey: SessionRegistry.kFocusMode) {
            return registry.focusTabs(taggedOnly: tagged)
        }
        let host = registry.activeHost?.id ?? ForkHost.local.id
        return registry.hostTabs(on: host, taggedOnly: tagged)
    }

    private func stepTab(_ delta: Int) {
        guard let active = registry.activeTab else { return }
        let tabs = visibleTabs()
        guard let i = tabs.firstIndex(where: { $0.id == active.id }) else {
            // Active tab itself is filtered out (activated via ⌘K/history while the tag
            // filter hides it) — step onto the visible list instead of cycling a ghost.
            if let first = tabs.first { activate(tab: first.id) }
            return
        }
        let n = tabs.count
        activate(tab: tabs[((i + delta) % n + n) % n].id)
    }

    /// ⌘N indexes whatever the sidebar is currently rendering: per-host order in normal
    /// mode, the cross-host pinned-then-MRU list in focus mode. The two @AppStorage keys
    /// live in `SidebarView`; reading UserDefaults directly avoids threading view state
    /// back through the controller for a one-shot key handler.
    /// Mouse back/forward (and the ⌘K palette entries) — browser-style navigation through
    /// the tab visit history. The registry moves its cursor first; `activate` → `setActive`
    /// then sees the cursor already pointing at the target and doesn't re-record, so a
    /// back-step can't truncate its own forward stack.
    func navigateTabHistory(_ delta: Int) {
        guard let target = registry.historyStep(delta) else { return }
        activate(tab: target)
    }

    func gotoTab(index n: Int) {
        let tabs = visibleTabs()
        guard tabs.indices.contains(n - 1) else { return }
        activate(tab: tabs[n - 1].id)
    }

    private func moveActiveTab(by amount: Int) {
        guard amount != 0, let active = registry.activeTab else { return }
        // Focus mode's list is derived (pinned›MRU or host-grouped recency) — there is no
        // stored order to move within; reordering the invisible per-host list from there
        // would shuffle rows the user can't see. No-op, like the sidebar's drag-reorder.
        let d = UserDefaults.standard
        guard !d.bool(forKey: SessionRegistry.kFocusMode) else { return }
        // Filtered siblings: `moveTab` lands after-target moving down / before-target
        // moving up, so targeting the *visible* neighbor hops any hidden tabs between —
        // the reorder you see is the reorder you get.
        let siblings = registry.hostTabs(on: active.hostID,
                                         taggedOnly: d.bool(forKey: SessionRegistry.kFilterTagged))
        guard let i = siblings.firstIndex(where: { $0.id == active.id }) else { return }
        let j = max(0, min(siblings.count - 1, i + amount))
        guard j != i else { return }
        registry.moveTab(active.id, before: siblings[j].id)
    }

    /// Intercept palette tab actions — `Ghostty.App.gotoTab/moveTab` guard on
    /// `tabGroup.windows.count > 1`, which is never true with `tabbingMode = .disallowed`.
    override func performAction(_ action: String, on surfaceView: Ghostty.SurfaceView) {
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        // `split` on an empty/all-separator string yields [], and upstream's action spelling
        // is outside our control — fall through to super rather than trap.
        guard let head = parts.first else { return super.performAction(action, on: surfaceView) }
        switch head {
        case "previous_tab": stepTab(-1)
        case "next_tab": stepTab(1)
        case "last_tab":
            if let last = visibleTabs().last { activate(tab: last.id) }
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
        // With a fork sheet up, the inline rename field would appear (and grab the renaming
        // state) invisibly behind it — and falling through to super would pop upstream's
        // NSAlert on top of our sheet. Swallow.
        guard sheetPanel == nil else { return }
        guard let tab = registry.activeTab else {
            return super.promptTabTitle()
        }
        revealRow(on: tab.hostID)
        registry.setRenaming(.tab(tab.id))
    }

    /// ⌘I — sidebar's persisted per-pane label for the focused pane. Upstream's
    /// `SurfaceView.promptTitle()` writes `surface.title`, which is per-instance and lost
    /// on restart; `paneLabels` (keyed by `ref.key`) survives via fork.json.
    func promptPaneTitle() {
        guard sheetPanel == nil, let tab = registry.activeTab else { return }
        // `tab.tree` lags `surfaceTree` by ≤80ms (debounced persistActive); `focusedPaneIndex`
        // is from the live tree, so a fresh split would index past the stale `leafRefs`.
        let refs = liveRefs(for: tab.id)
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

    /// Refs bound in a tab's live tree, depth-first order. For the active tab this reads
    /// `surfaceTree` (never the ≤80ms-stale `liveTabs` mirror); empty for never-hydrated
    /// tabs. The single accessor behind ⌘I indexing, kill paths, and ref-wide
    /// active-membership checks — five call sites used to hand-roll this map.
    /// (`rollup` lives on the registry now — it reads persisted refs, not live surfaces.)
    private func liveRefs(for tabID: TabModel.ID) -> [SessionRef] {
        surfaces(for: tabID).compactMap { registry.refs[$0.id] }
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
        guard let host = registry.host(id: id) else { return }
        let tabCount = registry.tabs(on: id).count
        // One misclick on a context menu otherwise erases every tab/label/tag for the host
        // and the debounced autosave makes it durable within a second (zmx sessions survive,
        // the sidebar organisation doesn't). Same idiom as `confirmKill`.
        guard let window, tabCount > 0 else { performRemoveHost(id); return }
        let alert = NSAlert()
        alert.messageText = "Remove \(host.label)?"
        alert.informativeText = "Removes \(tabCount) tab\(tabCount == 1 ? "" : "s") from the sidebar. zmx sessions keep running on the host."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        // The Hosts panel is itself a sheet on this window — a second sheet on the same
        // window queues invisibly behind it, so present on whatever is frontmost.
        alert.beginSheetModal(for: window.attachedSheet ?? window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            self?.performRemoveHost(id)
        }
    }

    private func performRemoveHost(_ id: ForkHost.ID) {
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

    /// Refs a Kill on this tab would actually kill, deduped. Live tree first — and for the
    /// *active* tab that's `surfaceTree`, not `liveTabs`, which lags it by the 80ms
    /// `persistActive` debounce (a per-pane Detach followed by ⌘W within that window would
    /// otherwise list — and kill — the session the user just chose to keep). Falls back to
    /// persisted leafRefs for never-hydrated tabs.
    private func killableRefs(for tab: TabModel) -> [SessionRef] {
        let live = liveRefs(for: tab.id)
        return Array(Set(live.isEmpty ? tab.tree.leafRefs : live))
    }

    func confirmKill(_ tab: TabModel) {
        guard let window, let host = registry.host(id: tab.hostID) else { return }
        let refs = killableRefs(for: tab)
        guard !refs.isEmpty else { closeForkTab(tab.id); return }
        let alert = NSAlert()
        alert.messageText = "Kill \(refs.count) zmx session\(refs.count == 1 ? "" : "s")?"
        alert.informativeText = refs.map(\.name).joined(separator: ", ")
        alert.addButton(withTitle: "Kill")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            self?.killSessions(refs, on: host)
            self?.closeForkTab(tab.id)
        }
    }

    /// Is any *other* visible fork window still open? Gates singleton teardown (the CC poll)
    /// on window close — the registry is shared, so "this window is closing" is not the same
    /// as "the fork is done with it".
    static func anyOtherForkWindow(besides w: NSWindow?) -> Bool {
        NSApp.windows.contains {
            $0 !== w && ($0.isVisible || $0.isMiniaturized) && $0.windowController is ForkWindowController
        }
    }

    /// Any fork window the user can actually *see* right now (not occluded, minimized, or
    /// behind a locked screen)? Gates the CC poll cadence — status freshness is pointless
    /// when nothing renders it.
    static var anyVisibleForkWindow: Bool {
        NSApp.windows.contains {
            $0.isVisible && $0.occlusionState.contains(.visible)
                && $0.windowController is ForkWindowController
        }
    }

    /// Fire-and-track kills: a kill that silently didn't run (host briefly unreachable)
    /// leaves the remote session — and any agent inside it — running forever while the tab
    /// is already gone, so failures get a log line instead of vanishing into `try?`.
    /// One verification `list` after the batch: zmx kill of a *wedged* daemon exits 0
    /// without killing — exit status alone can't distinguish "killed" from "daemon ignored
    /// it", only the session's absence from the next list can.
    private func killSessions(_ refs: [SessionRef], on host: ForkHost) {
        Task {
            for ref in refs {
                do { try await ZmxAdapter.kill(host: host, ref: ref) } catch {
                    ForkBootstrap.logger.error(
                        "zmx kill \(stripControl(ref.name, max: 64), privacy: .public) on \(host.label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
            guard let after = await ZmxAdapter.list(host: host) else { return }
            let alive = Set((after.managed + after.external).map { SessionRef(
                hostID: host.id, name: $0.name, external: $0.external).key })
            for ref in refs where alive.contains(ref.key) {
                ForkBootstrap.logger.error(
                    "zmx kill \(stripControl(ref.name, max: 64), privacy: .public) on \(host.label, privacy: .public): session still listed after kill (unresponsive daemon?)")
            }
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
        // The moved pane just landed on screen (dst is the active tab; surfaceTree was
        // swapped above) — ack its unread/blocked state the same way `activate(tab:)`
        // does. Without this a `.waiting`/`.blocked` pane moved into view keeps its stale
        // dot and badge count until the user switches away and back.
        if dst == registry.activeTabID { registry.apply(ref, .viewed) }
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
        showSessionPicker()
    }

    @IBAction override func closeTab(_ sender: Any?) {
        // Same leak-past-the-sheet path as ⌘D (see newSplit): a menu key equivalent walks
        // the responder chain past an open panel — don't close tabs invisibly behind it.
        guard sheetPanel == nil else { return }
        guard let active = registry.activeTabID else { return }
        closeForkTab(active)
    }

    private var sheetPanel: NSWindow?
    private var sheetResignSub: Any?

    /// Two-stage new-session palette. ⌘T / ⌘⇧T / sidebar ＋ open it unlocked (host
    /// filterable, defaults to the active host); the host-row context menu opens it
    /// `locked` so stage 1 is skipped. ⌘D builds its own (locked, split-submit) instance.
    func showSessionPicker(lockedTo host: ForkHost? = nil) {
        let h = host ?? registry.activeHost ?? .local
        let placeholder = registry.uniqueAutoName()
        presentSheet(size: .init(width: 400, height: 300)) { [weak self] in
            NewSessionView(
                host: h, locked: host != nil, placeholder: placeholder,
                onSubmit: { ref, smartJump in
                    self?.newForkTab(intent: .init(
                        hostID: ref.hostID, name: ref.name,
                        // ⇧⏎: the session's shell starts at the zsh-z match for its name.
                        cmd: smartJump ? ZmxAdapter.smartJumpCmd(name: ref.name) : nil,
                        external: ref.external))
                    self?.endSheet()
                },
                onCancel: { self?.endSheet() })
        }
    }

    func showHostsSheet(select: ForkHost.ID? = nil) {
        presentSheet(size: .init(width: 640, height: 560)) { [weak self] in
            HostsView(select: select,
                      onRemove: { id in self?.removeHost(id) },
                      onDone: { self?.endSheet() })
        }
    }

    func showPanePalette() {
        // `ForkPaletteCard` is a self-chromed card (material bg + HandCut stroke + shadow)
        // that fills the panel, so the panel's size IS the palette's size: scale it with
        // the window (~45% wide / ~60% tall, clamped to stay usable on small windows and
        // readable on huge ones). Upstream's `CommandPaletteView` is deliberately not used
        // here — it hard-caps at 500pt wide with a 200pt option table (~4 rows) no matter
        // what frame it's given.
        // Presented as a borderless child window, not a sheet: macOS sheets wrap content
        // in a system `NSVisualEffectView` that `backgroundColor = .clear` can't suppress.
        // The min(…, win - 24) outer clamp keeps the borderless child window inside its
        // parent on tiny windows — a floating overhang past the window edge reads as a
        // detached alien panel (and steals clicks from whatever's behind).
        let win = window?.frame.size ?? .init(width: 1280, height: 800)
        let size = CGSize(width: min(max(560, win.width * 0.45), 880, win.width - 24),
                          height: min(max(420, win.height * 0.60), 980, win.height - 24))
        presentSheet(size: size, bare: true) { [weak self] in
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
        let host = NSHostingController(rootView: ForkThemed { content().environmentObject(registry) })
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
        // `panes` lives on the singleton and `ForkNotify.badgeSub` outlives this
        // controller; `.detached` (via `stopObservingProgress`) resets phase so the dock
        // badge doesn't stick.
        for id in Array(progressSubs.keys) { stopObservingProgress(id) }
        endSheet()  // drops sheetResignSub; child-window auto-close doesn't guarantee resign-key fires first
        // Focus is leaving the window for good — record the focused pane's departure now,
        // so a reopen hours later can't back-date it to "just now" via the exit-stamp.
        // Must run BEFORE the probe stop below: the read-stamp half reads `ccLive`, which
        // `setCCProbeEnabled(false)` wipes.
        registry.flushPaneExit()
        // The sidebar's `.onDisappear` usually stops the cc poll + ⌥ monitor, but that path
        // depends on upstream nilling `contentView` during close (a line upstream has marked
        // as removable). Stop the poll here too — idempotent, and the sidebar re-enables it
        // on its next appear — so a closed window can't leave a 3s ps/ssh probe running.
        // Only when this is the *last* fork window: the registry is a singleton, and killing
        // the probe under a surviving window's sidebar would silently freeze its CC status
        // (its showCC toggle still reads "on" and nothing re-enables until it's flipped).
        if !Self.anyOtherForkWindow(besides: window) { registry.setCCProbeEnabled(false) }
        // The fork's two selector observers: without this a parked pane's pty exit after
        // close still builds a placeholder surface — a fresh `zmx attach` pty — for a window
        // that no longer exists. Scoped (not a blanket removeObserver(self)) so upstream's
        // own observers stay intact for whatever super/dealloc still needs.
        NotificationCenter.default.removeObserver(self, name: Ghostty.Notification.ghosttyCloseSurface, object: nil)
        NotificationCenter.default.removeObserver(self, name: .ghosttyBellDidRing, object: nil)
        super.windowWillClose(notification)
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        guard let window, let terminalContent = window.contentView else { return }

        window.tabbingMode = .disallowed
        window.isRestorable = false

        // Upstream's `BaseTerminalController.terminalViewContainer` is
        // `window?.contentView as? TerminalViewContainer`, and `SurfaceRepresentable`
        // re-creates its `SurfaceScrollView` wrapper whenever the split-tree's
        // `.id(structuralIdentity)` changes — both assume the container is
        // contentView. Reparenting it into an NSSplitView broke split rendering.
        // Instead: keep `terminalContent` as `window.contentView`, add the sidebar
        // as a sibling subview of the container, and re-pin the container's inner
        // hosting view to start after the sidebar.
        let sidebar = NSHostingView(rootView: ForkThemed { SidebarView(controller: self).environmentObject(registry) })
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        terminalContent.addSubview(sidebar)
        sidebarHost = sidebar
        sidebarWidthConstraint = sidebar.widthAnchor.constraint(equalToConstant: sidebarWidth)
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
        // Skip the Liquid Glass background view explicitly: today it's created lazily
        // (after this runs), so "first non-sidebar subview" happens to be the hosting
        // view — but the moment upstream makes glass creation synchronous, this would
        // re-pin the *glass* and leave the terminal full-width under the sidebar.
        let glass = (terminalContent as? TerminalViewContainer)?.glassEffectView
        if let hosting = terminalContent.subviews.first(where: { $0 !== sidebar && $0 !== glass }) {
            terminalContent.constraints
                .filter { ($0.firstItem === hosting && $0.firstAttribute == .leading)
                       || ($0.secondItem === hosting && $0.secondAttribute == .leading) }
                .forEach { $0.isActive = false }
            terminalLeadingConstraint = hosting.leadingAnchor.constraint(
                equalTo: terminalContent.leadingAnchor, constant: sidebarWidth)
            terminalLeadingConstraint!.isActive = true
        }

        let cheatsheet = NSHostingView(rootView: ForkThemed { CheatsheetView(hoverCommands: registry.hoverCommands) })
        cheatsheet.translatesAutoresizingMaskIntoConstraints = false
        cheatsheet.isHidden = true
        terminalContent.addSubview(cheatsheet)
        cheatsheetHost = cheatsheet
        cheatsheetCenterX = cheatsheet.centerXAnchor.constraint(
            equalTo: terminalContent.centerXAnchor, constant: sidebarWidth / 2)
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

        // Sidebar resize handle — an invisible strip on the sidebar/terminal boundary;
        // drag to widen the sidebar (floor = the classic 248pt). AppKit, not a SwiftUI
        // gesture: the strip must span the NSHostingView/terminal seam, and constraint
        // edits must not route through SwiftUI re-renders (see the leading-constraint
        // comment above). Added last so it sits above both views — which also means it
        // *steals* clicks from what it covers: biased 2pt-sidebar/5pt-terminal because
        // the sidebar edge has clickable chrome (rows, StatusRail, overlay scroller)
        // while the terminal's first half-column is only text selection.
        let handle = SidebarResizeHandle()
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.startWidth = { [weak self] in
            self?.sidebarWidthConstraint?.constant ?? Self.sidebarMinWidth
        }
        handle.onDrag = { [weak self] w in self?.setSidebarWidth(w, commit: false) }
        handle.onCommit = { [weak self] w in self?.setSidebarWidth(w, commit: true) }
        terminalContent.addSubview(handle)
        NSLayoutConstraint.activate([
            handle.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -2),
            handle.widthAnchor.constraint(equalToConstant: 7),
            handle.topAnchor.constraint(equalTo: terminalContent.topAnchor),
            handle.bottomAnchor.constraint(equalTo: terminalContent.bottomAnchor),
        ])
        sidebarHandle = handle

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
        } else if registry.tabHistory.isEmpty {
            // Relaunch path: the disk-restored active tab IS `current`, so the setActive
            // above never runs — seed the visit history with it, or the first back press
            // after every launch is a dead no-op (the tab the user "came from" wouldn't
            // exist as an anchor).
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
        for ref in leaves.lazy.compactMap({ self.registry.refs[$0.id] }) {
            registry.apply(ref, .viewed)
        }
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
            stopObservingProgress(surface.id)
            registry.unbind(surface: surface.id)
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
        // External names bypass charset validation; seeding `uniqueAutoName` with one would
        // mint a *managed* ref that fails `isValid` → scrubbed + orphaned on restart (same
        // guard as `runPaneCommand`).
        let seed = registry.refs[oldView.id].flatMap { $0.isValid ? $0.name : nil }
        let placeholder = registry.uniqueAutoName(derivedFrom: seed)
        pendingSplit = (oldView, direction)
        presentSheet(size: .init(width: 400, height: 300)) { [weak self] in
            NewSessionView(
                title: "Split on \(host.label)",
                host: host, locked: true, placeholder: placeholder,
                onSubmit: { ref, smartJump in
                    guard let self, let p = self.pendingSplit else { return }
                    self.pendingSplit = nil
                    _ = self.completeSplit(
                        at: p.at, direction: p.dir, host: host, ref: ref,
                        initialCmd: smartJump ? ZmxAdapter.smartJumpCmd(name: ref.name) : nil)
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

/// Invisible vertical strip on the sidebar's trailing edge — drag to resize the sidebar.
/// Plain NSResponder mouse tracking (no NSGestureRecognizer): the drag must keep working
/// when the cursor leaves the strip mid-drag, which mouseDragged gives for free
/// (events keep routing to the mouseDown view until mouseUp).
private final class SidebarResizeHandle: NSView {
    /// Reads the constraint's current constant at drag start (not a cached width — the
    /// user may have toggled the sidebar or resized since the handle was created).
    var startWidth: () -> CGFloat = { 0 }
    var onDrag: ((CGFloat) -> Void)?
    var onCommit: ((CGFloat) -> Void)?
    private var anchorX: CGFloat = 0
    private var baseWidth: CGFloat = 0
    private var cursorPushed = false

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        anchorX = event.locationInWindow.x
        baseWidth = startWidth()
        // Pin the cursor for the whole drag — the pointer leaves the strip immediately
        // and would otherwise flip back to an arrow/I-beam over the terminal.
        NSCursor.resizeLeftRight.push()
        cursorPushed = true
    }

    override func mouseDragged(with event: NSEvent) {
        // ⌘⇧B mid-drag hides the handle while the drag session keeps routing events here;
        // writing widths into the collapse animation would re-expand a hiding sidebar.
        guard !isHiddenOrHasHiddenAncestor else { return }
        onDrag?(baseWidth + (event.locationInWindow.x - anchorX))
    }

    override func mouseUp(with event: NSEvent) {
        popCursorIfNeeded()
        guard !isHiddenOrHasHiddenAncestor else { return }
        onCommit?(baseWidth + (event.locationInWindow.x - anchorX))
    }

    /// The window can close mid-drag (mouseUp never arrives) — a leaked push leaves the
    /// ⇔ cursor stuck app-wide.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { popCursorIfNeeded() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func popCursorIfNeeded() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }
}
#endif
