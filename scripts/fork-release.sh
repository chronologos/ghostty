#!/usr/bin/env bash
# Builds an optimized fork Ghostty.app, re-signed with a stable self-signed
# identity so TCC keys grants on the cert leaf (not the per-build CDHash).
#   - libghostty: zig ReleaseFast (xcframework only; we drive xcodebuild ourselves)
#   - Swift app:  xcodebuild ReleaseLocal (ad-hoc), then post-hoc codesign
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
IDENTITY="${FORK_SIGN_IDENTITY:-ghostty-fork-dev}"

./scripts/fork-check.sh

echo "→ libghostty (ReleaseFast)"
PATH="$(pwd)/scripts/shims:$PATH" zig build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework \
  -Demit-macos-app=false

out="macos/build/ReleaseLocal/Ghostty.app"
# Fresh .app dir each build — leftover nested code from a prior build that the
# inside-out codesign list below doesn't cover would survive and break AMFI's
# deep validation at launch.
rm -rf "${out}"

echo "→ Ghostty.app (ReleaseLocal)"
# Clean env: Nix's NIX_LDFLAGS/NIX_CFLAGS_COMPILE poison xcodebuild's linker.
# OTHER_SWIFT_FLAGS (unset in pbxproj, so CLI override is non-clobbering) bakes the
# fork on by default; env GHOSTTY_FORK=0 still opts out at runtime.
env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  xcodebuild \
    -project macos/Ghostty.xcodeproj \
    -scheme Ghostty \
    -configuration ReleaseLocal \
    "SYMROOT=$(pwd)/macos/build" \
    'OTHER_SWIFT_FLAGS=$(inherited) -DGHOSTTY_FORK_DEFAULT' \
    'PRODUCT_BUNDLE_IDENTIFIER=com.mitchellh.ghostty.fork' \
    build

if security find-identity 2>/dev/null | grep -q "\"${IDENTITY}\""; then
  echo "→ re-sign with '${IDENTITY}'"
  ent="${ROOT}/macos/GhosttyReleaseLocal.entitlements"
  # Inside-out: nested code first (no entitlements), then the app shell.
  codesign --force --deep --sign "${IDENTITY}" \
    "${out}/Contents/Frameworks/Sparkle.framework"
  codesign --force --sign "${IDENTITY}" \
    "${out}/Contents/PlugIns/DockTilePlugin.plugin"
  codesign --force --options runtime --entitlements "${ent}" \
    --sign "${IDENTITY}" "${out}"
  # --deep so an incomplete nested re-sign (Sparkle's XPCs/Updater.app held open by
  # a running instance) fails *here* instead of as an AMFI SIGKILL "Launch Constraint
  # Violation" at next launch.
  codesign --verify --deep --strict --verbose=2 "${out}" 2>&1
  echo "  designated requirement:"
  codesign -dr - "${out}" 2>&1 | sed -n 's/^designated => /    /p'
else
  echo "⚠ identity '${IDENTITY}' not found — left ad-hoc; TCC will re-prompt every build"
  echo "  fix: scripts/fork-make-cert.sh   (or: FORK_SIGN_IDENTITY='Apple Development: …')"
fi

echo
echo "✓ ${out}"
du -sh "${out}"
