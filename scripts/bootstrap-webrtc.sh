#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT/artifacts}"
VENDOR_DIR="${VENDOR_DIR:-$ROOT/Vendor}"
WEBRTC_RELEASE_BASE_URL="${WEBRTC_RELEASE_BASE_URL:-https://github.com/aweffr/my-webrtc-builds/releases/download/webrtc-m150.7871.3-0ff0e8c-20260714-macos-android-preview.1}"
ARCHIVE="$ARTIFACTS_DIR/WebRTC-m150-macos-universal.xcframework.zip"
AAR="$ARTIFACTS_DIR/webrtc-m150-android-arm64-v8a.aar"
FRAMEWORK="$VENDOR_DIR/WebRTC.xcframework"

download_if_missing() {
  local destination="$1"
  [[ -f "$destination" ]] && return
  mkdir -p "${destination:h}"
  local temporary="$destination.download.$$"
  if ! curl --fail --location --retry 3 \
      --output "$temporary" \
      "$WEBRTC_RELEASE_BASE_URL/${destination:t}"; then
    rm -f "$temporary"
    return 1
  fi
  mv "$temporary" "$destination"
}

download_if_missing "$ARCHIVE"
download_if_missing "$AAR"

cd "$ARTIFACTS_DIR"
shasum -a 256 -c SHA256SUMS

expected_aar_members="$(print -l \
  AndroidManifest.xml \
  classes.jar \
  jni/arm64-v8a/libjingle_peerconnection_so.so | sort)"
actual_aar_members="$(unzip -Z1 "$AAR" | sort)"
if [[ "$actual_aar_members" != "$expected_aar_members" ]]; then
  print -u2 "Android AAR does not match the app-consumable package contract"
  diff -u <(print -r -- "$expected_aar_members") <(print -r -- "$actual_aar_members") || true
  exit 1
fi

rm -rf "$FRAMEWORK"
mkdir -p "$VENDOR_DIR"
ditto -x -k "$ARCHIVE" "$VENDOR_DIR"
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
