#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
build_dir="${ASSETFURNACE_BUILD_DIR:-${TMPDIR:-/tmp}/assetfurnace-desktop-build}"
output="${1:-$here/build/AssetFurnace.app}"
configuration="${ASSETFURNACE_CONFIGURATION:-release}"
if [ "${AF_DISTRIBUTION:-0}" = 1 ]; then
  [[ "${AF_SERVER_COMMIT:-}" =~ ^[a-f0-9]{40}$ ]] || { echo "AF_SERVER_COMMIT must pin a tested commit" >&2; exit 1; }
fi
swift build --configuration "$configuration" --disable-sandbox --package-path "$here" --scratch-path "$build_dir"
bin="$(swift build --configuration "$configuration" --disable-sandbox --package-path "$here" --scratch-path "$build_dir" --show-bin-path)"
mkdir -p "$output/Contents/MacOS" "$output/Contents/Frameworks"
framework="$build_dir/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -d "$framework" ] || { echo "Sparkle framework not found" >&2; exit 1; }
ditto "$framework" "$output/Contents/Frameworks/Sparkle.framework"
cp "$bin/AssetFurnace" "$output/Contents/MacOS/AssetFurnace"
cp "$here/Info.plist" "$output/Contents/Info.plist"
if [ -n "${AF_SERVER_COMMIT:-}" ]; then
  /usr/libexec/PlistBuddy -c "Add :AFServerCommit string $AF_SERVER_COMMIT" "$output/Contents/Info.plist"
fi
if [ -n "${AF_BUILD_NUMBER:-}" ]; then
  [[ "$AF_BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "Invalid build number" >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $AF_BUILD_NUMBER" "$output/Contents/Info.plist"
fi
codesign --force --sign - "$output"
