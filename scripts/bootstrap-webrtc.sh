#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
ARCHIVE="$ROOT/artifacts/WebRTC-m150-macos-universal.xcframework.zip"
FRAMEWORK="$ROOT/Vendor/WebRTC.xcframework"

cd "$ROOT/artifacts"
shasum -a 256 -c SHA256SUMS

rm -rf "$FRAMEWORK"
mkdir -p "$ROOT/Vendor"
ditto -x -k "$ARCHIVE" "$ROOT/Vendor"
test -f "$FRAMEWORK/Info.plist"

FRAMEWORK_ROOT="$FRAMEWORK/macos-arm64_x86_64/WebRTC.framework"
TOP_LEVEL_BINARY="$FRAMEWORK_ROOT/WebRTC"
VERSIONED_BINARY="$FRAMEWORK_ROOT/Versions/A/WebRTC"

# The published universal archive contains the correct fat binary at the
# framework root, but a stale x86_64-only binary under Versions/A. A versioned
# macOS framework loads Versions/A/WebRTC at runtime, so canonicalize the
# extracted copy and keep the downloaded archive immutable.
TOP_LEVEL_ARCHS="$(lipo -archs "$TOP_LEVEL_BINARY")"
if [[ "$TOP_LEVEL_ARCHS" != *arm64* || "$TOP_LEVEL_ARCHS" != *x86_64* ]]; then
  echo "Expected a universal WebRTC binary, found: $TOP_LEVEL_ARCHS" >&2
  exit 1
fi
cp "$TOP_LEVEL_BINARY" "$VERSIONED_BINARY"
rm "$TOP_LEVEL_BINARY"
ln -s "Versions/Current/WebRTC" "$TOP_LEVEL_BINARY"

VERSIONED_ARCHS="$(lipo -archs "$VERSIONED_BINARY")"
if [[ "$VERSIONED_ARCHS" != *arm64* || "$VERSIONED_ARCHS" != *x86_64* ]]; then
  echo "Canonical WebRTC binary is not universal: $VERSIONED_ARCHS" >&2
  exit 1
fi

echo "WebRTC XCFramework ready at $FRAMEWORK"
