#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RUNTIME_CONFIG="${RUNTIME_CONFIG:-}"
ROUNDS=3
RUN_SECONDS=90

usage() {
  print -u2 "usage: $0 --runtime-config path [--rounds n] [--run-seconds n]"
  exit 2
}

while (( $# )); do
  case "$1" in
    --runtime-config) [[ $# -ge 2 ]] || usage; RUNTIME_CONFIG="$2"; shift 2 ;;
    --rounds) [[ $# -ge 2 ]] || usage; ROUNDS="$2"; shift 2 ;;
    --run-seconds) [[ $# -ge 2 ]] || usage; RUN_SECONDS="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -r "$RUNTIME_CONFIG" ]] || { print -u2 "readable TURN runtime config is required"; exit 2; }
[[ "$ROUNDS" == <-> && "$ROUNDS" -ge 1 ]] || usage
[[ "$RUN_SECONDS" == <-> && "$RUN_SECONDS" -ge 85 ]] || { print -u2 "--run-seconds must be >= 85 to preserve the post-path 10s warm-up and 60s measurement window"; exit 2; }
for tool in ffmpeg jq python3; do command -v "$tool" >/dev/null || { print -u2 "$tool is required"; exit 2; }; done
[[ "$(ffmpeg -hide_banner -filters 2>/dev/null)" == *libvmaf* ]] || { print -u2 "ffmpeg libvmaf filter is required"; exit 2; }
"$ROOT/scripts/check-virtual-display-state.py" --expect 0

make -C "$ROOT" build-macos
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(git -C "$ROOT" rev-parse --short HEAD)"
artifact_root="$ROOT/artifacts/media-baseline/$run_id"
mkdir -p "$artifact_root"
chmod 700 "$artifact_root"
versioned_json=""
versioned_markdown=""

scan_complete_outputs() {
  typeset -a scan_targets
  scan_targets=("$artifact_root")
  [[ -n "$versioned_json" && -f "$versioned_json" ]] && scan_targets+=("$versioned_json")
  [[ -n "$versioned_markdown" && -f "$versioned_markdown" ]] && scan_targets+=("$versioned_markdown")
  "$ROOT/scripts/scan-artifacts-for-configured-secrets.sh" \
    --config "$RUNTIME_CONFIG" "${scan_targets[@]}"
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if ! scan_complete_outputs >/dev/null; then
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

jq -n \
  --arg recorded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg git_commit "$(git -C "$ROOT" rev-parse HEAD)" \
  --arg git_dirty "$([[ -n "$(git -C "$ROOT" status --porcelain)" ]] && print true || print false)" \
  --arg mac_model "$(sysctl -n hw.model)" \
  --arg memory_bytes "$(sysctl -n hw.memsize)" \
  --arg logical_cpu_count "$(sysctl -n hw.logicalcpu)" \
  --arg macos_version "$(sw_vers -productVersion)" \
  --arg macos_build "$(sw_vers -buildVersion)" \
  --arg architecture "$(uname -m)" \
  --arg power_source "$(pmset -g batt | head -1)" \
  --arg low_power_mode "$(pmset -g | awk '/lowpowermode/{print $2; exit}')" \
  --arg thermal_state "$(pmset -g therm 2>/dev/null | tr '\n' ';')" \
  --arg active_interface "$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')" \
  --arg ffmpeg_version "$(ffmpeg -version | head -1)" \
  --arg libvmaf_version "$(pkg-config --modversion libvmaf 2>/dev/null || print unknown)" \
  --arg app_sha256 "$(shasum -a 256 "$ROOT/DerivedData/Build/Products/Debug/WebRTCScreencast.app/Contents/MacOS/WebRTCScreencast" | awk '{print $1}')" \
  '{recorded_at:$recorded_at,git_commit:$git_commit,git_dirty:($git_dirty=="true"),app:{executable_sha256:$app_sha256},host:{mac_model:$mac_model,memory_bytes:($memory_bytes|tonumber),logical_cpu_count:($logical_cpu_count|tonumber),macos_version:$macos_version,macos_build:$macos_build,architecture:$architecture,power_source:$power_source,low_power_mode:$low_power_mode,thermal_state:$thermal_state,active_interface:$active_interface},tools:{ffmpeg:$ffmpeg_version,libvmaf_version:$libvmaf_version,libvmaf_model:"vmaf_v0.6.1"},capture:{shows_cursor:true,screen_recording_authorization:"verified by successful capture in each run"}}' \
  >"$artifact_root/host-context.json"

typeset -a reports
for round in $(seq 1 "$ROUNDS"); do
  for profile in direct-baseline production-relay; do
    run_parent="$artifact_root/round-$round-$profile"
    typeset -a args
    args=(
      --profile "$profile"
      --source virtual
      --run-seconds "$RUN_SECONDS"
      --output-root "$run_parent"
      --media-baseline
      --skip-build
    )
    [[ "$profile" == production-relay ]] && args+=(--runtime-config "$RUNTIME_CONFIG")
    run_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if output="$($ROOT/scripts/run-dual-client.sh "${args[@]}")"; then
      run_status=0
    else
      run_status=$?
    fi
    run_ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    print "$output"
    if "$ROOT/scripts/check-virtual-display-state.py" --expect 0; then
      display_status=0
    else
      display_status=$?
    fi
    (( run_status == 0 )) || exit "$run_status"
    (( display_status == 0 )) || exit "$display_status"
    run_root="$(find "$run_parent" -mindepth 1 -maxdepth 1 -type d -name 'run.*' -print -quit)"
    [[ -d "$run_root" ]] || { print -u2 "unable to locate run artifact directory"; exit 1; }
    sender_dir="$(find "$run_root/diagnostics" -mindepth 1 -maxdepth 1 -type d -name '*-sender' -print -quit)"
    receiver_dir="$(find "$run_root/diagnostics" -mindepth 1 -maxdepth 1 -type d -name '*-receiver' -print -quit)"
    report="$run_root/media-baseline-report.json"
    "$ROOT/scripts/analyze-media-baseline.py" --sender-dir "$sender_dir" --receiver-dir "$receiver_dir" --output "$report"
    jq --arg profile "$profile" --argjson round "$round" --arg started_at "$run_started_at" --arg ended_at "$run_ended_at" '. + {profile:$profile,round:$round,started_at:$started_at,ended_at:$ended_at}' "$report" >"$report.tmp"
    mv "$report.tmp" "$report"
    reports+=("$report")
  done
done

baseline_slug="$(date -u +%Y-%m-%d)-$(git -C "$ROOT" rev-parse --short HEAD)"
"$ROOT/scripts/aggregate-media-baseline.py" \
  --host-context "$artifact_root/host-context.json" \
  --output-json "$artifact_root/baseline.json" \
  --output-markdown "$artifact_root/baseline.md" \
  "${reports[@]}"
mkdir -p "$ROOT/baselines"
versioned_json="$ROOT/baselines/$baseline_slug.json"
versioned_markdown="$ROOT/baselines/$baseline_slug.md"
cp "$artifact_root/baseline.json" "$versioned_json"
cp "$artifact_root/baseline.md" "$versioned_markdown"
scan_complete_outputs
print "media baseline artifacts: $artifact_root"
