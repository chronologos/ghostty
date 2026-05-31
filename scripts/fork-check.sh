#!/usr/bin/env bash
# Guards the fork's upstream-isolation invariants. Run in CI and after `jj rebase`.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "fork-check: FAIL — $1" >&2; exit 1; }
warn() { echo "fork-check: WARN — $1" >&2; warned=1; }
warned=0

# --- Seams: exactly two `// [fork]` lines outside Fork/ -------------------------------
seam_count=$( { rg -c --no-filename '\[fork\]' macos/Sources --glob '!**/Fork/**' || true; } | awk '{s+=$1} END{print s+0}')
[[ "$seam_count" -eq 2 ]] || fail "expected 2 [fork] seam lines outside Fork/, found $seam_count"

# --- Upstream symbols the fork references by name ------------------------------------
# Format: <regex> <TAB> <expected location>. Each is searched in its expected location
# first; "found elsewhere" is a warning (the fork's reference may need updating too),
# "found nowhere" is a failure. These are the loud (compile-error-adjacent) breaks.
syms=$(cat <<'EOF'
class BaseTerminalController	macos/Sources/Features/Terminal/BaseTerminalController.swift
var surfaceTree	macos/Sources/Features/Terminal/BaseTerminalController.swift
func newSplit\(	macos/Sources/Features/Terminal/BaseTerminalController.swift
struct SplitTree	macos/Sources/Features/Splits/SplitTree.swift
struct TerminalSplitTreeView	macos/Sources/Features/Splits/TerminalSplitTreeView.swift
class SurfaceView	macos/Sources/Ghostty/Surface View
struct SurfaceConfiguration	macos/Sources/Ghostty/Surface View/SurfaceView.swift
var command: String\?	macos/Sources/Ghostty/Surface View/SurfaceView.swift
var workingDirectory: String\?	macos/Sources/Ghostty/Surface View/SurfaceView.swift
ghosttyCloseSurface	macos/Sources/Ghostty
struct CommandPaletteView	macos/Sources/Features/Command Palette
struct CommandOption	macos/Sources/Features/Command Palette
var titleOverride: String\?	macos/Sources/Features/Terminal/BaseTerminalController.swift
func closeTabImmediately\(	macos/Sources/Features/Terminal/TerminalController.swift
func closeWindowImmediately\(	macos/Sources/Features/Terminal/TerminalController.swift
var processExited: Bool	macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift
var progressReport	macos/Sources/Ghostty/Surface View/OSSurfaceView.swift
var bell: Bool	macos/Sources/Features/Terminal/BaseTerminalController.swift
var glassEffectView	macos/Sources/Features/Terminal/TerminalViewContainer.swift
class TerminalViewContainer	macos/Sources/Features/Terminal/TerminalViewContainer.swift
EOF
)

sym_count=0
while IFS=$'\t' read -r pat hint; do
  [[ -z "$pat" ]] && continue
  sym_count=$((sym_count + 1))
  if rg -q "$pat" "$hint" 2>/dev/null; then
    continue
  elif rg -q "$pat" macos/Sources --glob '!**/Fork/**'; then
    warn "symbol /$pat/ moved out of $hint — update the hint (and check the fork's call sites)"
  else
    fail "upstream symbol gone: /$pat/  (was in $hint)"
  fi
done <<< "$syms"

# --- Silent contracts (no compile error when they break) ------------------------------

# UN-delegate ordering: ForkNotify.install() defers one main-queue tick to wrap
# `center.delegate`; that only works while seam #1 runs before upstream's assignment.
# Anchored on the assignment itself — `let center = UNUserNotificationCenter.current()`
# appears more than once in AppDelegate.
ad=macos/Sources/App/macOS/AppDelegate.swift
seam_ln=$(rg -n 'ForkBootstrap\.install' "$ad" | head -1 | cut -d: -f1 || true)
deleg_ln=$(rg -n 'center\.delegate = self' "$ad" | head -1 | cut -d: -f1 || true)
[[ -n "$seam_ln" && -n "$deleg_ln" && "$seam_ln" -lt "$deleg_ln" ]] \
  || fail "ForkBootstrap.install must precede UN delegate assignment in $ad (seam:${seam_ln:-?} deleg:${deleg_ln:-?})"

# progress-style gate: upstream gates OSC 9;4 progress reports on this config option.
# If the gate moves/renames, every fork status dot, settle banner, and badge count reads
# permanently idle — with zero compile errors.
rg -q 'config\.progressStyle' macos/Sources/Ghostty/Ghostty.App.swift \
  || fail "progressReport gate (config.progressStyle) gone from Ghostty.App.swift — fork status dots depend on it"

# performAction string contract: the fork switches on these zig binding-action names
# (ForkWindowController.performAction). A rename upstream silently falls through to super.
for action in previous_tab next_tab last_tab goto_tab move_tab prompt_surface_title prompt_tab_title; do
  rg -q "^\s*${action}[,:]" src/input/Binding.zig \
    || fail "binding action '$action' gone from src/input/Binding.zig (fork's performAction switches on it)"
done

# --- xcframework freshness -------------------------------------------------------------
# A rebase that pulls zig-side changes rebuilds nothing by itself: new Swift + old
# libghostty links fine and misbehaves silently. fork-release.sh stamps the framework
# with the SHA of the last zig-source-touching commit at build time; compare it to now.
# FORK_CHECK_SKIP_XCFW=1 skips this (fork-release.sh sets it — it regenerates right after).
fw=macos/GhosttyKit.xcframework
stamp_file="$fw/.fork-zig-sha"
if [[ -d "$fw" && "${FORK_CHECK_SKIP_XCFW:-0}" != "1" ]]; then
  current_zig_sha=$(git log -1 --format=%H HEAD -- src include 2>/dev/null || true)
  if [[ ! -f "$stamp_file" ]]; then
    warn "xcframework has no build stamp — if you just rebased, regenerate it (zig build -Demit-xcframework) or run fork-release.sh"
  elif [[ -n "$current_zig_sha" && "$(cat "$stamp_file")" != "$current_zig_sha" ]]; then
    fail "GhosttyKit.xcframework is stale: zig sources changed since it was built (stamp $(cut -c1-12 "$stamp_file")… vs now $(echo "$current_zig_sha" | cut -c1-12)…). Regenerate it (zig build -Demit-xcframework) or run fork-release.sh."
  fi
fi

if [[ "$warned" -eq 1 ]]; then
  echo "fork-check: OK (with warnings) — 2 seams, $sym_count upstream symbols present"
else
  echo "fork-check: OK — 2 seams, $sym_count upstream symbols present"
fi
