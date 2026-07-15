#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
AVD_NAME="${ANDROID_TV_AVD_NAME:-WebRTCScreencast_TV_API_31}"
PACKAGE="cn.aweffr.webrtcscreencast.tv"
ACTIVITY="$PACKAGE/.ui.ReceiverActivity"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/diagnostics/android-tv-smoke}"
APK="$ROOT/apps/android-tv/app/build/outputs/apk/directBaseline/debug/app-directBaseline-debug.apk"
EMULATOR_LOG="$OUTPUT_DIR/emulator.log"
SERVER_LOG="$OUTPUT_DIR/signaling-server.log"
started_emulator=0
started_server=0

mkdir -p "$OUTPUT_DIR"

cleanup() {
  local exit_code=$?
  adb shell rm -f /sdcard/webrtc-tv-window.xml >/dev/null 2>&1 || true
  if (( started_server )); then
    kill "$server_pid" >/dev/null 2>&1 || true
  fi
  if (( started_emulator )); then
    adb emu kill >/dev/null 2>&1 || true
  fi
  return "$exit_code"
}
trap cleanup EXIT INT TERM

"$ROOT/scripts/provision-android-tv-avd.sh"

if ! adb get-state >/dev/null 2>&1; then
  emulator "@$AVD_NAME" \
    -no-window -no-audio -no-boot-anim -no-snapshot-save \
    -gpu swiftshader_indirect >"$EMULATOR_LOG" 2>&1 &
  started_emulator=1
  adb wait-for-device
fi

for attempt in {1..45}; do
  [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]] && break
  sleep 1
done

[[ "$(adb shell getprop sys.boot_completed | tr -d '\r')" == "1" ]] || {
  print -u2 "Android TV emulator did not finish booting"
  exit 1
}
[[ "$(adb shell getprop ro.build.version.sdk | tr -d '\r')" == "31" ]] || {
  print -u2 "Expected Android API 31"
  exit 1
}
[[ "$(adb shell getprop ro.product.cpu.abi | tr -d '\r')" == "arm64-v8a" ]] || {
  print -u2 "Expected arm64-v8a emulator"
  exit 1
}
adb shell wm size | grep -Fq '1920x1080' || {
  print -u2 "Expected a 1920x1080 Android TV display"
  exit 1
}
adb shell getprop ro.boot.qemu.avd_name | tr -d '\r' | grep -Fxq "$AVD_NAME" || {
  print -u2 "Connected emulator is not $AVD_NAME"
  exit 1
}

if ! curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
  "$ROOT/scripts/run-local-signaling.sh" >"$SERVER_LOG" 2>&1 &
  server_pid=$!
  started_server=1
  for attempt in {1..30}; do
    curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1 && break
    sleep 1
  done
fi
curl -fsS http://127.0.0.1:8080/healthz >/dev/null

"$ROOT/apps/android-tv/gradlew" -p "$ROOT/apps/android-tv" \
  :app:assembleDirectBaselineDebug
adb install -r "$APK" >/dev/null
adb shell pm clear "$PACKAGE" >/dev/null
adb shell am start -n "$ACTIVITY" >/dev/null

evidence_path=""
for attempt in {1..30}; do
  evidence_path="$(
    (adb shell run-as "$PACKAGE" find files/evidence \
      -name receiver.jsonl -type f -maxdepth 3 -print 2>/dev/null || true) \
      | tr -d '\r' \
      | head -1
  )"
  if [[ -n "$evidence_path" ]] \
      && adb shell run-as "$PACKAGE" grep -Fq receiver_runtime_initialized "$evidence_path" \
      && adb shell run-as "$PACKAGE" grep -Fq receiver_registered "$evidence_path"; then
    break
  fi
  sleep 1
done

[[ -n "$evidence_path" ]] || {
  print -u2 "Receiver evidence was not created"
  exit 1
}
adb shell run-as "$PACKAGE" grep -Fq receiver_runtime_initialized "$evidence_path"
adb shell run-as "$PACKAGE" grep -Fq receiver_registered "$evidence_path"
adb exec-out run-as "$PACKAGE" cat "$evidence_path" >"$OUTPUT_DIR/receiver.jsonl"

adb shell uiautomator dump /sdcard/webrtc-tv-window.xml >/dev/null
adb shell cat /sdcard/webrtc-tv-window.xml \
  | grep -Eq 'text="[0-9A-HJKMNPQRSTVWXYZ]{4} [0-9A-HJKMNPQRSTVWXYZ]{4}"' || {
    print -u2 "Pairing code is not visible in the Android TV UI"
    exit 1
  }
adb exec-out screencap -p >"$OUTPUT_DIR/receiver-waiting.png"

print "Android TV smoke passed"
print "Evidence: $OUTPUT_DIR/receiver.jsonl"
print "Screenshot: $OUTPUT_DIR/receiver-waiting.png"
