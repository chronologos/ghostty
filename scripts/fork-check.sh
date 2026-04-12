#!/usr/bin/env bash
# Guards the fork's upstream-isolation invariants. Run in CI and after `jj rebase`.
# See do_not_commit/ghostty-fork/SPEC.md §2.3, §2.4.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "fork-check: FAIL — $1" >&2; exit 1; }

# §2.3 — exactly two `// [fork]` seam lines outside Fork/
seam_count=$( { rg -c --no-filename '\[fork\]' macos/Sources --glob '!**/Fork/**' || true; } | awk '{s+=$1} END{print s+0}')
[[ "$seam_count" -eq 2 ]] || fail "expected 2 [fork] seam lines outside Fork/, found $seam_count"

# §2.4 — upstream symbols the fork references by name must still exist after rebase.
# Format: <regex> <TAB> <expected file (informational)>
syms=$(cat <<'EOF'
class BaseTerminalController	macos/Sources/Features/Terminal/BaseTerminalController.swift
var surfaceTree	macos/Sources/Features/Terminal/BaseTerminalController.swift
func newSplit\(	macos/Sources/Features/Terminal/BaseTerminalController.swift
struct SplitTree	macos/Sources/Features/Splits/SplitTree.swift
struct TerminalSplitTreeView	macos/Sources/Features/Splits/TerminalSplitTreeView.swift
class SurfaceView	macos/Sources/Ghostty/Surface View/
struct SurfaceConfiguration	macos/Sources/Ghostty/Surface View/SurfaceView.swift
var command: String\?	macos/Sources/Ghostty/Surface View/SurfaceView.swift
var workingDirectory: String\?	macos/Sources/Ghostty/Surface View/SurfaceView.swift
var environmentVariables	macos/Sources/Ghostty/Surface View/SurfaceView.swift
ghosttyCloseSurface	macos/Sources/Ghostty/
struct CommandPaletteView	macos/Sources/Features/Command Palette/
struct CommandOption	macos/Sources/Features/Command Palette/
var titleOverride: String\?	macos/Sources/Features/Terminal/BaseTerminalController.swift
func closeTabImmediately\(	macos/Sources/Features/Terminal/TerminalController.swift
var processExited: Bool	macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift
EOF
)

while IFS=$'\t' read -r pat hint; do
  [[ -z "$pat" ]] && continue
  rg -q "$pat" macos/Sources --glob '!**/Fork/**' \
    || fail "upstream symbol gone: /$pat/  (was in $hint)"
done <<< "$syms"

echo "fork-check: OK — 2 seams, $(wc -l <<< "$syms" | tr -d ' ') upstream symbols present"
