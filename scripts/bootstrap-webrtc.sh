#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT/artifacts}"
VENDOR_DIR="${VENDOR_DIR:-$ROOT/Vendor}"
MACOS_ARCHIVE="${WEBRTC_MACOS_TAR_GZ:-$ARTIFACTS_DIR/webrtc-m150-macos-arm64.tar.gz}"
AAR="${WEBRTC_ANDROID_AAR:-$ARTIFACTS_DIR/webrtc-m150-android-arm64-v8a.aar}"
FRAMEWORK="$VENDOR_DIR/WebRTC.xcframework"

for artifact in "$MACOS_ARCHIVE" "$AAR"; do
  [[ -f "$artifact" ]] || {
    print -u2 "Missing WebRTC artifact: $artifact"
    exit 1
  }
done

for artifact in "$MACOS_ARCHIVE" "$AAR"; do
  artifact_name="${artifact:t}"
  expected_sha256="$(awk -v name="$artifact_name" '$2 == name { print $1 }' "$ARTIFACTS_DIR/SHA256SUMS")"
  actual_sha256="$(shasum -a 256 "$artifact" | awk '{ print $1 }')"
  [[ -n "$expected_sha256" && "$actual_sha256" == "$expected_sha256" ]] || {
    print -u2 "WebRTC artifact checksum mismatch: $artifact_name"
    exit 1
  }
done

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

stage="$(mktemp -d "${TMPDIR:-/tmp}/webrtc-bootstrap.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
tar -xzf "$MACOS_ARCHIVE" -C "$stage"
source_framework="$stage/webrtc/Frameworks/WebRTC.framework"
source_binary="$source_framework/Versions/A/WebRTC"
[[ -f "$source_binary" ]] || {
  print -u2 "macOS archive is missing WebRTC.framework"
  exit 1
}
[[ "$(lipo -archs "$source_binary")" == "arm64" ]] || {
  print -u2 "macOS WebRTC framework must contain exactly arm64"
  exit 1
}

xcodebuild -create-xcframework \
  -framework "$source_framework" \
  -output "$stage/WebRTC.xcframework" >/dev/null
rm -rf "$FRAMEWORK"
mkdir -p "$VENDOR_DIR"
ditto "$stage/WebRTC.xcframework" "$FRAMEWORK"

print "WebRTC artifacts ready: $FRAMEWORK and $AAR"
