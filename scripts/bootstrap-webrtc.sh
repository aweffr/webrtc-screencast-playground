#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT/artifacts}"
VENDOR_DIR="${VENDOR_DIR:-$ROOT/Vendor}"
WEBRTC_RELEASE_BASE_URL="${WEBRTC_RELEASE_BASE_URL:-https://github.com/aweffr/my-webrtc-builds/releases/download/webrtc-m150.7871.3-0ff0e8c-20260714-macos-android-preview.1}"
ARCHIVE="${WEBRTC_XCFRAMEWORK_ZIP:-$ARTIFACTS_DIR/WebRTC-m150-macos-universal.xcframework.zip}"
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

if [[ -n "${WEBRTC_XCFRAMEWORK_ZIP:-}" ]]; then
  [[ -f "$ARCHIVE" ]] || {
    print -u2 "WEBRTC_XCFRAMEWORK_ZIP is not a readable file: $ARCHIVE"
    exit 1
  }
else
  download_if_missing "$ARCHIVE"
fi
download_if_missing "$AAR"

cd "$ARTIFACTS_DIR"
if [[ -n "${WEBRTC_XCFRAMEWORK_ZIP:-}" ]]; then
  grep -F "  ${AAR:t}" SHA256SUMS | shasum -a 256 -c -
else
  shasum -a 256 -c SHA256SUMS
fi

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

framework_slices=("$FRAMEWORK"/macos-*/WebRTC.framework(N/))
if [[ ${#framework_slices} -ne 1 ]]; then
  print -u2 "Expected exactly one macOS WebRTC.framework slice"
  exit 1
fi
FRAMEWORK_ROOT="${framework_slices[1]}"
TOP_LEVEL_BINARY="$FRAMEWORK_ROOT/WebRTC"
VERSIONED_BINARY="$FRAMEWORK_ROOT/Versions/A/WebRTC"

# The published universal archive contains the correct fat binary at the
# framework root, but a stale x86_64-only binary under Versions/A. A versioned
# macOS framework loads Versions/A/WebRTC at runtime, so canonicalize the
# extracted copy and keep the downloaded archive immutable.
TOP_LEVEL_ARCHS="$(lipo -archs "$TOP_LEVEL_BINARY")"
if [[ "$TOP_LEVEL_ARCHS" != *arm64* ]]; then
  echo "Expected an arm64 WebRTC binary, found: $TOP_LEVEL_ARCHS" >&2
  exit 1
fi
if [[ "$TOP_LEVEL_ARCHS" == *x86_64* ]]; then
  if [[ ! -L "$TOP_LEVEL_BINARY" ]]; then
    cp "$TOP_LEVEL_BINARY" "$VERSIONED_BINARY"
    rm "$TOP_LEVEL_BINARY"
    ln -s "Versions/Current/WebRTC" "$TOP_LEVEL_BINARY"
  fi
elif [[ -z "${WEBRTC_XCFRAMEWORK_ZIP:-}" ]]; then
  echo "Published WebRTC XCFramework must be universal: $TOP_LEVEL_ARCHS" >&2
  exit 1
fi

VERSIONED_ARCHS="$(lipo -archs "$VERSIONED_BINARY")"
if [[ "$VERSIONED_ARCHS" != *arm64* || \
      ("$TOP_LEVEL_ARCHS" == *x86_64* && "$VERSIONED_ARCHS" != *x86_64*) ]]; then
  echo "Canonical WebRTC binary has unexpected architectures: $VERSIONED_ARCHS" >&2
  exit 1
fi

echo "WebRTC XCFramework ready at $FRAMEWORK"
