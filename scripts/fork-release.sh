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
# The Metal compiler is a separate download that belongs to one Xcode build, so the same
# auto-update leaves it uninstalled. That can stay hidden for weeks: zig caches the compiled
# shaders, and `metal` only runs again when they change or the cache is new (a new Zig).
# xcrun also remembers "missing" after the download has finished, hence the second try.
xcrun -sdk macosx metal --version >/dev/null 2>&1 \
  || { xcrun --kill-cache; xcrun -sdk macosx metal --version >/dev/null 2>&1; } \
  || { echo "fork-release: Xcode's Metal toolchain is not installed — run: xcodebuild -downloadComponent MetalToolchain" >&2; exit 1; }

# Preflight: is the Zig this tree needs installed? Upstream raises build.zig.zon's
# `minimum_zig_version` every few months (0.16 in 2026-07, 0.17 in 2026-10), so the first
# release after a rebase is where a missing toolchain shows up. Without this check
# scripts/shims/zig falls through to the system `zig` and the build dies on a version error.
#
# How Zig is installed here (scripts/shims/zig depends on it, and so do the zmx deploy scripts):
#   ~/.local/share/zig-X.Y.Z/   the official tarball from ziglang.org, unpacked and untouched
#   ~/.local/bin/zig-X.Y        symlink to that directory's `zig`; ~/.local/bin is on PATH
# One directory per release, side by side. Nothing is ever upgraded in place, because this repo
# and zmx change Zig versions at different times. Not Homebrew: it carries one version, and
# moves it on its own schedule. A patch release (X.Y.1) gets its own directory and the
# symlink is re-pointed. An old directory can go once no build.zig.zon on this machine names
# its X.Y. The message below is the install procedure, with this tree's version filled in.
zig_min="$(sed -nE 's/.*\.minimum_zig_version = "([^"]+)".*/\1/p' build.zig.zon | head -1)"
zig_bin="zig-${zig_min%.*}"
zig_have="$("${zig_bin}" version 2>/dev/null || true)" # empty sorts first, so "missing" fails too
if [[ "$(printf '%s\n' "${zig_min}" "${zig_have}" | sort -V | head -1)" != "${zig_min}" ]]; then
  zig_tar="zig-$(uname -m | sed 's/^arm64$/aarch64/')-macos-${zig_min}"
  cat >&2 <<EOF
fork-release: this tree needs Zig >= ${zig_min} as \`${zig_bin}\` on PATH (found: ${zig_have:-none}). To install it:

  cd "\$(mktemp -d)"
  curl -fLO https://ziglang.org/download/${zig_min}/${zig_tar}.tar.xz
  shasum -a 256 ${zig_tar}.tar.xz    # must match the one listed on https://ziglang.org/download/
  tar -xJf ${zig_tar}.tar.xz
  mv ${zig_tar} ~/.local/share/zig-${zig_min}
  ln -sfn ~/.local/share/zig-${zig_min}/zig ~/.local/bin/${zig_bin}
EOF
  exit 1
fi

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
