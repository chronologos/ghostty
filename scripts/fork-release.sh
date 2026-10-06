#!/usr/bin/env bash
# Builds an optimized fork Ghostty.app, re-signed with a stable self-signed
# identity so TCC keys grants on the cert leaf (not the per-build CDHash).
#   - libghostty: zig ReleaseFast (xcframework only; we drive xcodebuild ourselves)
#   - Swift app:  xcodebuild ReleaseLocal (ad-hoc), then post-hoc codesign
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
IDENTITY="${FORK_SIGN_IDENTITY:-ghostty-fork-dev}"

# Preflight: can Xcode run at all? An App Store auto-update (they follow macOS updates)
# swaps in a new Xcode whose license hasn't been agreed to and whose first-launch tasks
# haven't run, and from then on every xcodebuild exits 69. The zig build below is the worst
# place to find that out: its xcframework step *captures* xcodebuild's stderr and drops it
# (XCFrameworkStep.zig), and has already `rm -rf`'d the old framework by then — so all you
# see is "process exited with code 69" and a repo with no GhosttyKit.xcframework. Ask
# xcodebuild directly, before anything is deleted; it says what's wrong in plain words.
xcodebuild -license check \
  || { echo "fork-release: Xcode license not accepted — run: sudo xcodebuild -license accept" >&2; exit 1; }
xcodebuild -checkFirstLaunchStatus \
  || { echo "fork-release: Xcode first-launch tasks pending — run: sudo xcodebuild -runFirstLaunch" >&2; exit 1; }

# Skip the xcframework freshness check — the zig build right below regenerates it.
FORK_CHECK_SKIP_XCFW=1 ./scripts/fork-check.sh

echo "→ libghostty (ReleaseFast)"
PATH="$(pwd)/scripts/shims:$PATH" zig build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework \
  -Demit-macos-app=false

# Freshness stamp for fork-check.sh: which zig-source state this framework was built from.
# Detects "rebased but never regenerated" — new Swift + old libghostty links and runs, but
# misbehaves silently.
git log -1 --format=%H HEAD -- src include > macos/GhosttyKit.xcframework/.fork-zig-sha

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

echo "→ fork icon"
# Baked, not painted at launch: Finder, Spotlight, the quit Dock tile and notification
# banners only ever read the bundle's icon. Upstream's lives in Assets.car behind
# CFBundleIconName, which wins over CFBundleIconFile, so the key has to go. Drawn by
# scripts/fork-icon/render.swift. Must stay above the signing below — Info.plist and
# Resources are both under the seal.
cp scripts/fork-icon/ForkGhost.icns "${out}/Contents/Resources/ForkGhost.icns"
plutil -replace CFBundleIconFile -string ForkGhost "${out}/Contents/Info.plist"
plutil -remove CFBundleIconName "${out}/Contents/Info.plist"

ent="${ROOT}/macos/GhosttyReleaseLocal.entitlements"
if security find-identity 2>/dev/null | grep -q "\"${IDENTITY}\""; then
  echo "→ re-sign with '${IDENTITY}'"
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
  # The icon swap broke xcodebuild's seal on the app shell; nested code is untouched.
  codesign --force --options runtime --entitlements "${ent}" --sign - "${out}"
fi

echo
echo "✓ ${out}"
du -sh "${out}"
