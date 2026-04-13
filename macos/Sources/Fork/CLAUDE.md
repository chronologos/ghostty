# Ghostty zmx Fork

Left sidebar with host-grouped tabs; every tab/split is a `zmx` session (local or ssh).
See `do_not_commit/ghostty-fork/SPEC.md` for the full spec.

## Build & test

```sh
# zig 0.15.2 can't link the macOS 26.4 SDK (ziglang/zig#31658).
# scripts/shims/xcrun redirects its SDK probe to 15.4. Remove once a fixed zig ships.
PATH=$(pwd)/scripts/shims:$PATH zig build

# Run the fork
GHOSTTY_FORK=1 open macos/build/Debug/Ghostty.app

# Tests (Swift Testing, auto-picked-up via PBXFileSystemSynchronizedRootGroup)
cd macos && xcodebuild test -scheme Ghostty -destination 'platform=macOS' \
  -only-testing:GhosttyTests/TransportTests

# Seam + symbol invariants — run after every rebase
./scripts/fork-check.sh
```

Release build & push: see [Branches & release](#branches--release).

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
  Model/
    Host.swift                 ForkHost, Transport, SSHTarget, SessionRef, TabModel, PersistedTree
    SessionRegistry.swift      @MainActor singleton; @Published hosts/tabs/activeTabID (refs is plain var)
    Persistence.swift          fork.json (atomic write + .bak + revalidate-on-load)
  Zmx/
    ShellQuote.swift           shq() — POSIX single-quote
    ZmxAdapter.swift           surfaceConfig/list/kill/detachedScript; Transport.wrap/controlArgv
  UI/
    ForkWindowController.swift the controller; tab switching = swap surfaceTree
    SidebarView.swift          SwiftUI; host sections, tab rows, context menus
    MinimapView.swift          read-only PersistedTree visualizer under active tab
    NewSessionView.swift       ⌘T sheet
    SplitPickerView.swift      ⌘D picker (new vs attach-existing)
    NewHostView.swift          add-host sheet
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
  `GHOSTTY_FORK_NO_ZMX`.
- **Sheet ⌘V**: nil-targeted menu actions walk *past* the sheet to
  `mainWindow.firstResponder` (the `SurfaceView`, which has its own `paste:`).
  `ForkSheetPanel.performKeyEquivalent` intercepts before the menu.
- **`activeTabID` is controller-owned**: registry's `newTab`/`removeTab` mutate the list,
  never the cursor. Only `ForkWindowController.activate(tab:)` calls `setActive`.
- **iOS target shares `Sources/`** via the synchronized group. Every file under `Fork/` must
  be wrapped in `#if os(macOS) … #endif`.
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

# Optimized build → macos/build/ReleaseLocal/Ghostty.app (ad-hoc signed)
./scripts/fork-release.sh
```

## Backlog

- **zmx absolute path**: `ZmxAdapter` uses bare `zmx`, which works under `open -n`
  (inherits shell PATH) but not Finder/Spotlight/Dock launch (launchd PATH only).
  Resolve once at startup; fall back to a config key.
- **⌘K command palette** (SPEC §8) — fork-hosted `CommandPaletteView` listing
  sessions/hosts/actions. Reuse upstream's `CommandPaletteView(options:)`.
- 3rd seam for `keybind = all:cmd+t=new_tab` config edge — leaks through
  `AppDelegate.ghosttyNewTab` since `ForkWindowController is TerminalController`.
- Host rename in sidebar context menu (registry method exists, no UI).
- `navMonitor` cleanup on dealloc; `detachedPlaceholders` pruning.
- `macos-titlebar-style = tabs` config — `tabbingMode = .disallowed` should suppress
  the native tab bar but untested with our sidebar.
- Scripted splits (`NewTerminalIntent.swift:133`, `ScriptTerminal.swift:105`) hit our
  `newSplit` override → picker pops + script gets nil. Bypass needed if Shortcuts/
  AppleScript matters.
- **Minimap focus highlight + click-to-focus** — needs `[Bool]` tree-path addressing
  (`SessionRef` is non-unique per leaf via `completeSplit` attach-existing).
- **Detached-pane list-probe** (SPEC §5) — `detachedScript` reattaches blindly; should
  `zmx list` first and show "session ended — start fresh?" if absent.

## Known limitations

- `refs` is never pruned (see undo gotcha) — closed-split entries leak until quit;
  `isConnected()` may stay green slightly stale. In-memory only, not persisted.

- `returnToDefaultSize` reads `NSSplitView.intrinsicContentSize` in fork mode.
- `SessionRegistry.shared` stored-prop init will fail compile under Swift 6 strict concurrency.
- Command field in NewSessionView splits naively on spaces.
- ⌘⇧[/⌘⇧] tab nav matches `{`/`}` (US-layout); other layouts won't fire.
  Digit shortcuts (⌘1-9, ⌘⌥1-9) are layout-independent via `keyCode`.
  ⌘[/⌘] left to upstream's `goto_split` (Config.zig:7016).
