#!/usr/bin/env bash
# Builds an optimized, ad-hoc-signed Ghostty.app for the fork.
#   - libghostty: zig ReleaseFast (xcframework only; we drive xcodebuild ourselves)
#   - Swift app:  xcodebuild ReleaseLocal (CODE_SIGN_IDENTITY="-")
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/fork-check.sh

echo "→ libghostty (ReleaseFast)"
PATH="$(pwd)/scripts/shims:$PATH" zig build \
  -Doptimize=ReleaseFast \
  -Demit-macos-app=false

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
    build

out="macos/build/ReleaseLocal/Ghostty.app"
echo
echo "✓ ${out}"
du -sh "${out}"
