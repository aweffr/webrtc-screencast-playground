#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RUNTIME_CONFIG=""
XCFRAMEWORK=""
OUTPUT_ROOT="$ROOT/artifacts/static-max-qp"
RUN_SECONDS=30
DEPENDENCY_ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT/artifacts}"
SKIP_MACOS_BUILD=0

usage() {
  print -u2 "usage: $0 --runtime-config path --xcframework path [--output-root path] [--run-seconds n] [--skip-macos-build]"
  exit 2
}

while (( $# )); do
  case "$1" in
    --runtime-config) [[ $# -ge 2 ]] || usage; RUNTIME_CONFIG="$2"; shift 2 ;;
    --xcframework) [[ $# -ge 2 ]] || usage; XCFRAMEWORK="$2"; shift 2 ;;
    --output-root) [[ $# -ge 2 ]] || usage; OUTPUT_ROOT="$2"; shift 2 ;;
    --run-seconds) [[ $# -ge 2 ]] || usage; RUN_SECONDS="$2"; shift 2 ;;
    --skip-macos-build) SKIP_MACOS_BUILD=1; shift ;;
    *) usage ;;
  esac
done

[[ -r "$RUNTIME_CONFIG" && -f "$XCFRAMEWORK" ]] || usage
[[ "$RUN_SECONDS" == <-> && "$RUN_SECONDS" -ge 20 ]] || usage
for tool in adb ffmpeg git jq sips shasum sw_vers sysctl; do
  command -v "$tool" >/dev/null || { print -u2 "$tool is required"; exit 2; }
done

mkdir -p "$OUTPUT_ROOT"
OUTPUT_ROOT="$(cd "$OUTPUT_ROOT" && pwd -P)"
experiment_root="$OUTPUT_ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$experiment_root"
typeset -a temporary_configs
temporary_configs=()
cleanup() {
  rm -f "${temporary_configs[@]}"
}
trap cleanup EXIT INT TERM

xcframework_sha256="$(shasum -a 256 "$XCFRAMEWORK" | awk '{print $1}')"
skip_build=$SKIP_MACOS_BUILD
for max_qp in 24 22 20 18; do
  case_root="$experiment_root/qp-$max_qp"
  e2e_root="$case_root/e2e"
  mkdir -p "$case_root" "$e2e_root"
  runtime_case="$(mktemp "$experiment_root/.runtime-qp-$max_qp.XXXXXX.json")"
  temporary_configs+=("$runtime_case")
  jq --argjson max_qp "$max_qp" '.static_max_qp = $max_qp' \
    "$RUNTIME_CONFIG" >"$runtime_case"
  chmod 600 "$runtime_case"

  typeset -a e2e_args
  e2e_success=0
  for attempt in 1 2 3; do
    attempt_root="$case_root/e2e-attempt-$attempt"
    attempt_log="$case_root/e2e-attempt-$attempt.log"
    mkdir -p "$attempt_root"
    e2e_args=(
      --profile production-relay
      --source main
      --runtime-config "$runtime_case"
      --run-seconds "$RUN_SECONDS"
      --output-root "$attempt_root"
      --static-qp-evidence
    )
    (( skip_build )) && e2e_args+=(--skip-macos-build)
    if WEBRTC_XCFRAMEWORK_ZIP="$XCFRAMEWORK" \
        ARTIFACTS_DIR="$DEPENDENCY_ARTIFACTS_DIR" \
        "$ROOT/scripts/run-android-tv-e2e.sh" "${e2e_args[@]}" \
          | tee "$attempt_log"; then
      run_root="$(find "$attempt_root" -mindepth 1 -maxdepth 1 -type d -name 'run.*' -print -quit)"
      [[ -n "$run_root" ]] || { print -u2 "successful E2E did not retain a run"; exit 1; }
      mv "$run_root" "$e2e_root/"
      mv "$attempt_log" "$case_root/e2e.log"
      rm -rf "$attempt_root"
      e2e_success=1
      break
    fi
    skip_build=1
    mkdir -p "$case_root/e2e-failed"
    mv "$attempt_root" "$case_root/e2e-failed/attempt-$attempt"
    mv "$attempt_log" "$case_root/e2e-failed/attempt-$attempt.log"
    print -u2 "QP $max_qp E2E attempt $attempt failed; retrying"
    sleep 2
  done
  (( e2e_success )) || { print -u2 "QP $max_qp E2E failed after 3 attempts"; exit 1; }
  skip_build=1

  run_root="$(find "$e2e_root" -mindepth 1 -maxdepth 1 -type d -name 'run.*' -print -quit)"
  [[ -n "$run_root" ]] || { print -u2 "missing E2E run for QP $max_qp"; exit 1; }
  metrics_file="$(find "$run_root/macos" -mindepth 2 -maxdepth 2 -name metrics.jsonl -type f -print -quit)"
  [[ -s "$metrics_file" ]] || { print -u2 "missing sender metrics for QP $max_qp"; exit 1; }
  [[ -s "$run_root/static-qp-evidence.json" ]] || {
    print -u2 "missing screenshot-bound QP evidence for QP $max_qp"
    exit 1
  }
  cp "$run_root/static-qp-evidence.json" "$case_root/qp-evidence.json"
  jq -e --argjson max_qp "$max_qp" '
    .evidence_binding == "generation-session-stable-across-screenshot" and
    .requested_max_qp == $max_qp and
    .effective_max_qp == $max_qp and
    .max_qp_apply_state == "applied" and
    .last_qp_sample_generation == .max_qp_generation and
    .last_qp_sample_encoder_session_id == .max_qp_applied_encoder_session_id and
    .last_key_frame_qp != null and
    .last_key_frame_qp <= $max_qp and
    .last_key_frame_bytes > 0
  ' "$case_root/qp-evidence.json" >/dev/null

  cp "$run_root/android/receiver-playing.png" "$case_root/android-received-final.png"
  cp "$run_root/macos-main-source.png" "$case_root/macos-main-source.png"
  cp "$run_root/context.json" "$case_root/context.json"
  [[ "$(sips -g pixelWidth "$case_root/android-received-final.png" | awk '/pixelWidth/ {print $2}')" == 1920 ]]
  [[ "$(sips -g pixelHeight "$case_root/android-received-final.png" | awk '/pixelHeight/ {print $2}')" == 1080 ]]

  ffmpeg -hide_banner -loglevel error \
    -i "$case_root/macos-main-source.png" \
    -i "$case_root/android-received-final.png" \
    -filter_complex \
      "[0:v]scale=1920:1080:force_original_aspect_ratio=decrease:flags=lanczos,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black,format=yuv420p[reference];[1:v]scale=1920:1080:flags=lanczos,format=yuv420p[distorted];[distorted][reference]libvmaf=log_fmt=json:log_path=$case_root/vmaf.json" \
    -frames:v 1 -f null -
  jq -e '.pooled_metrics.vmaf.mean | numbers' "$case_root/vmaf.json" >/dev/null
done

android_context="$experiment_root/qp-24/context.json"
jq -e '.android.avd and .android.api and .android.abi and .android.display' \
  "$android_context" >/dev/null
jq -n \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg xcframework_sha256 "$xcframework_sha256" \
  --arg app_commit "$(git -C "$ROOT" rev-parse HEAD)" \
  --arg hardware_model "$(sysctl -n hw.model)" \
  --arg macos_version "$(sw_vers -productVersion)" \
  --arg android_device "$(jq -r '.android.avd' "$android_context")" \
  --arg android_api "$(jq -r '.android.api' "$android_context")" \
  --arg android_abi "$(jq -r '.android.abi' "$android_context")" \
  --arg android_display "$(jq -r '.android.display' "$android_context")" \
  --argjson run_seconds "$RUN_SECONDS" \
  '{
    schema_version: 1,
    generated_at: $generated_at,
    xcframework_sha256: $xcframework_sha256,
    app_commit: $app_commit,
    hardware_model: $hardware_model,
    macos_version: $macos_version,
    android_device: $android_device,
    android_api: $android_api,
    android_abi: $android_abi,
    android_display: $android_display,
    profile: "production-relay",
    source: "main",
    run_seconds: $run_seconds,
    requested_max_qp: [24, 22, 20, 18]
  }' >"$experiment_root/manifest.json"

print "$experiment_root"
