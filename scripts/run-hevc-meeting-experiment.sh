#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
RUNTIME_CONFIG=""
MACOS_ARTIFACT=""
OUTPUT_ROOT="$ROOT/artifacts/hevc-meeting"
EXPERIMENT_ROOT=""
STAGE="base"
WINNER_ID=""
DOCUMENT_PORT=18765
RUN_SECONDS=100
TIME_SCALE=1
CHROME_VERSION="150.0.7871.129"

usage() {
  print -u2 "usage: $0 --runtime-config path --macos-artifact path [--stage smoke|base|supplemental|features] [--winner-id A1|B0|B1] [--experiment-root path] [--output-root path] [--document-port n]"
  exit 2
}

while (( $# )); do
  case "$1" in
    --runtime-config) [[ $# -ge 2 ]] || usage; RUNTIME_CONFIG="$2"; shift 2 ;;
    --macos-artifact) [[ $# -ge 2 ]] || usage; MACOS_ARTIFACT="$2"; shift 2 ;;
    --stage) [[ $# -ge 2 ]] || usage; STAGE="$2"; shift 2 ;;
    --winner-id) [[ $# -ge 2 ]] || usage; WINNER_ID="$2"; shift 2 ;;
    --experiment-root) [[ $# -ge 2 ]] || usage; EXPERIMENT_ROOT="$2"; shift 2 ;;
    --output-root) [[ $# -ge 2 ]] || usage; OUTPUT_ROOT="$2"; shift 2 ;;
    --document-port) [[ $# -ge 2 ]] || usage; DOCUMENT_PORT="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$STAGE" == smoke || "$STAGE" == base || "$STAGE" == supplemental || "$STAGE" == features ]] || usage
[[ "$DOCUMENT_PORT" == <-> && "$DOCUMENT_PORT" -ge 1024 && "$DOCUMENT_PORT" -le 65535 ]] || usage
if [[ "$STAGE" == features ]]; then
  [[ "$WINNER_ID" == A1 || "$WINNER_ID" == B0 || "$WINNER_ID" == B1 ]] || usage
  [[ -n "$EXPERIMENT_ROOT" && -d "$EXPERIMENT_ROOT" ]] || usage
  command -v jq >/dev/null || { print -u2 "jq is required"; exit 2; }
  base_report="$EXPERIMENT_ROOT/report.json"
  if [[ ! -r "$base_report" ]] || ! jq -e --arg winner "$WINNER_ID" '
      .stage == "base"
      and .run_features == true
      and .winner_id == $winner
      and any(.cases[]?; .case_id == $winner and .eligible == true)
    ' "$base_report" >/dev/null; then
    print -u2 "base report does not authorize HEVC feature stage for $WINNER_ID"
    exit 2
  fi
fi
[[ -r "$RUNTIME_CONFIG" && -f "$MACOS_ARTIFACT" ]] || usage
for tool in adb jq playwright-cli python3 shasum; do
  command -v "$tool" >/dev/null || { print -u2 "$tool is required"; exit 2; }
done
if [[ "$STAGE" != smoke && -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  print -u2 "formal HEVC experiments require a clean git worktree"
  exit 2
fi
MACOS_ARTIFACT="$(cd "${MACOS_ARTIFACT:h}" && pwd -P)/${MACOS_ARTIFACT:t}"
ANDROID_ARTIFACT="$ROOT/artifacts/webrtc-m150-android-arm64-v8a.aar"
[[ -f "$ANDROID_ARTIFACT" ]] || { print -u2 "Android WebRTC AAR is missing"; exit 2; }
jq -e '.turn.url | startswith("turn:") and contains("transport=udp")' "$RUNTIME_CONFIG" >/dev/null
jq -e '.turn.username and .turn.password' "$RUNTIME_CONFIG" >/dev/null
source_sha="$(jq -er '.sha256' "$ROOT/experiments/hevc-meeting/source.json")"
document_sha="$(shasum -a 256 "$ROOT/experiments/hevc-meeting/document.html" | awk '{print $1}')"
python3 -m unittest scripts.test_hevc_meeting_document >/dev/null

mkdir -p "$OUTPUT_ROOT"
OUTPUT_ROOT="$(cd "$OUTPUT_ROOT" && pwd -P)"
if [[ -z "$EXPERIMENT_ROOT" ]]; then
  EXPERIMENT_ROOT="$OUTPUT_ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$EXPERIMENT_ROOT"
fi
ATTEMPTS_FILE="$EXPERIMENT_ROOT/attempts.jsonl"
: >>"$ATTEMPTS_FILE"
[[ ! -e "$EXPERIMENT_ROOT/COMPLETE" ]] || {
  print -u2 "experiment is already complete: $EXPERIMENT_ROOT"
  exit 2
}

temp_root="$(mktemp -d /private/tmp/hevc-meeting-runner.XXXXXX)"
http_pid=""
workload_pid=""
workload_session=""
cleanup() {
  exit_code=$?
  if [[ -n "$workload_pid" ]]; then
    kill "$workload_pid" >/dev/null 2>&1 || true
    wait "$workload_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$workload_session" ]]; then
    playwright-cli -s="$workload_session" close >/dev/null 2>&1 || true
  fi
  if [[ -n "$http_pid" ]]; then
    kill "$http_pid" >/dev/null 2>&1 || true
    wait "$http_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$temp_root"
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

python3 -m http.server "$DOCUMENT_PORT" --bind 127.0.0.1 \
  --directory "$ROOT/experiments/hevc-meeting" \
  >"$EXPERIMENT_ROOT/document-server-$STAGE.log" 2>&1 &
http_pid=$!
for _ in {1..50}; do
  curl -fsS "http://127.0.0.1:$DOCUMENT_PORT/document.html" >/dev/null 2>&1 && break
  kill -0 "$http_pid" 2>/dev/null || { print -u2 "document server exited"; exit 1; }
  sleep 0.1
done
curl -fsS "http://127.0.0.1:$DOCUMENT_PORT/document.html" >/dev/null

macos_sha="$(shasum -a 256 "$MACOS_ARTIFACT" | awk '{print $1}')"
android_sha="$(shasum -a 256 "$ANDROID_ARTIFACT" | awk '{print $1}')"
app_commit="$(git -C "$ROOT" rev-parse HEAD)"
if [[ ! -f "$EXPERIMENT_ROOT/manifest.json" ]]; then
  jq -n \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg app_commit "$app_commit" \
    --arg builder_commit "da7818a854bb5d227f306af9816d2b54ebc7a74e" \
    --arg macos_artifact_sha256 "$macos_sha" \
    --arg android_artifact_sha256 "$android_sha" \
    --arg document_source_sha256 "$source_sha" \
    --arg document_html_sha256 "$document_sha" \
    --arg chrome_version "$CHROME_VERSION" \
    '{schema_version:2,created_at:$created_at,app_commit:$app_commit,builder_commit:$builder_commit,macos_artifact_sha256:$macos_artifact_sha256,android_artifact_sha256:$android_artifact_sha256,document_source_sha256:$document_source_sha256,document_html_sha256:$document_html_sha256,chrome_version:$chrome_version,profile:"production-relay",source:"main",max_attempts:23,max_infrastructure_retries:4}' \
    >"$EXPERIMENT_ROOT/manifest.json"
else
  jq -e \
    --arg commit "$app_commit" \
    --arg macos "$macos_sha" \
    --arg android "$android_sha" \
    --arg source "$source_sha" \
    --arg document "$document_sha" \
    --arg chrome "$CHROME_VERSION" '
      .schema_version == 2
      and .app_commit == $commit
      and .macos_artifact_sha256 == $macos
      and .android_artifact_sha256 == $android
      and .document_source_sha256 == $source
      and .document_html_sha256 == $document
      and .chrome_version == $chrome
    ' \
    "$EXPERIMENT_ROOT/manifest.json" >/dev/null
fi

typeset -a schedule_args
schedule_args=(schedule --stage "$STAGE")
[[ "$STAGE" == features ]] && schedule_args+=(--winner-id "$WINNER_ID")
schedule=("${(@f)$(python3 "$ROOT/scripts/hevc_meeting_experiment.py" "${schedule_args[@]}")}")
if [[ "$STAGE" == smoke ]]; then
  TIME_SCALE=0.1
  RUN_SECONDS=30
fi

typeset -A repetitions
skip_macos_build=0
for case_id in "${schedule[@]}"; do
  repetitions[$case_id]=$(( ${repetitions[$case_id]:-0} + 1 ))
  repetition="${repetitions[$case_id]}"
  run_root="$EXPERIMENT_ROOT/cases/$case_id/run-$repetition"
  if [[ -e "$run_root/VALID" ]]; then
    jq -e \
      --arg commit "$app_commit" \
      --arg macos "$macos_sha" \
      --arg android "$android_sha" '
        .app_commit == $commit
        and .macos_artifact_sha256 == $macos
        and .android_artifact_sha256 == $android
        and (.macos_executable_sha256 | type == "string" and length == 64)
        and (.android_apk_sha256 | type == "string" and length == 64)
      ' "$run_root/build-provenance.json" >/dev/null
    print -u2 "skipping completed $case_id run $repetition"
    continue
  fi
  mkdir -p "$run_root"

  valid=0
  for attempt in 1 2; do
    total_attempts=$(jq -s 'length' "$ATTEMPTS_FILE" 2>/dev/null || print 0)
    retries=$(jq -s '[.[] | select(.attempt == 2)] | length' "$ATTEMPTS_FILE" 2>/dev/null || print 0)
    (( total_attempts < 23 )) || { print -u2 "global attempt cap reached"; exit 1; }
    if (( attempt == 2 && retries >= 4 )); then
      print -u2 "global infrastructure retry cap reached"
      exit 1
    fi

    attempt_root="$run_root/attempt-$attempt"
    mkdir -p "$attempt_root"
    runtime_case="$temp_root/runtime-$case_id-$repetition-$attempt.json"
    tuning_case="$run_root/cast-tuning.json"
    typeset -a config_args
    config_args=(
      configs --case-id "$case_id"
      --runtime "$RUNTIME_CONFIG"
      --tuning "$ROOT/config/cast-tuning.default.json"
      --runtime-output "$runtime_case"
      --tuning-output "$tuning_case"
    )
    [[ "$STAGE" == features ]] && config_args+=(--winner-id "$WINNER_ID")
    python3 "$ROOT/scripts/hevc_meeting_experiment.py" "${config_args[@]}"
    chmod 600 "$runtime_case"
    jq -n --arg case_id "$case_id" --argjson repetition "$repetition" \
      --arg codec "$(jq -r '.video_codec_policy' "$runtime_case")" \
      --argjson static_qp "$(jq '.static_max_qp // null' "$runtime_case")" \
      --argjson active_qp "$(jq '.encoder.max_qp // null' "$tuning_case")" \
      '{case_id:$case_id,repetition:$repetition,codec_policy:$codec,static_max_qp:$static_qp,active_max_qp:$active_qp}' \
      >"$run_root/policy.json"

    ready_file="$attempt_root/chrome-ready"
    fullscreen_trigger_file="$attempt_root/sender-started"
    fullscreen_ready_file="$attempt_root/fullscreen-ready"
    start_file="$attempt_root/media-ready"
    workload_root="$attempt_root/workload"
    workload_session="hm${case_id:l}${repetition}${attempt}"
    python3 "$ROOT/scripts/hevc_meeting_workload.py" \
      --url "http://127.0.0.1:$DOCUMENT_PORT/document.html" \
      --output-directory "$workload_root" \
      --expected-chrome-version "$CHROME_VERSION" \
      --session "$workload_session" \
      --time-scale "$TIME_SCALE" \
      --ready-file "$ready_file" \
      --fullscreen-trigger-file "$fullscreen_trigger_file" \
      --fullscreen-ready-file "$fullscreen_ready_file" \
      --start-file "$start_file" \
      >"$attempt_root/workload.log" 2>&1 &
    workload_pid=$!
    browser_ready=0
    for _ in {1..300}; do
      if [[ -s "$ready_file" ]]; then browser_ready=1; break; fi
      kill -0 "$workload_pid" 2>/dev/null || break
      sleep 0.1
    done

    e2e_status=1
    if (( browser_ready )); then
      typeset -a e2e_args
      e2e_args=(
        --profile production-relay
        --source main
        --runtime-config "$runtime_case"
        --cast-tuning-config "$tuning_case"
        --run-seconds "$RUN_SECONDS"
        --output-root "$attempt_root/e2e"
        --marker-evidence
        --workload-fullscreen-trigger-file "$fullscreen_trigger_file"
        --workload-fullscreen-ready-file "$fullscreen_ready_file"
        --workload-start-file "$start_file"
      )
      (( skip_macos_build )) && e2e_args+=(--skip-macos-build)
      set +e
      WEBRTC_MACOS_TAR_GZ="$MACOS_ARTIFACT" \
      WEBRTC_ANDROID_AAR="$ANDROID_ARTIFACT" \
      "$ROOT/scripts/run-android-tv-e2e.sh" "${e2e_args[@]}" \
        >"$attempt_root/e2e.log" 2>&1
      e2e_status=$?
      set -e
      (( e2e_status == 0 )) && skip_macos_build=1
    fi

    if (( e2e_status != 0 )); then
      kill "$workload_pid" >/dev/null 2>&1 || true
    fi

    set +e
    wait "$workload_pid"
    workload_status=$?
    set -e
    workload_pid=""
    playwright-cli -s="$workload_session" close >/dev/null 2>&1 || true
    workload_session=""
    completed=$(jq -s 'any(.[]; .event == "workload_completed" and .valid == true)' \
      "$workload_root/workload.jsonl" 2>/dev/null || print false)
    e2e_run=$(find "$attempt_root/e2e" -mindepth 1 -maxdepth 1 -type d -name 'run.*' -print -quit 2>/dev/null || true)
    if (( e2e_status == 0 && workload_status == 0 )) \
        && [[ "$completed" == true && -n "$e2e_run" ]]; then
      jq -e --arg commit "$app_commit" '.git_commit == $commit' \
        "$e2e_run/context.json" >/dev/null
      build_provenance="$(jq -c '.build' "$e2e_run/context.json")"
      jq -n \
        --arg app_commit "$app_commit" \
        --arg macos_artifact_sha256 "$macos_sha" \
        --arg android_artifact_sha256 "$android_sha" \
        --argjson build "$build_provenance" '
          {
            app_commit:$app_commit,
            macos_artifact_sha256:$macos_artifact_sha256,
            android_artifact_sha256:$android_artifact_sha256
          } + $build
        ' >"$run_root/build-provenance.json"
      if jq -e '.build_outputs != null' "$EXPERIMENT_ROOT/manifest.json" >/dev/null; then
        jq -e --argjson build "$build_provenance" '
          .build_outputs.macos_executable_sha256 == $build.macos_executable_sha256
          and .build_outputs.android_aar_sha256 == $build.android_aar_sha256
        ' \
          "$EXPERIMENT_ROOT/manifest.json" >/dev/null
      else
        jq --argjson build "$build_provenance" '
          .build_outputs = {
            macos_executable_sha256:$build.macos_executable_sha256,
            android_aar_sha256:$build.android_aar_sha256
          }
        ' \
          "$EXPERIMENT_ROOT/manifest.json" >"$temp_root/manifest.json"
        mv "$temp_root/manifest.json" "$EXPERIMENT_ROOT/manifest.json"
      fi
      jq -n --arg case_id "$case_id" --argjson repetition "$repetition" \
        --argjson attempt "$attempt" --arg status valid \
        '{case_id:$case_id,repetition:$repetition,attempt:$attempt,status:$status}' \
        >>"$ATTEMPTS_FILE"
      print 'valid' >"$run_root/VALID"
      valid=1
      break
    fi

    jq -n --arg case_id "$case_id" --argjson repetition "$repetition" \
      --argjson attempt "$attempt" --arg status invalid \
      --argjson e2e_status "$e2e_status" --argjson workload_status "$workload_status" \
      '{case_id:$case_id,repetition:$repetition,attempt:$attempt,status:$status,e2e_status:$e2e_status,workload_status:$workload_status}' \
      >>"$ATTEMPTS_FILE"
    print -u2 "$case_id run $repetition attempt $attempt invalid"
  done
  (( valid )) || { print -u2 "$case_id run $repetition exhausted retry"; exit 1; }
done

print "$EXPERIMENT_ROOT"
