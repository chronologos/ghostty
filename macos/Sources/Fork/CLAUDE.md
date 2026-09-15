# Ghostty zmx Fork

Left sidebar with host-grouped tabs; every tab/split is a `zmx` session (local or ssh).
Design notes live in `do_not_commit/ghostty-fork/` (gitignored: `backlog.md`,
`PaneMachine-plan.md`; the original SPEC.md is gone — code comments still cite its
section numbers as historical anchors).

## Principles

1. **Upstream-rebaseable.** The diff against `ghostty-org/ghostty` is exactly three
   `// [fork]` seam lines plus `Fork/**`. `jj rebase -b fork -d main@upstream` must
   stay mechanical — see [seam policy](#upstream-seam-policy).
2. **zmx-native.** Every pane is `zmx attach <session>`; there is no non-zmx mode.
   Tabs, splits, remote hosts, and crash-survival all reduce to session names.
3. **Additive, not parallel.** Subclass + side-registry. Never reimplement what
   `TerminalController` already does — the
   [one architectural rule](#the-one-architectural-rule) is the load-bearing case.

## Build & test

```sh
# Upstream requires Zig 0.16 (build.zig.zon `minimum_zig_version`) while system `zig`
# stays 0.15.2 (zmx builds on it); scripts/shims/zig picks per-project from the nearest
# build.zig.zon's declared minimum → `zig-0.16` here — a real shim, not an alias, because
# upstream's `translate_c` dependency discovers the lib dir via `zig env` on PATH.
# (0.16 no longer needs scripts/shims/xcrun — ziglang/zig#31658 is fixed — but the
# 0.15.2 consumers of this shims dir, e.g. ~/bin/zmx-deploy, still do; leave it.)
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

Exactly **three** `// [fork]` lines outside `Fork/`:

| File | Seam |
|---|---|
| `macos/Sources/App/main.swift` | `ForkBootstrap.prepareEnvironment()` — *before* `ghostty_init`, which snapshots `environ` (see the env gotcha below) |
| `macos/Sources/App/AppDelegate.swift` | `ForkBootstrap.install(ghostty:)` — in `applicationWillFinishLaunching` (near-frozen upstream; don't move it back into the churn-heavy `applicationDidFinishLaunching`) |
| `macos/Sources/Features/Terminal/TerminalController.swift` | `if let c = ForkBootstrap.intercept(...) { return c }` |

`fork-check.sh` enforces this. New behavior goes in `Fork/` via subclassing/overrides — never
by editing upstream. If a hook genuinely doesn't exist, add another seam *and bump the count
in fork-check.sh in the same commit*.

## Layout

```
Fork/
  ForkBootstrap.swift          enabled flag (env GHOSTTY_FORK=1), seam entry points;
                               `prepareEnvironment` (pre-`ghostty_init`, the only place the
                               process env is ever mutated) exports the cached login-shell
                               PATH (GUI launches get launchd's bare PATH, which breaks
                               ssh ProxyCommand wrappers resolved by name; `install`
                               refreshes the cache in the background) and scrubs the zmx
                               env vars that would change what our own commands mean
                               (`ZMX_SESSION`, `ZMX_SESSION_PREFIX`) and sets
                               `ZMX_NO_DETACH_KEY`
  Notify.swift                 UN delegate proxy (wraps AppDelegate's); userInfo["forkTab"]
                               → foreground banner + click→activate(tab:); dock badge =
                               count of (finished-unread OR blocked) && !ccBusy panes
  SurfaceWiggle.swift          forkWigglePane — ⌘⇧R force-repaint via synthetic SIGWINCH;
                               also injects a Space+Backspace nudge when (and only when)
                               the CC probe sees a session in that pane
  Model/
    Host.swift                 ForkHost, Transport, SSHTarget, SessionRef, TabModel,
                               PersistedTree, PaneTag, HoverCommand, isValidIdent/
                               isSafeExternalName
    AliasSync.swift            Per-SessionRef alias reducer — cache ⇄ daemon `ghostty_name`
                               label (capability earned by a seen label or an Ack'd write,
                               pending-write mask, migration/seed, two-strike clear
                               propagation, stamp-matched retries); pure, unit-tested
    PaneMachine.swift          Per-SessionRef status reducer — event-ordered `.progress`/
                               `.settled`/`.probe`/`.probeAbsent`/`.probeStopped`/`.viewed`/
                               `.watch`/`.bell(isActive:)`/`.detached` → `.dot` projection
                               + post-banner bool
    SessionRegistry.swift      @MainActor singleton; @Published hosts/tabs/activeTabID/
                               focusedPaneIndex/renaming/recentTags/panes/ccLive (refs is a
                               plain var); focusTabs/hostTabs (the ⌘1-9 contract), rollup,
                               applyProbeResult (mergeCC body), uniqueAutoName, tab visit
                               history (setActive records; historyStep walks — mouse ⏴/⏵)
    Persistence.swift          fork.json (atomic write + .bak + preserve-aside + revalidate-on-load)
  Zmx/
    ShellQuote.swift           shq() — POSIX single-quote; stripControl()
    AliasCodec.swift           pane alias ⇄ zmx `ghostty_name` label value (`_HH` escape into
                               `[A-Za-z0-9._-]`, lenient decode) + display sanitize
    ZmxAdapter.swift           surfaceConfig/list(Result)/partition/kill/history/
                               detachedScript/restoreCmd/expand/run/setAlias;
                               Transport.wrap/controlArgv; `ListEntry` (alias, daemon cwd,
                               cmd, task end/exit) + `ListResult.unresponsive` (daemons that
                               didn't answer — present, not gone); `ListFailure` (why a list
                               failed), `KillOutcome`, `SetResult`
    CCProbe.swift              zmx pid → ~/.claude/sessions/<pid>.json. Local host: native
                               Swift (sysctl process table + FileManager); ssh hosts: sh
                               probe script. Keyed by SessionRef.key; nil-on-failure so the
                               poll keeps last-known. Also `rename` (CC name sync over the
                               session's control UDS)
  UI/
    ForkWindowController.swift the controller; tab switching = swap surfaceTree; sheet
                               presentation; ⌘W Detach/Kill routing; kill verification;
                               sidebar width = drag the right edge (248pt floor, persisted
                               via UserDefaults ForkSidebarWidth; ⌘⇧B hide/show restores it)
    SidebarView.swift          host sections (drag-reorder); per-pane rows show paneLabel ›
                               surface.title › ref.name; optional tab-title heading + collapse
                               chevron; ⌘I/⌘⇧I → inline rename; tag pills; single density (no
                               compact toggle): unread CC status text is bright + up to 3
                               lines, read text (exit-stamped ccSeenDetail) demotes to one
                               tertiary line; solo ⌥-hold ≥0.5s reveals all (and pops the
                               cheatsheet — one peek, one threshold), ⌥⌥ marks all
                               read; recency = afterglow wash (<15m) + doze opacity (>1h /
                               past focus cutoff; never on unread/blocked rows) + the peek
                               ledger's age line; resting the cursor on a row ≥ Theme.peekDelay
                               exhales it open into the PanePeek ledger (state+age / DIR / ZMX
                               lines + un-clamped status text — replaced the row tooltip);
                               focus mode wraps each tab
                               in a ForkCard with a ⌘N + HostDot + host-label caption row
    OptionGesture.swift        OptionGestureRecognizer — the *only* ⌥-hold / ⌥⌥ recognizer
                               (extracted ViewModifier; SidebarView binds revealAll/onPeek/
                               onSweep). Solo-⌥ 0.5s peek drives the sidebar reveal and the
                               cheatsheet as a unit via `setPeek`
    ForkTheme.swift            ForkTokens (terminal `foreground`/`background` → text +
                               chrome; ANSI `palette` → the host-dot/tab-accent ramp, by
                               nearest hue so a slot keeps its color, or the wheel if the
                               theme can't make a legible one) + the `\.forkTokens` env key
                               + ForkThemed, the one
                               place ForkTheme is observed. `resolve` declines a theme when
                               Increase Contrast is on or the bg's polarity fights the
                               window appearance the material is drawn from
    Theme.swift                theme-*independent* tokens (clay/blocked/error/…), peek
                               tokens (peekRule/peekDelay/exhale/settle), Pebble, HandCut,
                               ForkCard
    TagEditView.swift          tag popover (text + 8 hue swatches); opened from the pane
                               context menu's Tag submenu ("New Tag…")
    NewSessionView.swift       two-stage new-session palette (⌘T / ⌘⇧T / sidebar ＋ /
                               host context-menu / ⌘D split): type-filter host → ⏎/Tab →
                               name (or ↓ to pick existing). ⏎ create/attach;
                               ⇧⏎ smart-jump create (shell starts at the zsh-z frecency
                               match for the typed name, resolved on the session's host);
                               ⌫ on empty name steps back to host pick. Stage/sel/query
                               state lives in `NewSessionMachine` (unit-tested) so the
                               sel-reset invariants don't depend on view-side onChange
    SessionMetaLabel.swift     shared session-row pieces: name (alias › id › dim cwd/cmd
                               line), trailer (CC sparkle + in-sidebar glyph + client-count
                               + creation age or task exit), and the not-responding row
    HostsView.swift            master-detail Hosts sheet (list + add-host form)
    HostDetailView.swift       detail pane: rename, N×N SlotPicker (10-slot theme-derived ramp,
                               bicolor HostDot), sessions, remove
    ForkPaletteView.swift      ForkPanePalette (⌘K, rendered by the fork-owned
                               ForkPaletteCard — fills a window-scaled panel; upstream's
                               CommandPaletteView caps at 500×~250 so it's not used; match
                               highlighting still reuses upstream String.matchedIndices) +
                               ScrollbackSearchView (⌘⇧K, history fetched once per sheet
                               then matched client-side)
    CheatsheetView.swift       hold-⌥ shortcut overlay; static content, shown/hidden by
                               `setCheatsheet` off OptionGestureRecognizer's `onPeek`
                               (it owns the debounce — there is no second ⌥ recognizer)
    ForkSheetPanel.swift       NSWindow.performKeyEquivalent → ⌘V/C/X/A/Z/⇧Z to
                               firstResponder; reused as the borderless ⌘K palette window
```

New-session flow: one two-stage palette (`NewSessionView`) for every entry point. ⌘T /
⌘⇧T / sidebar ＋ open it at the host stage (active host pre-selected); ⌘D and the
host context-menu open it host-locked, skipping straight to the name stage. ⌘⇧T
shadows upstream's `undo` alias (Config.zig:6934); ⌘Z remains undo.

## Gotchas (each cost ≥1 verifier round)

- **`windowDidLoad` fires *inside* `super.init`**: `BaseTerminalController.init` assigns
  `surfaceTree` → `didSet` → `surfaceTreeDidChange` reads `self.window` → nib lazy-loads.
  Do registry seeding in `newWindow()` after init returns, never in `windowDidLoad`.
- **`@Published.sink` without a scheduler fires synchronously** inside the property setter.
  `$surfaceTree` uses `.debounce(80ms, .main)` — async delivery so `bind()` completes before
  `persistActive` projects, *and* divider-drag (per-frame `splitDidResize`) doesn't storm
  the sidebar.
- **The process env is frozen at `ghostty_init`.** Since the Zig 0.16 port libghostty
  snapshots the C `environ` array as a slice and builds every surface's env from it. A
  `setenv` after that (a new variable reallocs the array, a longer value reallocs the
  string) leaves the snapshot dangling: `createMap` fails, `Surface.zig` falls back to an
  **empty** env, and the log fills with `error getting env map for surface
  err=error.OutOfMemory`. Panes then carry only `PATH=<app>/Contents/MacOS` — `zmx attach`
  (absolute path) still works, which hides it, while ssh panes and anything resolved by
  name die at exec, and new sessions are created without `SSH_AUTH_SOCK`/`TMPDIR`/`LANG`.
  Whether freed memory still reads back intact is the allocator's call, so it can stay
  latent for months and appear with an OS update. Every mutation goes in
  `ForkBootstrap.prepareEnvironment` (seam #3, before `ghostty_init`); `fork-check.sh`
  fails on a `setenv`/`unsetenv`/`putenv` anywhere else under `Fork/`. Need a different
  env for one child? Pass `Process.environment` / `SurfaceConfiguration.environmentVariables`.
- `GHOSTTY_FORK_ZMX=/path` overrides zmx resolution; `GHOSTTY_FORK=0` disables the
  whole fork (the per-feature `GHOSTTY_FORK_NO_*` bisect toggles were removed).
- **zmx reads the *client's* environment, and every pane inherits the app's.**
  `ZMX_SESSION` (injected into every shell inside a session) turns `zmx attach X` into
  "switch the session I'm in to X" — it never attaches, exits 0, and yanks the launching
  pane's client onto the new name. Running the app binary from a fork pane would kill
  every new local pane and hijack the pane you launched from; `ZMX_SESSION_PREFIX` would
  silently file every managed session as external. `ForkBootstrap.scrubZmxEnvironment`
  unsets both (from `prepareEnvironment`, pre-`ghostty_init`). The same function sets
  `ZMX_NO_DETACH_KEY=1`: ctrl+\ is zmx's in-band detach key, which in a fork pane blanks
  it into the placeholder and makes SIGQUIT undeliverable — the fork owns detach (⌘W).
  Remote attaches get it via `Transport.wrap`'s env prefix.
- **A session name is not opaque to zmx.** A trailing `*` makes `zmx kill`/`wait`/`tail` a
  *prefix match* while `attach` reads it literally — so a session literally named `dev*`
  exists, lists, and would turn the Kill button into "kill everything starting with dev"
  (`*` alone: every session on the host). `isSafeExternalName` refuses such names, like
  leading `-`; they never become a `SessionRef`.
- **`err=` rows are sessions, not noise.** A daemon that misses `zmx list`'s 1s probe
  prints `name=…\terr=Timeout\tstatus=unreachable`; zmx says it may just be busy. They
  land in `ListResult.unresponsive`: kill verification counts them as still-present, the CC
  probe keeps last-known for them (not `.probeAbsent`), and pickers/Hosts show a dim
  "not responding" row. Never reach for `zmx kill --force` — it unlinks the socket of a
  merely busy daemon and orphans it.
- **Sheet ⌘V**: nil-targeted menu actions walk *past* the sheet to
  `mainWindow.firstResponder` (the `SurfaceView`, which has its own `paste:`).
  `ForkSheetPanel.performKeyEquivalent` intercepts before the menu.
- **`activeTabID` is controller-owned**: registry's `newTab`/`removeTab` mutate the list
  and may *nil* the cursor (removing the active tab); only
  `ForkWindowController.activate(tab:)` ever sets it to a tab.
- **Undo is window-scoped, tabs aren't**: `BaseTerminalController.replaceSurfaceTree`
  registers `{ target.surfaceTree = oldTree }` with `withTarget: self`. The closure
  captures a *tree*, not a tab id, so ⌘Z after a sidebar tab switch would write the
  previous tab's tree under the new `activeTabID` (then `persistActive` makes it
  permanent). `activate(tab:)` clears `undoManager.removeAllActions(withTarget: self)`
  on switch — same idiom upstream uses at `BaseTerminalController.swift:226`.
- **iOS target shares `Sources/`** via the synchronized group. Every file under `Fork/` must
  be wrapped in `#if os(macOS) … #endif`.
- **`SessionRef.name` is not unique within a tab**: `ZmxAdapter` strips the `{hostID}-` prefix
  on list parse, so a tab-owned `acr` and an external-attached `acr` collide. Per-tab dicts
  (`paneLabels`/`paneTags`/`lastActive`) key on `SessionRef.key` (`@`-prefix for external).
- **Three pane-title layers**: `paneLabels[ref.key]` (the *alias*, ⌘I) › `surface.title`
  (OSC-driven, per-`SurfaceView`-instance, lost on restart) › `ref.name` (zmx session id).
  The alias's source of truth is the daemon-side session label `ghostty_name=<v>`
  (`zmx set`); `paneLabels` is its write-through cache. The per-ref rules live in the
  `AliasSync` reducer (`syncAliases` drives it off the poll's `zmx list`, and every
  `zmx set` result is fed back in): daemon-wins; a *missing* label is an authoritative
  clear only from a daemon that has proven label-capable — it has shown a label, or Ack'd
  one of our writes (since zmx 0.7.0 `zmx set` exits 0 only on the daemon's Ack; `zmx list`
  alone still can't tell, old and new daemons print alike) — and only on the *second*
  consecutive label-less row (`zmx list` waits just 50ms for a busy daemon's labels); an
  unproven absence keeps the cache and gets the once-per-incarnation migration/seed push
  (managed refs only, budgeted 4/host/tick). The proof is persisted per incarnation
  (`TabModel.aliasProven`), so a clear made elsewhere while the app was quit isn't
  "migrated" back on launch. Session identity is zmx `created` + pid (1s resolution alone
  misses kill-then-recreate), so a recreated session re-migrates; a pending-write mask
  (released by the echo, by the first list fetched after the write's Ack, or a 40s TTL)
  keeps a fresh rename from being clobbered by the stale echo; a stamp-matched failure
  unmasks immediately and queues *that write's own value* for ≤3 retries ahead of
  daemon-wins (else a failed rename against an already-labeled session silently reverts)
  — counted since the last write that landed, dropped if the daemon's label has moved on
  since (someone else's newer write wins), and skipped entirely for "daemon too old".
  Writes for one session run strictly one at a time, newest wins (`liveAliasPusher`).
  Don't reach for `zmx attach --labels` to seed: despite its help text it applies on
  *every* attach (restore/placeholder paths would clobber renames made elsewhere), a label
  failure aborts the attach, and a pre-0.8 client reads the flag as the session name.
  `renamePane` is the one user
  writer (sanitizes via `AliasCodec.sanitize`); a creation seed labels the daemon only —
  label == id never enters the cache (it would freeze the row over the OSC title). Values
  escape into zmx's `[A-Za-z0-9._-]` via `AliasCodec` (`_HH`); raw values outside that
  charset are rejected at parse (zmx validates labels only in its CLI — see Security).
  An agent inside a pane can rename itself with `zmx set . ghostty_name=…`.
  Upstream's `titleFallbackTimer` writes `"👻"` 500ms after surface init — `PaneLabel` treats
  it as no-title. A zmx ≥0.8 *daemon* replays the window title (and OSC 7) on re-attach;
  an older one replays only the buffer, so `surface.title` stays empty until the next
  prompt. Daemons keep the binary they were started with, so after a zmx upgrade some rows
  restore their titles and some don't — expected, not a fork bug.
- **Codable defaults aren't optional**: adding a non-Optional field with a default to a
  persisted type breaks decode of old `fork.json`. Use `decodeIfPresent` in a custom
  `init(from:)`.

## Security boundary

`Transport.wrap` / `controlArgv` are the shell **boundary**. `SSHTarget` and
`SessionRef.name` are validated against `\A[A-Za-z0-9._-]+\z` (`\A…\z`, not `^…$` — ICU `$`
matches before a trailing newline); `shq` single-quotes argv. For ssh, the remote command is
double-quoted (`shq(shq(argv))`) and both ssh argv builders pass `--` before the destination.
The only other shell-string builders are `ZmxAdapter.detachedScript`/`restoreCmd`/
`smartJumpCmd` and `CCProbe.renameScript` — all of which charset-validate and/or
`shq`/`stripControl` every dynamic token. Don't build shell strings anywhere else. (`ForkBootstrap.loginShellOutput` does run the user's login
shell at launch, but only with compile-time-literal commands — never pass it anything
derived from session, host, or remote data.)

Beyond the shell layer: **external** session names bypass the regex (they come from remote
`zmx list` verbatim) — `ZmxAdapter.partition` and `Persistence.scrub` drop leading-`-` names
so they can't become zmx options, and partition only trusts the `{hostID}-` wire prefix when
the stripped name passes the managed charset (a forged prefix on a hostile name stays
external); `ZmxAdapter.parse` is first-key-wins (a session *label* can't shadow the built-in
`name`/`clients`/`err` fields) and drops a second row for a session key it has already seen
(zmx validates labels only in its **CLI** — a raw `LabelSet` on the socket stores tab/newline
bytes verbatim, enough to forge whole `zmx list` rows; `AliasCodec.alias` likewise rejects any
raw `ghostty_name` outside the codec's own charset — daemon-side validation was proposed
upstream and declined, so these parse-side guards are permanent; `ghostty_name` itself is
*last*-occurrence-wins, because `cwd=`/`cmd=` print before the labels and are free text — a
tab inside a command line must not pose as the label); `{cwd}` for hover commands must be an absolute path (`ZmxAdapter.expand` degrades
anything else to `.`) because it originates from OSC 7 / the CC probe / the zmx daemon's
`cwd=`, all pane-controlled — and the directory a remote split starts in travels as one
`shq`'d positional argument to a fixed `sh -c` script (`Transport.wrap(_:cwd:)`), never
interpolated into it;
cached CC names are `stripControl`'d before they reach a local pty, and so are remote-origin
strings that reach UN notification titles (`paneDisplayLabel`) and `CommandError.stderr`.
`zmx run()` output accumulation is capped (8 MiB stdout / 256 KiB stderr) so a hostile remote
can't balloon memory inside the timeout window. On shared-uid hosts the probe still transfers
(and heartbeats) every user's CC session files — treat `name`/`detail`/`needs` from such
hosts as untrusted display text.

## Hover commands

User-defined hover-key actions, hand-edited in `fork.json` (`~/Library/Application
Support/com.mitchellh.ghostty/fork.json`). Loaded once at launch.

```json
"hoverCommands": {
  "g": { "cmd": ["lazygit", "-p", "{cwd}"], "mode": "pane" },
  "j": { "cmd": ["jj", "-R", "{cwd}", "log"], "mode": "pane" },
  "o": { "cmd": ["open", "{cwd}"],            "mode": "local" }
}
```

Edit while the app is **quit** — `fork.json` autosaves on every state change and will
overwrite a live edit. `cmd` is an **argv array** — each element stays one word through
`Transport.wrap`/`shq` or `Process.arguments`, so an untrusted `{cwd}` stays inert.
`{cwd}`/`{ref}`/`{host}` substitute **whole tokens only** (`ZmxAdapter.expand`);
`"-C={cwd}"` passes through verbatim. `{host}` is the ssh `user@host` (or label for
local), not the internal hash id. `mode` (unknown values — including the removed
`overlay` — drop that one binding; the load path preserves the original file aside):

- `pane` — sibling split next to the *focused* pane, running `zmx attach <fresh-ref> <cmd…>`
  on that pane's host (local or ssh, via `Transport.wrap`). The new session starts in the
  focused pane's directory (same rule as ⌘D), so `{cwd}` flags are optional. The split is
  *disposable*: when the tool exits the pane closes — no reattach placeholder — and the
  throwaway session is killed best-effort.
  No-ops on a tab whose `liveTabs` entry hasn't been built yet (cold-restored, never
  activated).
- `local` — fire-and-forget `Process` on the mac via `/usr/bin/env`; PATH is the
  cached login-shell PATH exported at launch (launchd's bare PATH if there's no cache yet), so
  most tools resolve by name; an absolute path is still the safe choice for anything
  exotic. For panes on **remote** hosts `{cwd}` degrades to `.` — a remote-controlled cwd
  must not steer what a local tool opens or operates on; only `pane` mode (or panes on
  the local host) receives the pane's real cwd.

`{cwd}` resolves (`ForkWindowController.paneCwd`) `surface.pwd` (OSC 7 — **local panes
only**: Ghostty drops OSC 7 whose host isn't the Mac, so it is always nil on ssh hosts) ›
`ccLive[host][ref.key].cwd` (CCProbe poll, while an agent runs) › `zmxCwd[host][ref.key]`
(the daemon's own tracking from the last `zmx list`, zmx ≥0.8 — every session on every
host, CC toggle or not) › `"."`. ⌘D and `pane`-mode commands start the new session there. Bindings appear in the ⌘K palette
(targeting the *focused* pane, via `runPaneCommand`) and in the ⌥-hold cheatsheet —
there is no bare-letter hover dispatch (`hoveredPane` was removed; the terminal is
usually firstResponder so stray letters intercepted). The `key` in `hoverCommands` is
now just a stable config id; it's no longer the dispatch character.

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

**Post-rebase smoke pass** (fork-check + a green build can still hide quiet behavior breaks —
these five exercise the upstream contracts the fork leans on hardest):
1. Switch tabs in the sidebar, then ⌘Z — must NOT swap the previous tab's tree in (undo
   retargeting contract).
2. Background a pane until it settles, click the notification banner — must focus that tab
   (UN-delegate proxy contract).
3. Open a new window — sidebar on the left, terminal shifted, no overlap (contentView
   layout-surgery contract; also guards the Liquid-Glass-subview skip).
4. ⌘W on one pane of a multi-pane tab → per-pane Detach/Kill sheet; ⌘W on the last pane →
   tab-level sheet (close-routing contract — upstream is actively refactoring its close
   path, and a reroute leaves ⌘W closing the window with no sheet).
5. Run a long command (or a CC turn) → rail goes working → settles → banner fires → dock
   badge counts it (progressReport / `progress-style` gate / UN / badge contracts in one
   pass — all of these break silently).

## Backlog

- 3rd seam for `keybind = all:cmd+t=new_tab` config edge — leaks through
  `AppDelegate.ghosttyNewTab` since `ForkWindowController is TerminalController`.
- Direct "Rename Host" item in the sidebar host context menu (rename today goes through
  Manage Host… → label field).
- `macos-titlebar-style = tabs` config — `tabbingMode = .disallowed` should suppress
  the native tab bar but untested with our sidebar.
- Scripted **splits** (`NewTerminalIntent.swift:133`, `ScriptTerminal.swift:121`) hit our
  `newSplit` override → picker pops + script gets nil. (Scripted new-window/new-tab paths
  already carry a `NewSessionIntent` through `ForkBootstrap.intercept`.)
- **Scrollback peek** — a throwaway local split running `zmx history --vt <name> | less -R`:
  full-colour look at any session (in the sidebar or not) without becoming a client, so it
  can't claim leadership or resize an agent's TUI.
- Persist a dirty bit for an alias write that hadn't been Ack'd at quit (today the relaunch
  lets the daemon win, i.e. the rename reverts).
- ssh attach to a re-keyed host behind a ProxyCommand dies opaque (`UNKNOWN port 65535`)
  at the host-key prompt — consider `-o StrictHostKeyChecking=accept-new` or a clearer
  error surface in the ssh argv builders (`ZmxAdapter.swift` Transport extension).
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

- Launch applies the *cached* login-shell PATH instantly (pre-`ghostty_init`) and refreshes
  the cache via a background probe (15s bound — heavy rc inits measured at 2-4s defeat any
  short inline probe; `ForkBootstrap.refreshLoginPATHCache`). The refresh is cache-only —
  the env is frozen once libghostty has snapshotted it — so a changed login PATH applies
  at the *next* launch, and the first-ever launch (no cache) runs on launchd's bare PATH:
  ProxyCommand-by-name hosts stay unreachable until a relaunch. `ZmxAdapter.localZmx` no
  longer probes the login shell: env override → PATH → the hardcoded dir list → bare `zmx`. Set
  `GHOSTTY_FORK_ZMX=/abs/path` for an install somewhere exotic.
- **The pane can't tell why its zmx client ended** — shell `exit`, ssh drop, detach and a
  kill from another Mac are all exit 0. So the placeholder *asks* (`zmx list` over the
  control transport, before each prompt): "detached — still running" / "session ended — ⏎
  starts a fresh shell" / "can't reach <host>". The sidebar shows the same from the poll
  (`SessionRegistry.liveness`): ⏸ detached (a hydrated pane whose session has 0 clients —
  the placeholder at its prompt, or a pane whose client was *switched* in-band by typing
  `zmx attach other` inside it; the fork doesn't follow a switch, its ref/alias/Kill keep
  naming the original session), ⏹ ended (absent from two consecutive lists — shown on
  cold rows too), ⚠ not responding. Host header: "⏸ N" + context-menu **Reattach N
  Detached Panes** after a VPN flap.
- ssh panes run with `ServerAliveInterval=15 / CountMax=3 / ConnectTimeout=15`
  (`Transport.paneSSHOptions`; command-line `-o` beats `ssh_config`). Without them a link
  that died silently leaves the pane frozen for minutes while everything else reads healthy.
- Kill is fire-and-forget after the tab closes, so a kill that didn't land is reported as a
  banner ("Kill didn't land on <host>", click → Hosts sheet). Verified by one follow-up
  `list` (answered rows *plus* `err=` rows), re-checked after 4s — a timed-out kill is
  "sent, not confirmed" and often lands late. Already-gone counts as success.
- `TERM_PROGRAM`/`SSH_AUTH_SOCK` in a *pre-existing* remote session: `wrap` sets
  `ZMX_TRACK_ENV` so zmx ≥0.8 records them from each attaching client; add
  `eval "$(zmx print-env -s .)"` to the remote shell's precmd hook to pick them up (it only
  records — it never changes a running process's environment).
- `refs` entries for **Detach**-closed panes leak until tab close / quit (Kill and tab/host
  close do unbind; `persistActive` never prunes — see undo gotcha); `isConnected()` may stay
  green slightly stale. In-memory only, not persisted.
- `SessionRegistry.shared` stored-prop init will fail compile under Swift 6 strict concurrency.
- ⌘⇧[/⌘⇧] tab nav matches `{`/`[` and `}`/`]` via `charactersIgnoringModifiers`.
  Digit shortcuts (⌘1-9, ⌘⌥1-9) are layout-independent via `keyCode`.
  All list-relative nav (⌘1-9, ⌘⇧[/⌘⇧], last_tab, move_tab) goes through one
  `visibleTabs()` accessor matching what the sidebar renders (focus mode + tag
  filter applied) — never add a nav path that reads `registry.tabs(on:)` raw.
  move_tab no-ops in focus mode (derived order, nothing to move).
  ⌘[/⌘] left to upstream's `goto_split`. ⌘W → per-pane/tab Detach/Kill sheet
  (second ⌘W or K = Kill, Esc = Cancel). ⌘⇧B toggles the sidebar; dragging the
  sidebar's right edge resizes it (248pt floor, capped at min(560, half the window),
  persisted).
  Mouse back/forward walks the tab visit history, window-wide. Two delivery paths,
  both handled: swipe gestures (deltaX ±1 — what SteerMouse / Logi Options+ / trackpad
  page-swipes emit; the Safari convention) and raw buttons 3/4 (drivers that pass thumb
  buttons through untranslated). Trade-off: the pty never sees either form (xterm SGR
  buttons 8/9), so a TUI that binds them loses; nothing common does. Also in the ⌘K
  palette as Back/Forward (shown only when a step would actually land somewhere).
  Swallowed-but-inert while a sheet or the ⌘W alert is up.
  ⇧⏎ in the session picker = smart-jump create — needs the zsh-z plugin (`zshz`) in
  the target host's .zshrc. No zshz → starts in the default dir; no zsh at all → the
  sh wrapper degrades to `${SHELL:-sh} -l`. Disabled when the typed name already
  exists (zmx attach would reuse that session and discard the jump).
  ⌘⌥A/⌘⌥P (watch / pin) match physical `kVK_ANSI_A`/`_P` (keyCode 0/35);
  AZERTY gets ⌘⌥A on ⌘⌥Q. ⌘⇧R (repaint) is keyCode 15.
  ⌘K/⌘⇧K shadow upstream's `clear_screen`; rebind via
  `keybind = cmd+ctrl+k=clear_screen` if wanted.
  Hold a solo ⌥ ≥0.5s to peek: `CheatsheetView` plus the sidebar's read-CC reveal, one
  threshold, one recognizer (`OptionGestureRecognizer`). Any key or mouse event while ⌥
  is down — including autorepeat — is a chord and cancels/hides both. ⌘-hold shows
  nothing (it used to drive the cheatsheet; ⌘ is held too often for that to sit still).
- CC probe (sparkle toggle) reads `~/.claude/sessions/` — a zshrc-only
  `CLAUDE_CONFIG_DIR` override is invisible to the Dock-launched app and to
  `ssh -o BatchMode=yes` (non-login shell). The **local** host probe is native Swift
  (sysctl process table + FileManager — no per-tick process spawns); **remote** probes
  run the POSIX `sh` script (`ps -A -o pid=,ppid=`; BusyBox/Alpine untested). Shared-uid
  remotes (`deploy@`) ship every user's CC pid-files over the wire — BFS filters the
  *result* to descendants of our zmx sessions, but the raw transfer doesn't.
  The poll stretches from 3s to 30s while no fork window is visible (occluded /
  minimized / locked screen), and the inter-tick sleep is deadline-based so one
  down ssh host (5s timeout) can't push the local host's cadence to ~8s.
  The red `.blocked` indicator depends on classifier fields (`tempo`/`needs`)
  that the agent only writes while it believes it's being watched —
  the probe touches the heartbeat file every poll to keep that true, but
  the agent-side feature gate must also be on (silently absent otherwise).
  CC doesn't reliably rewrite `tempo` once you reply; `PaneMachine.apply`
  handles that by event ordering (`.progress` clears `blocked`, only a
  *changed* classifier `Sig` re-sets it, `.viewed` clears) — see
  `PaneMachineTests` for the cases that used to need a Date-watermark.
- Sidebar mono font reads `window-title-font-family` (not `font-family` — that's a
  `RepeatableString` and `c_get.zig` can't return it without an upstream `cval()`).
  Set `window-title-font-family = <terminal font>` for matched typography.
- ⌘⇧K scrollback search fetches `zmx history` **once per sheet** (all sessions,
  width-capped at 4 concurrent, local-first so a many-pane query doesn't burst
  N fresh ssh connections past sshd `MaxStartups`) and matches client-side against
  the cached buffers as you type (keeps user input out of `controlArgv`'s shell).
  Each hit shows the latest matching line ± one line of context and the match count.
  Content written after the sheet opened isn't searched — reopen to refresh. zmx keeps
  the last 10k lines per session. A pane whose history didn't come back (10s timeout, or
  zmx's own 5s internal one, which exits 0 with nothing) is counted as *unavailable* in
  the footer, not as "no match".
