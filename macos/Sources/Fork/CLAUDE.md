# Ghostty zmx Fork

Left sidebar with host-grouped tabs; every tab/split is a `zmx` session (local or ssh).
See `do_not_commit/ghostty-fork/SPEC.md` for the full spec.

## Principles

1. **Upstream-rebaseable.** The diff against `ghostty-org/ghostty` is exactly two
   `// [fork]` seam lines plus `Fork/**`. `jj rebase -b fork -d main@upstream` must
   stay mechanical — see [seam policy](#upstream-seam-policy).
2. **zmx-native.** Every pane is `zmx attach <session>`; there is no non-zmx mode.
   Tabs, splits, remote hosts, and crash-survival all reduce to session names.
3. **Additive, not parallel.** Subclass + side-registry. Never reimplement what
   `TerminalController` already does — the
   [one architectural rule](#the-one-architectural-rule) is the load-bearing case.

## Build & test

```sh
# zig 0.15.2 can't link the macOS 26.4 SDK (ziglang/zig#31658).
# scripts/shims/xcrun redirects its SDK probe to 15.4. Remove once a fixed zig ships.
# -Demit-xcframework: upstream's libghostty-vt split made the xcframework non-default.
PATH=$(pwd)/scripts/shims:$PATH zig build -Demit-xcframework -Demit-macos-app=false

# Run the fork (debug builds are opt-in; ReleaseLocal via fork-release.sh defaults on)
GHOSTTY_FORK=1 open macos/build/Debug/Ghostty.app

# Tests (Swift Testing, auto-picked-up via PBXFileSystemSynchronizedRootGroup)
cd macos && xcodebuild test -scheme Ghostty -destination 'platform=macOS' \
  -only-testing:GhosttyTests/TransportTests

# Seam + symbol invariants — run after every rebase
./scripts/fork-check.sh

# One-time: self-signed identity so TCC grants survive rebuilds (ad-hoc → new CDHash → re-prompt)
./scripts/fork-make-cert.sh
```

Release build & push: see [Branches & release](#branches--release).
macOS privacy prompts (TCC, container access, FDA): see [Signing & TCC](#signing--tcc).

## The one architectural rule

> **The split tree's leaf type stays `Ghostty.SurfaceView`. Session metadata lives in
> `SessionRegistry`, keyed by `SurfaceView.id`.**

`ForkWindowController` subclasses `TerminalController` and inherits `surfaceTree`,
`TerminalSplitTreeView`, split IBActions, focus nav, zoom, close-confirm. The fork adds a
sidebar and a registry; it does not reimplement splits.

## Upstream seam policy

Exactly **two** `// [fork]` lines outside `Fork/`:

| File | Seam |
|---|---|
| `macos/Sources/App/macOS/AppDelegate.swift` | `ForkBootstrap.install(ghostty:)` |
| `macos/Sources/Features/Terminal/TerminalController.swift` | `if let c = ForkBootstrap.intercept(...) { return c }` |

`fork-check.sh` enforces this. New behavior goes in `Fork/` via subclassing/overrides — never
by editing upstream. If a hook genuinely doesn't exist, add a third seam *and bump the count
in fork-check.sh in the same commit*.

## Layout

```
Fork/
  ForkBootstrap.swift          enabled flag (env GHOSTTY_FORK=1), seam entry points
  Notify.swift                 UN delegate proxy (wraps AppDelegate's); userInfo["forkTab"]
                               → foreground banner + click→activate(tab:); dock badge =
                               .waiting count
  Model/
    Host.swift                 ForkHost, Transport, SSHTarget, SessionRef, TabModel, PersistedTree
    SessionRegistry.swift      @MainActor singleton; @Published hosts/tabs/activeTabID/focusedPaneIndex (refs is plain var)
    Persistence.swift          fork.json (atomic write + .bak + revalidate-on-load)
  Zmx/
    ShellQuote.swift           shq() — POSIX single-quote
    ZmxAdapter.swift           surfaceConfig/list/kill/detachedScript; Transport.wrap/controlArgv
    CCProbe.swift              zmx pid → ~/.claude/sessions/<pid>.json via ps-tree BFS;
                               keyed by SessionRef.key; nil-on-failure so poll keeps last-known
  UI/
    ForkWindowController.swift the controller; tab switching = swap surfaceTree
    SidebarView.swift          host sections (drag-reorder); per-pane rows show paneLabel ›
                               surface.title › ref.name; optional tab-title heading + collapse
                               chevron; ⌘I/⌘⇧I → inline rename; tag pills; compact toggle
                               (@AppStorage) hides age + subtitle; focus mode prefixes each tab
                               with its host's SF-Symbol badge
    TagEditView.swift          right-click "Tag…" popover (text + 8 hue swatches)
    NewSessionView.swift       ⌘T sheet
    SplitPickerView.swift      ⌘D picker (new vs attach-existing)
    SessionMetaLabel.swift     shared row trailer: client-count + age
    NewHostView.swift          add-host sheet
    HostDetailView.swift       manage-host sheet (rename, accent hue, SF-Symbol icon, remove)
    CheatsheetView.swift       hold-⌘ shortcut overlay (600ms debounce; flagsChanged monitor)
    ForkSheetPanel.swift       NSWindow.performKeyEquivalent → ⌘V/C/X/A/Z to firstResponder
```

## Gotchas (each cost ≥1 verifier round)

- **`windowDidLoad` fires *inside* `super.init`**: `BaseTerminalController.init` assigns
  `surfaceTree` → `didSet` → `surfaceTreeDidChange` reads `self.window` → nib lazy-loads.
  Do registry seeding in `newWindow()` after init returns, never in `windowDidLoad`.
- **`@Published.sink` without a scheduler fires synchronously** inside the property setter.
  `$surfaceTree` uses `.debounce(80ms, .main)` — async delivery so `bind()` completes before
  `persistActive` projects, *and* divider-drag (per-frame `splitDidResize`) doesn't storm
  the sidebar.
- **Split-prompt redraw** (resolved, zmx-side): old pane's prompt vanished after
  ⌘D because zig stdlib's `posix.poll` auto-retries on EINTR — zmx's SIGWINCH
  handler set its flag but the client loop never woke to check it. Fixed in zmx
  via self-pipe. None of the Swift-side ordering mattered; the prior "fixes"
  here (split-before-endSheet, `refs` un-@Published) were timing coincidences.
  Debug toggles: `GHOSTTY_FORK_NO_SIDEBAR`, `GHOSTTY_FORK_NO_PICKER`,
  `GHOSTTY_FORK_NO_ZMX`. `GHOSTTY_FORK_ZMX=/path` overrides zmx resolution.
- **Sheet ⌘V**: nil-targeted menu actions walk *past* the sheet to
  `mainWindow.firstResponder` (the `SurfaceView`, which has its own `paste:`).
  `ForkSheetPanel.performKeyEquivalent` intercepts before the menu.
- **`activeTabID` is controller-owned**: registry's `newTab`/`removeTab` mutate the list,
  never the cursor. Only `ForkWindowController.activate(tab:)` calls `setActive`.
- **Undo is window-scoped, tabs aren't**: `BaseTerminalController.replaceSurfaceTree`
  registers `{ target.surfaceTree = oldTree }` with `withTarget: self`. The closure
  captures a *tree*, not a tab id, so ⌘Z after a sidebar tab switch would write the
  previous tab's tree under the new `activeTabID` (then `persistActive` makes it
  permanent). `activate(tab:)` clears `undoManager.removeAllActions(withTarget: self)`
  on switch — same idiom upstream uses at `BaseTerminalController.swift:226`.
- **iOS target shares `Sources/`** via the synchronized group. Every file under `Fork/` must
  be wrapped in `#if os(macOS) … #endif`.
- **`SessionRef.name` is not unique within a tab**: `ZmxAdapter` strips the `{tabID}-` prefix
  on list parse, so a tab-owned `acr` and an external-attached `acr` collide. Per-tab dicts
  (`paneLabels`/`paneTags`/`lastActive`) key on `SessionRef.key` (`@`-prefix for external).
- **Three pane-title layers**: `paneLabels[ref.key]` (fork-persisted, ⌘I) › `surface.title`
  (OSC-driven, per-`SurfaceView`-instance, lost on restart) › `ref.name` (zmx session id).
  Upstream's `titleFallbackTimer` writes `"👻"` 500ms after surface init — `PaneLabel` treats
  it as no-title. `zmx attach` replays buffer but not OSC, so `surface.title` stays empty
  until the next prompt.
- **Codable defaults aren't optional**: adding a non-Optional field with a default to a
  persisted type breaks decode of old `fork.json`. Use `decodeIfPresent` in a custom
  `init(from:)`.

## Security boundary

`Transport.wrap` / `controlArgv` are the **only** places strings meet a shell. `SSHTarget`
and `SessionRef.name` are validated against `^[A-Za-z0-9._-]+$`; `shq` single-quotes argv.
For ssh, the remote command is double-quoted (`shq(shq(argv))`). Don't build shell strings
anywhere else.

## Branches & release

Remotes: `upstream` = `ghostty-org/ghostty`, `origin` = `chronologos/ghostty`.
`main` mirrors upstream; the fork stack lives on bookmark `fork`.

```sh
# Pull upstream and rebase the stack
jj git fetch --remote upstream
jj rebase -b fork -d main@upstream
./scripts/fork-check.sh                       # seam count + upstream symbols

# Push (after squashing into the PR commits)
jj bookmark set fork -r @-
jj git push --bookmark fork --remote origin   # never push to upstream

# Optimized build → macos/build/ReleaseLocal/Ghostty.app
# Re-signed with `ghostty-fork-dev` (or $FORK_SIGN_IDENTITY) so TCC grants persist.
./scripts/fork-release.sh
```

## Backlog

- 3rd seam for `keybind = all:cmd+t=new_tab` config edge — leaks through
  `AppDelegate.ghosttyNewTab` since `ForkWindowController is TerminalController`.
- Host rename in sidebar context menu (registry method exists, no UI).
- `detachedPlaceholders` pruning.
- `macos-titlebar-style = tabs` config — `tabbingMode = .disallowed` should suppress
  the native tab bar but untested with our sidebar.
- Scripted splits (`NewTerminalIntent.swift:133`, `ScriptTerminal.swift:105`) hit our
  `newSplit` override → picker pops + script gets nil. Bypass needed if Shortcuts/
  AppleScript matters.
- **Detached-pane list-probe** (SPEC §5) — `detachedScript` reattaches blindly; should
  `zmx list` first and show "session ended — start fresh?" if absent.
- ssh attach to a re-keyed host behind a ProxyCommand dies opaque (`UNKNOWN port 65535`)
  at the host-key prompt — consider `-o StrictHostKeyChecking=accept-new` or a clearer
  error surface in `ZmxAdapter.swift:175`.
- "Kill Session…" missing from the heading context menu.
- `ReorderDelegate` accepts external `.text` drops: cancelled internal drag leaves
  `dragging` stale (no SwiftUI cancel hook), then dragging text from another app
  onto a row fires a spurious `moveTab`/`moveHost`. Fix needs a private UTType so
  external drags don't match `.onDrop(of:)`.

## Signing & TCC

A terminal that runs arbitrary shells will trip every macOS privacy surface. Three layers:

| Prompt | Why | Fix |
|---|---|---|
| Files / Photos / Desktop etc., **re-asks after every build** | Ad-hoc signature → new CDHash per compile → TCC's `csreq` (`cdhash H"…"`) never matches again | `scripts/fork-make-cert.sh` once, then always run via `scripts/fork-release.sh`. The re-sign step makes the DR `certificate leaf = H"<cert-sha1>"` — stable across rebuilds. Debug builds stay ad-hoc; don't daily-drive them. |
| **"wants to access data from other apps"** with no always-allow | Per-container data protection (macOS 15+). Fires on any `stat()` into `~/Library/{Group ,}Containers/<app>/` — `ls`, `fd`, shell-history/dir-jump tools, prompt git checks. Each target container is a separate session-scoped grant by design. | Grant **Full Disk Access** to the ReleaseLocal app (Privacy & Security → Full Disk Access → `+`). FDA is a superset; suppresses this and the row above. Keyed on the DR, so it survives rebuilds *only because of* the self-signed cert. |
| Gatekeeper "unidentified developer" on first launch | Self-signed isn't notarized | Right-click → Open once, or `xattr -dr com.apple.quarantine <app>`. |
| **SIGKILL "Launch Constraint Violation"** intermittently after rebuild | A nested component (Sparkle's XPCs/Updater.app) wasn't fully re-signed — typically held open by the still-running instance — so the outer seal covers ad-hoc inner code. Shallow `codesign --verify` passes; AMFI's launch-time check is deep. | `fork-release.sh` now `rm -rf`s the bundle pre-build and runs `--verify --deep` post-sign so this fails the script instead of the launch. |

`FORK_SIGN_IDENTITY="Apple Development: …"` overrides the cert if you'd rather use a real Team ID.

## Known limitations

- First cold launch may freeze ≤2s if `zmx` isn't in env/PATH or the hardcoded dir
  list (ZmxAdapter.swift:15). `static let` is swift_once-serialized, so the login-shell
  probe can't be moved off main; it's forced eagerly in `install()` so the stall lands
  before the first window draws. Set `GHOSTTY_FORK_ZMX=/abs/path` to skip the probe.
- `refs` is never pruned (see undo gotcha) — closed-split entries leak until quit;
  `isConnected()` may stay green slightly stale. In-memory only, not persisted.

- `returnToDefaultSize` reads `NSSplitView.intrinsicContentSize` in fork mode.
- `SessionRegistry.shared` stored-prop init will fail compile under Swift 6 strict concurrency.
- Command field in NewSessionView splits naively on spaces.
- ⌘⇧[/⌘⇧] tab nav matches `{`/`}` (US-layout); other layouts won't fire.
  Digit shortcuts (⌘1-9, ⌘⌥1-9) are layout-independent via `keyCode`.
  ⌘[/⌘] left to upstream's `goto_split` (Config.zig:7016).
  ⌘⌥A watch matches physical `kVK_ANSI_A` (keyCode 0); AZERTY gets it on ⌘⌥Q.
  Bare-letter hover shortcuts (k/r/c/t/p) fire whenever the mouse is on a sidebar
  row — including while the terminal is firstResponder — so a stray letter while
  the cursor rests on a row will intercept; mitigated by `k` being confirm-gated
  and the rest being reversible.
  ⌘K/⌘⇧K shadow upstream's `clear_screen` (Config.zig:6927); rebind via
  `keybind = cmd+ctrl+k=clear_screen` if wanted.
  Hold-⌘ ≥600ms shows `CheatsheetView`; the debounce hides quick chords but
  ⌘-hold for autorepeat (e.g. ⌘← in a TUI) will pop it after 600ms.
- CC probe (sparkle toggle) reads `~/.claude/sessions/` — a zshrc-only
  `CLAUDE_CONFIG_DIR` override is invisible to the Dock-launched app and to
  `ssh -o BatchMode=yes` (non-login shell). Remote probe assumes POSIX
  `ps -A -o pid=,ppid=`; BusyBox/Alpine untested. Shared-uid remotes
  (`deploy@`) ship every user's CC pid-files over the wire — BFS filters the
  *result* to descendants of our zmx sessions, but the raw transfer doesn't.
- Sidebar mono font reads `window-title-font-family` (not `font-family` — that's a
  `RepeatableString` and `c_get.zig` can't return it without an upstream `cval()`).
  Set `window-title-font-family = <terminal font>` for matched typography.
- ⌘⇧K scrollback search fetches full `zmx history` per session and matches
  client-side (keeps user input out of `controlArgv`'s shell). Slow over ssh
  for large buffers; per-ref 10s timeout means a stalled remote silently drops.
