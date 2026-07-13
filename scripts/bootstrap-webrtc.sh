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

echo "WebRTC XCFramework ready at $FRAMEWORK"
