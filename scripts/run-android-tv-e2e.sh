#!/bin/zsh
set -euo pipefail
setopt extendedglob

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PROFILE="direct-baseline"
SOURCE="main"
RUNTIME_CONFIG="${RUNTIME_CONFIG:-}"
RUN_SECONDS=20
OUTPUT_ROOT="$ROOT/artifacts/android-tv-e2e"
MEDIA_BASELINE=0
SKIP_MACOS_BUILD=0
STATIC_QP_EVIDENCE=0
PACKAGE="cn.aweffr.webrtcscreencast.tv"
ACTIVITY="$PACKAGE/.ui.ReceiverActivity"
AVD_NAME="${ANDROID_TV_AVD_NAME:-WebRTCScreencast_TV_API_31}"
LOCAL_XML="$ROOT/apps/android-tv/app/src/debug/res/values/reference_runtime.local.xml"

usage() {
  print -u2 "usage: $0 [--profile direct-baseline|production-relay] [--source main|virtual] [--runtime-config path] [--run-seconds n] [--output-root path] [--media-baseline] [--static-qp-evidence] [--skip-macos-build]"
  exit 2
}

while (( $# )); do
  case "$1" in
    --profile) [[ $# -ge 2 ]] || usage; PROFILE="$2"; shift 2 ;;
    --source) [[ $# -ge 2 ]] || usage; SOURCE="$2"; shift 2 ;;
    --runtime-config) [[ $# -ge 2 ]] || usage; RUNTIME_CONFIG="$2"; shift 2 ;;
    --run-seconds) [[ $# -ge 2 ]] || usage; RUN_SECONDS="$2"; shift 2 ;;
    --output-root) [[ $# -ge 2 ]] || usage; OUTPUT_ROOT="$2"; shift 2 ;;
    --media-baseline) MEDIA_BASELINE=1; shift ;;
    --static-qp-evidence) STATIC_QP_EVIDENCE=1; shift ;;
    --skip-macos-build) SKIP_MACOS_BUILD=1; shift ;;
    *) usage ;;
  esac
done

[[ "$PROFILE" == direct-baseline || "$PROFILE" == production-relay ]] || usage
[[ "$SOURCE" == main || "$SOURCE" == virtual ]] || usage
[[ "$RUN_SECONDS" == <-> && "$RUN_SECONDS" -ge 10 ]] || {
  print -u2 "--run-seconds must be an integer >= 10"
  exit 2
}
(( ! MEDIA_BASELINE )) || [[ "$SOURCE" == virtual ]] || {
  print -u2 "--media-baseline requires --source virtual"
  exit 2
}
if [[ "$PROFILE" == production-relay ]]; then
  [[ -n "$RUNTIME_CONFIG" && -r "$RUNTIME_CONFIG" ]] || {
    print -u2 "production-relay requires a readable --runtime-config"
    exit 2
  }
  jq -e '.turn.url | startswith("turn:") and contains("transport=udp")' \
    "$RUNTIME_CONFIG" >/dev/null
  jq -e '.turn.username | type == "string" and length > 0' "$RUNTIME_CONFIG" >/dev/null
  jq -e '.turn.password | type == "string" and length > 0' "$RUNTIME_CONFIG" >/dev/null
fi
for tool in adb curl jq python3; do
  command -v "$tool" >/dev/null || { print -u2 "$tool is required"; exit 2; }
done
if (( STATIC_QP_EVIDENCE )); then
  [[ "$SOURCE" == main ]] || {
    print -u2 "--static-qp-evidence requires --source main"
    exit 2
  }
  command -v screencapture >/dev/null || {
    print -u2 "screencapture is required"
    exit 2
  }
fi

mkdir -p "$OUTPUT_ROOT"
OUTPUT_ROOT="$(cd "$OUTPUT_ROOT" && pwd -P)"
RUN_ROOT="$(mktemp -d "$OUTPUT_ROOT/run.XXXXXX")"
MACOS_METRICS="$RUN_ROOT/macos"
ANDROID_EVIDENCE="$RUN_ROOT/android"
CONFIG_FILE="$RUN_ROOT/runtime.json"
SERVER_BINARY="$RUN_ROOT/signaling-server"
mkdir -p "$MACOS_METRICS" "$ANDROID_EVIDENCE" "${LOCAL_XML:h}"
chmod 700 "$RUN_ROOT" "$MACOS_METRICS" "$ANDROID_EVIDENCE"

server_pid=""
sender_pid=""
caffeinate_pid=""
started_emulator=0
pairing_code=""
fresh_code=""
local_xml_backup=""
local_xml_restore_needed=0

restore_local_xml() {
  (( local_xml_restore_needed )) || return 0
  if [[ -n "$local_xml_backup" && -f "$local_xml_backup" ]]; then
    mv -f "$local_xml_backup" "$LOCAL_XML" || return 1
  else
    rm -f "$LOCAL_XML" || return 1
  fi
  local_xml_restore_needed=0
}

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM
  [[ -n "$sender_pid" ]] && kill "$sender_pid" >/dev/null 2>&1 || true
  [[ -n "$server_pid" ]] && kill "$server_pid" >/dev/null 2>&1 || true
  [[ -n "$caffeinate_pid" ]] && kill "$caffeinate_pid" >/dev/null 2>&1 || true
  adb shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
  rm -f "$CONFIG_FILE"
  restore_local_xml || exit_code=1
  for code in "$pairing_code" "$fresh_code"; do
    if [[ ${#code} -eq 8 ]] && LC_ALL=C grep -R -a -F -q -- "$code" "$RUN_ROOT"; then
      print -u2 "retained evidence contains a full pairing code"
      exit_code=1
    fi
  done
  if [[ "$PROFILE" == production-relay && -r "$RUNTIME_CONFIG" ]]; then
    "$ROOT/scripts/scan-artifacts-for-configured-secrets.sh" \
      --config "$RUNTIME_CONFIG" "$RUN_ROOT" >/dev/null || exit_code=1
  fi
  if (( started_emulator )); then
    adb emu kill >/dev/null 2>&1 || true
    for _ in {1..300}; do
      adb get-state >/dev/null 2>&1 || break
      sleep 0.1
    done
  fi
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$ROOT/scripts/check-virtual-display-state.py" --expect 0
command -v caffeinate >/dev/null || { print -u2 "caffeinate is required"; exit 2; }
caffeinate -di -w $$ >/dev/null 2>&1 &
caffeinate_pid=$!
"$ROOT/scripts/provision-android-tv-avd.sh" >/dev/null
if ! adb get-state >/dev/null 2>&1; then
  emulator "@$AVD_NAME" -no-window -no-audio -no-boot-anim -no-snapshot-save \
    -gpu swiftshader_indirect >"$RUN_ROOT/emulator.log" 2>&1 &
  started_emulator=1
  adb wait-for-device
fi
for _ in {1..60}; do
  [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] && break
  sleep 1
done
[[ "$(adb shell getprop sys.boot_completed | tr -d '\r')" == 1 ]] || {
  print -u2 "Android TV emulator did not finish booting"
  exit 1
}
[[ "$(adb shell getprop ro.build.version.sdk | tr -d '\r')" == 31 ]] || {
  print -u2 "Android TV E2E requires API 31"
  exit 1
}
[[ "$(adb shell getprop ro.product.cpu.abi | tr -d '\r')" == arm64-v8a ]] || {
  print -u2 "Android TV E2E requires arm64-v8a"
  exit 1
}
adb shell wm size | grep -Fq 1920x1080 || {
  print -u2 "Android TV E2E requires a 1920x1080 display"
  exit 1
}
adb shell getprop ro.boot.qemu.avd_name | tr -d '\r' | grep -Fxq "$AVD_NAME" || {
  print -u2 "connected emulator is not $AVD_NAME"
  exit 1
}
"$ROOT/scripts/ensure-android-tv-network.sh" >/dev/null

PORT="$(python3 - <<'PY'
import socket
with socket.socket() as server:
    server.bind(("127.0.0.1", 0))
    print(server.getsockname()[1])
PY
)"
SIGNALING_MAC="ws://127.0.0.1:$PORT/ws"
SIGNALING_ANDROID="ws://10.0.2.2:$PORT/ws"

if [[ -L "$LOCAL_XML" || ( -e "$LOCAL_XML" && ! -f "$LOCAL_XML" ) ]]; then
  print -u2 "$LOCAL_XML must be a regular file when present"
  exit 1
fi
if [[ -f "$LOCAL_XML" ]]; then
  local_xml_backup="$RUN_ROOT/reference-runtime-local.backup.xml"
  cp -p "$LOCAL_XML" "$local_xml_backup"
fi
local_xml_restore_needed=1
python3 - "$PROFILE" "$SIGNALING_ANDROID" "$RUNTIME_CONFIG" "$LOCAL_XML" <<'PY'
import json
import pathlib
import sys
from xml.sax.saxutils import escape

profile, signaling, runtime_path, output = sys.argv[1:]
turn = {
    "url": "turn:turn.example.invalid:3478?transport=udp",
    "username": "REPLACE_ME",
    "password": "REPLACE_ME",
}
if profile == "production-relay":
    turn = json.loads(pathlib.Path(runtime_path).read_text(encoding="utf-8"))["turn"]
values = {
    "reference_signaling_url": signaling,
    "reference_turn_url": turn["url"],
    "reference_turn_username": turn["username"],
    "reference_turn_password": turn["password"],
}
lines = ['<?xml version="1.0" encoding="utf-8"?>', "<resources>"]
for name, value in values.items():
    lines.append(
        f'    <string name="{name}" translatable="false">{escape(value)}</string>')
lines.append("</resources>")
pathlib.Path(output).write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
chmod 600 "$LOCAL_XML"

if [[ "$PROFILE" == production-relay ]]; then
  jq --arg signaling "$SIGNALING_MAC" --arg metrics "$MACOS_METRICS" '
    .signaling_url = $signaling
    | .ice_profile = "production-relay"
    | .metrics_directory = $metrics
    | .excluded_receiver_pid = null
  ' "$RUNTIME_CONFIG" >"$CONFIG_FILE"
  GRADLE_TASK=:app:assembleProductionRelayDebug
  APK="$ROOT/apps/android-tv/app/build/outputs/apk/productionRelay/debug/app-productionRelay-debug.apk"
else
  jq -n --arg signaling "$SIGNALING_MAC" --arg metrics "$MACOS_METRICS" '{
    signaling_url:$signaling,
    ice_profile:"direct-baseline",
    turn:null,
    metrics_directory:$metrics,
    excluded_receiver_pid:null
  }' >"$CONFIG_FILE"
  GRADLE_TASK=:app:assembleDirectBaselineDebug
  APK="$ROOT/apps/android-tv/app/build/outputs/apk/directBaseline/debug/app-directBaseline-debug.apk"
fi
chmod 600 "$CONFIG_FILE"

if (( ! SKIP_MACOS_BUILD )); then
  make -C "$ROOT" build-macos
fi
WEBRTC_ANDROID_AAR="${ARTIFACTS_DIR:-$ROOT/artifacts}/webrtc-m150-android-arm64-v8a.aar"
[[ -f "$WEBRTC_ANDROID_AAR" ]] || {
  print -u2 "verified Android WebRTC AAR is missing: $WEBRTC_ANDROID_AAR"
  exit 1
}
WEBRTC_ANDROID_AAR="$WEBRTC_ANDROID_AAR" \
  "$ROOT/apps/android-tv/gradlew" -p "$ROOT/apps/android-tv" "$GRADLE_TASK"
restore_local_xml
APP_EXECUTABLE="$ROOT/DerivedData/Build/Products/Debug/WebRTCScreencast.app/Contents/MacOS/WebRTCScreencast"
[[ -x "$APP_EXECUTABLE" && -f "$APK" ]] || {
  print -u2 "macOS app or Android TV APK is missing"
  exit 1
}

(cd "$ROOT/server" && go build -o "$SERVER_BINARY" ./cmd/signaling-server)
LISTEN_ADDR="127.0.0.1:$PORT" "$SERVER_BINARY" >"$RUN_ROOT/signaling.log" 2>&1 &
server_pid=$!
for _ in {1..100}; do
  curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
  kill -0 "$server_pid" 2>/dev/null || {
    print -u2 "signaling server exited before health check"
    exit 1
  }
  sleep 0.1
done
curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null

adb install -r "$APK" >/dev/null
adb shell pm clear "$PACKAGE" >/dev/null
adb shell am start -n "$ACTIVITY" --ez baseline_mode "$([[ $MEDIA_BASELINE == 1 ]] && print true || print false)" >/dev/null

automation_path=files/automation/automation.jsonl
for _ in {1..300}; do
  automation_record="$(adb exec-out run-as "$PACKAGE" cat "$automation_path" 2>/dev/null || true)"
  pairing_code="$(print -r -- "$automation_record" | jq -r \
    'select(.event == "receiver_registered") | .pairing_code // empty' 2>/dev/null || true)"
  [[ "$pairing_code" == [0-9A-HJKMNPQRSTVWXYZ]## ]] && break
  sleep 0.1
done
[[ "$pairing_code" == [0-9A-HJKMNPQRSTVWXYZ]## && ${#pairing_code} -eq 8 ]] || {
  print -u2 "Android TV receiver did not publish a valid app-private pairing code"
  exit 1
}
adb shell run-as "$PACKAGE" rm -f "$automation_path"
adb exec-out screencap -p >"$ANDROID_EVIDENCE/receiver-waiting.png"

typeset -a sender_args
sender_args=(
  --role sender
  --profile "$PROFILE"
  --config "$CONFIG_FILE"
  --pairing-code "$pairing_code"
  --source "$SOURCE"
  --run-seconds "$RUN_SECONDS"
)
(( MEDIA_BASELINE )) && sender_args+=(--media-baseline)
"$APP_EXECUTABLE" "${sender_args[@]}" >"$RUN_ROOT/sender.log" 2>&1 &
sender_pid=$!

sender_directory=""
remote_evidence=""
connected=0
for _ in {1..600}; do
  sender_directory="$(find "$MACOS_METRICS" -mindepth 1 -maxdepth 1 -type d -name '*-sender' -print -quit)"
  remote_evidence="$(
    adb shell run-as "$PACKAGE" find files/evidence -name receiver.jsonl \
      -type f -maxdepth 3 -print 2>/dev/null | tr -d '\r' | head -1
  )"
  receiver_snapshot=""
  if [[ -n "$remote_evidence" ]]; then
    receiver_snapshot="$(
      adb exec-out run-as "$PACKAGE" cat "$remote_evidence" 2>/dev/null || true
    )"
  fi
  if [[ -n "$sender_directory" && -s "$sender_directory/metrics.jsonl" \
      && -n "$remote_evidence" ]] \
      && grep -Fq '"event":"selected_path"' "$sender_directory/metrics.jsonl" \
      && [[ "$receiver_snapshot" == *'"event":"remote_video_playing"'* ]] \
      && [[ "$receiver_snapshot" == *'"path_status":"accepted"'* ]] \
      && [[ "$receiver_snapshot" =~ '"frames_decoded":[1-9][0-9]*' ]]; then
    connected=1
    break
  fi
  kill -0 "$sender_pid" 2>/dev/null || break
  sleep 0.1
done
(( connected )) || {
  print -u2 "cross-platform media/path evidence did not become ready"
  exit 1
}
if (( STATIC_QP_EVIDENCE )); then
  static_max_qp="$(jq -er '.static_max_qp | numbers' "$CONFIG_FILE")"
  static_qp_ready=0
  for _ in {1..200}; do
    if jq -s -e --argjson max_qp "$static_max_qp" '
      [ .[]
        | select(.event == "rtc_stats")
        | .fields.sender_media_boundary
        | select(
            .clarity_mode == "static_clarity" and
            .requested_max_qp == $max_qp and
            .effective_max_qp == $max_qp and
            .max_qp_apply_state == "applied" and
            .last_key_frame_qp != null and
            .last_key_frame_qp <= $max_qp and
            .last_key_frame_bytes > 0
          )
      ] | length > 0
    ' "$sender_directory/metrics.jsonl" >/dev/null 2>&1; then
      static_qp_ready=1
      break
    fi
    kill -0 "$sender_pid" 2>/dev/null || break
    sleep 0.1
  done
  (( static_qp_ready )) || {
    print -u2 "static max-QP evidence did not become ready"
    exit 1
  }
  sleep 0.5
  screencapture -x "$RUN_ROOT/macos-main-source.png"
fi
adb exec-out screencap -p >"$ANDROID_EVIDENCE/receiver-playing.png"

set +e
wait "$sender_pid"
sender_status=$?
set -e
sender_pid=""
[[ "$sender_status" -eq 0 ]] || { print -u2 "macOS Sender exited with $sender_status"; exit 1; }

for _ in {1..300}; do
  automation_record="$(adb exec-out run-as "$PACKAGE" cat "$automation_path" 2>/dev/null || true)"
  fresh_code="$(print -r -- "$automation_record" | jq -r \
    'select(.event == "receiver_registered") | .pairing_code // empty' 2>/dev/null || true)"
  [[ ${#fresh_code} -eq 8 && "$fresh_code" != "$pairing_code" ]] && break
  sleep 0.1
done
[[ ${#fresh_code} -eq 8 && "$fresh_code" != "$pairing_code" ]] || {
  print -u2 "Android TV receiver did not recover to a fresh pairing code"
  exit 1
}
adb shell run-as "$PACKAGE" rm -f "$automation_path"

"$ROOT/scripts/pull-android-tv-evidence.sh" --output-dir "$ANDROID_EVIDENCE" >/dev/null
curl -fsS "http://127.0.0.1:$PORT/metrics" >"$RUN_ROOT/signaling-metrics.txt"
"$ROOT/scripts/verify-diagnostics.sh" \
  "$ANDROID_EVIDENCE" "$sender_directory" "$PROFILE" "$CONFIG_FILE"
rm -f "$CONFIG_FILE"

if (( MEDIA_BASELINE )); then
  if (( RUN_SECONDS >= 75 )); then
    analysis_duration=60
  else
    analysis_duration=$(( RUN_SECONDS - 11 ))
  fi
  typeset -a analysis_args
  analysis_args=(
    --sender-dir "$sender_directory"
    --receiver-dir "$ANDROID_EVIDENCE"
    --profile "$PROFILE"
    --output "$RUN_ROOT/android-tv-baseline-report.json"
    --warmup-seconds 10
    --duration-seconds "$analysis_duration"
  )
  [[ "$PROFILE" == production-relay ]] && analysis_args+=(--runtime-config "$RUNTIME_CONFIG")
  (( RUN_SECONDS < 75 )) && analysis_args+=(--skip-images)
  "$ROOT/scripts/analyze-android-tv-baseline.py" "${analysis_args[@]}"
fi

jq -n \
  --arg recorded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg git_commit "$(git -C "$ROOT" rev-parse HEAD)" \
  --arg profile "$PROFILE" \
  --arg source "$SOURCE" \
  --arg avd "$AVD_NAME" \
  --arg api "$(adb shell getprop ro.build.version.sdk | tr -d '\r')" \
  --arg abi "$(adb shell getprop ro.product.cpu.abi | tr -d '\r')" \
  --arg display "$(adb shell wm size | tr -d '\r')" \
  '{recorded_at:$recorded_at,git_commit:$git_commit,profile:$profile,source:$source,android:{avd:$avd,api:$api,abi:$abi,display:$display}}' \
  >"$RUN_ROOT/context.json"

if LC_ALL=C grep -R -a -F -q -- "$pairing_code" "$RUN_ROOT" \
    || LC_ALL=C grep -R -a -F -q -- "$fresh_code" "$RUN_ROOT"; then
  print -u2 "retained evidence contains a full pairing code"
  exit 1
fi
if [[ "$PROFILE" == production-relay ]]; then
  "$ROOT/scripts/scan-artifacts-for-configured-secrets.sh" \
    --config "$RUNTIME_CONFIG" "$RUN_ROOT" >/dev/null
fi
pairing_code=""
fresh_code=""
"$ROOT/scripts/check-virtual-display-state.py" --expect 0
print "Android TV E2E artifacts: $RUN_ROOT"
