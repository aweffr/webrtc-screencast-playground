#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RUNTIME_CONFIG=""
D0_APP="$ROOT/artifacts/damage-idle/apps/D0-WebRTCScreencast.app"
OUTPUT_ROOT="$ROOT/artifacts/damage-idle/experiments"
EXPERIMENT_ROOT=""
STAGE="h264"
DOCUMENT_PORT=18766
CHROME_VERSION="150.0.7871.129"
ALLOW_H264_GATE_WAIVER=false

usage() {
  print -u2 "usage: $0 --runtime-config path [--d0-app path] [--stage h264|h265] [--allow-h264-gate-waiver] [--experiment-root path] [--output-root path] [--document-port n]"
  exit 2
}

while (( $# )); do
  case "$1" in
    --runtime-config) [[ $# -ge 2 ]] || usage; RUNTIME_CONFIG="$2"; shift 2 ;;
    --d0-app) [[ $# -ge 2 ]] || usage; D0_APP="$2"; shift 2 ;;
    --stage) [[ $# -ge 2 ]] || usage; STAGE="$2"; shift 2 ;;
    --allow-h264-gate-waiver) ALLOW_H264_GATE_WAIVER=true; shift ;;
    --experiment-root) [[ $# -ge 2 ]] || usage; EXPERIMENT_ROOT="$2"; shift 2 ;;
    --output-root) [[ $# -ge 2 ]] || usage; OUTPUT_ROOT="$2"; shift 2 ;;
    --document-port) [[ $# -ge 2 ]] || usage; DOCUMENT_PORT="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$STAGE" == h264 || "$STAGE" == h265 ]] || usage
[[ -r "$RUNTIME_CONFIG" ]] || usage
[[ -x "$D0_APP/Contents/MacOS/WebRTCScreencast" ]] || usage
[[ "$DOCUMENT_PORT" == <-> && "$DOCUMENT_PORT" -ge 1024 && "$DOCUMENT_PORT" -le 65535 ]] || usage
for tool in adb jq playwright-cli python3 shasum; do
  command -v "$tool" >/dev/null || { print -u2 "$tool is required"; exit 2; }
done
if ioreg -n Root -d1 | grep -Eq '"(CGSSessionScreenIsLocked|IOConsoleLocked)" = (Yes|true)'; then
  print -u2 "macOS console is locked; unlock it before running visual evidence"
  exit 2
fi
jq -e '.turn.url | startswith("turn:") and contains("transport=udp")' "$RUNTIME_CONFIG" >/dev/null
jq -e '.turn.username and .turn.password' "$RUNTIME_CONFIG" >/dev/null

mkdir -p "$OUTPUT_ROOT"
OUTPUT_ROOT="$(cd "$OUTPUT_ROOT" && pwd -P)"
if [[ -z "$EXPERIMENT_ROOT" ]]; then
  EXPERIMENT_ROOT="$OUTPUT_ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$EXPERIMENT_ROOT"
else
  mkdir -p "$EXPERIMENT_ROOT"
  EXPERIMENT_ROOT="$(cd "$EXPERIMENT_ROOT" && pwd -P)"
fi
if [[ "$STAGE" == h265 ]]; then
  [[ -r "$EXPERIMENT_ROOT/head-to-head-report.json" ]] \
    && { [[ "$ALLOW_H264_GATE_WAIVER" == true ]] \
      || jq -e '.eligible == true' "$EXPERIMENT_ROOT/head-to-head-report.json" >/dev/null; } || {
      print -u2 "H.264 head-to-head report does not authorize H.265 smoke"
      exit 2
    }
fi

make -C "$ROOT" build-macos
D1_APP="$ROOT/DerivedData/Build/Products/Debug/WebRTCScreencast.app"
[[ -x "$D1_APP/Contents/MacOS/WebRTCScreencast" ]] || {
  print -u2 "D1 app build is missing"
  exit 1
}
mkdir -p "$EXPERIMENT_ROOT/apps"
if [[ ! -d "$EXPERIMENT_ROOT/apps/D1-WebRTCScreencast.app" ]]; then
  ditto "$D1_APP" "$EXPERIMENT_ROOT/apps/D1-WebRTCScreencast.app"
fi
D1_APP="$EXPERIMENT_ROOT/apps/D1-WebRTCScreencast.app"

http_pid=""
workload_pid=""
watcher_pid=""
workload_session=""
cleanup() {
  exit_code=$?
  [[ -n "$watcher_pid" ]] && kill "$watcher_pid" >/dev/null 2>&1 || true
  [[ -n "$workload_pid" ]] && kill "$workload_pid" >/dev/null 2>&1 || true
  [[ -n "$workload_session" ]] && playwright-cli -s="$workload_session" close >/dev/null 2>&1 || true
  [[ -n "$http_pid" ]] && kill "$http_pid" >/dev/null 2>&1 || true
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

python3 -m http.server "$DOCUMENT_PORT" --bind 127.0.0.1 \
  --directory "$ROOT/experiments/hevc-meeting" \
  >"$EXPERIMENT_ROOT/document-server.log" 2>&1 &
http_pid=$!
for _ in {1..50}; do
  curl -fsS "http://127.0.0.1:$DOCUMENT_PORT/document.html" >/dev/null 2>&1 && break
  kill -0 "$http_pid" 2>/dev/null || { print -u2 "document server exited"; exit 1; }
  sleep 0.1
done
curl -fsS "http://127.0.0.1:$DOCUMENT_PORT/document.html" >/dev/null

if [[ "$STAGE" == h264 ]]; then
  schedule=(D0 D1 D1 D0 D0 D1)
else
  schedule=(H1)
fi
typeset -A repetitions

for case_id in "${schedule[@]}"; do
  repetitions[$case_id]=$(( ${repetitions[$case_id]:-0} + 1 ))
  repetition="${repetitions[$case_id]}"
  run_root="$EXPERIMENT_ROOT/cases/$case_id/run-$repetition"
  [[ ! -e "$run_root/VALID" ]] || continue
  mkdir -p "$run_root"
  case "$case_id" in
    D0) app_bundle="$D0_APP"; codec_policy=h264-only; static_qp=24; active_qp=32 ;;
    D1) app_bundle="$D1_APP"; codec_policy=h264-only; static_qp=24; active_qp=32 ;;
    H1) app_bundle="$D1_APP"; codec_policy=h265-only; static_qp=33; active_qp=39 ;;
  esac

  valid=0
  for attempt in 1 2; do
    attempt_root="$run_root/attempt-$attempt"
    [[ ! -e "$attempt_root" ]] || continue
    mkdir -p "$attempt_root/workload"
    runtime_case="$attempt_root/runtime.json"
    tuning_case="$run_root/cast-tuning.json"
    jq --arg policy "$codec_policy" --argjson qp "$static_qp" '
      .video_codec_policy = $policy | .static_max_qp = $qp
    ' "$RUNTIME_CONFIG" >"$runtime_case"
    jq --arg policy "$codec_policy" --argjson qp "$active_qp" '
      .encoder.max_qp = $qp
      | .encoder.allow_frame_reordering = false
      | .encoder.video_toolbox_low_latency_rate_control = false
      | .encoder.video_toolbox_spatial_adaptive_qp = "DEFAULT"
      | if $policy == "h264-only" then
          .encoder.h264_profile = "CONSTRAINED_BASELINE"
          | .encoder.h264_level = "4.1"
        else
          del(.encoder.h264_profile, .encoder.h264_level)
        end
    ' "$ROOT/config/cast-tuning.default.json" >"$tuning_case"
    chmod 600 "$runtime_case"
    jq -n --arg case_id "$case_id" --arg codec_policy "$codec_policy" \
      --argjson static_qp "$static_qp" --argjson active_qp "$active_qp" \
      '{case_id:$case_id,codec_policy:$codec_policy,static_qp:$static_qp,active_qp:$active_qp}' \
      >"$run_root/policy.json"

    start_file="$attempt_root/media-ready"
    trigger_file="$attempt_root/sender-started"
    fullscreen_file="$attempt_root/fullscreen-ready"
    workload_session="di${case_id:l}${repetition}${attempt}"
    python3 "$ROOT/scripts/damage_idle_workload.py" \
      --url "http://127.0.0.1:$DOCUMENT_PORT/document.html" \
      --output-directory "$attempt_root/workload" \
      --expected-chrome-version "$CHROME_VERSION" \
      --session "$workload_session" \
      --start-file "$start_file" \
      --fullscreen-trigger-file "$trigger_file" \
      --fullscreen-ready-file "$fullscreen_file" \
      >"$attempt_root/workload.log" 2>&1 &
    workload_pid=$!
    sleep 1
    if ! kill -0 "$workload_pid" 2>/dev/null; then
      wait "$workload_pid" || true
      workload_pid=""
      continue
    fi

    (
      while [[ ! -s "$attempt_root/workload/final.png" ]]; do
        sleep 0.1
      done
      adb exec-out screencap -p >"$attempt_root/android-final.png"
    ) &
    watcher_pid=$!

    set +e
    WEBRTC_ANDROID_AAR="$ROOT/artifacts/webrtc-m150-android-arm64-v8a.aar" \
      "$ROOT/scripts/run-android-tv-e2e.sh" \
      --profile production-relay \
      --source main \
      --runtime-config "$runtime_case" \
      --cast-tuning-config "$tuning_case" \
      --run-seconds 100 \
      --output-root "$attempt_root/e2e" \
      --damage-idle-evidence \
      --static-qp-evidence \
      --workload-start-file "$start_file" \
      --workload-fullscreen-trigger-file "$trigger_file" \
      --workload-fullscreen-ready-file "$fullscreen_file" \
      --macos-app-bundle "$app_bundle" \
      >"$attempt_root/e2e.log" 2>&1
    e2e_status=$?
    rm -f "$runtime_case"
    if (( e2e_status != 0 )); then
      kill "$workload_pid" >/dev/null 2>&1 || true
      kill "$watcher_pid" >/dev/null 2>&1 || true
    fi
    wait "$workload_pid"
    workload_status=$?
    if (( workload_status != 0 )); then
      kill "$watcher_pid" >/dev/null 2>&1 || true
    fi
    wait "$watcher_pid"
    watcher_status=$?
    set -e
    workload_pid=""
    watcher_pid=""
    playwright-cli -s="$workload_session" close >/dev/null 2>&1 || true
    workload_session=""

    completed=$(jq -s 'any(.[]; .event == "workload_completed" and .valid == true)' \
      "$attempt_root/workload/workload.jsonl" 2>/dev/null || print false)
    if (( e2e_status == 0 && workload_status == 0 && watcher_status == 0 )) \
        && [[ "$completed" == true ]]; then
      e2e_run=$(find "$attempt_root/e2e" -mindepth 1 -maxdepth 1 -type d -name 'run.*' -print -quit)
      expected_sha=$(shasum -a 256 "$app_bundle/Contents/MacOS/WebRTCScreencast" | awk '{print $1}')
      jq -e --arg sha "$expected_sha" '.build.macos_executable_sha256 == $sha' \
        "$e2e_run/context.json" >/dev/null
      ln -s "attempt-$attempt" "$run_root/valid-attempt"
      print valid >"$run_root/VALID"
      valid=1
      break
    fi
    print -u2 "$case_id run $repetition attempt $attempt invalid"
    if [[ "$completed" == true ]]; then
      print -u2 "completed workload produced invalid media evidence; refusing infrastructure retry"
      exit 1
    fi
  done
  (( valid )) || { print -u2 "$case_id run $repetition exhausted its infrastructure retry"; exit 1; }
done

jq -n \
  --arg stage "$STAGE" \
  --argjson h264_gate_waiver "$ALLOW_H264_GATE_WAIVER" \
  --arg chrome_version "$CHROME_VERSION" \
  --arg d0_sha "$(shasum -a 256 "$D0_APP/Contents/MacOS/WebRTCScreencast" | awk '{print $1}')" \
  --arg d1_sha "$(shasum -a 256 "$D1_APP/Contents/MacOS/WebRTCScreencast" | awk '{print $1}')" \
  '{stage:$stage,h264_gate_waiver:$h264_gate_waiver,chrome_version:$chrome_version,d0_executable_sha256:$d0_sha,d1_executable_sha256:$d1_sha}' \
  >"$EXPERIMENT_ROOT/$STAGE-context.json"
print "$EXPERIMENT_ROOT"
