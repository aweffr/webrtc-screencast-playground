#!/bin/zsh
set -euo pipefail
setopt extendedglob

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RUNTIME_CONFIG="${RUNTIME_CONFIG:-}"
MODE="all"
ROUNDS=3
FUNCTIONAL_RUN_SECONDS=20
BASELINE_RUN_SECONDS=80
OUTPUT_ROOT="$ROOT/artifacts/android-tv-e2e"
DRY_RUN=0
SKIP_MACOS_BUILD=0

usage() {
  print -u2 "usage: $0 --runtime-config path [--mode all|functional|baseline] [--rounds n] [--functional-run-seconds n] [--baseline-run-seconds n] [--output-root path] [--skip-macos-build] [--dry-run]"
  exit 2
}

while (( $# )); do
  case "$1" in
    --runtime-config) [[ $# -ge 2 ]] || usage; RUNTIME_CONFIG="$2"; shift 2 ;;
    --mode) [[ $# -ge 2 ]] || usage; MODE="$2"; shift 2 ;;
    --rounds) [[ $# -ge 2 ]] || usage; ROUNDS="$2"; shift 2 ;;
    --functional-run-seconds) [[ $# -ge 2 ]] || usage; FUNCTIONAL_RUN_SECONDS="$2"; shift 2 ;;
    --baseline-run-seconds) [[ $# -ge 2 ]] || usage; BASELINE_RUN_SECONDS="$2"; shift 2 ;;
    --output-root) [[ $# -ge 2 ]] || usage; OUTPUT_ROOT="$2"; shift 2 ;;
    --skip-macos-build) SKIP_MACOS_BUILD=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) usage ;;
  esac
done

[[ "$MODE" == all || "$MODE" == functional || "$MODE" == baseline ]] || usage
[[ "$ROUNDS" == <-> && "$ROUNDS" -ge 1 ]] || usage
[[ "$FUNCTIONAL_RUN_SECONDS" == <-> && "$FUNCTIONAL_RUN_SECONDS" -ge 10 ]] || usage
[[ "$BASELINE_RUN_SECONDS" == <-> && "$BASELINE_RUN_SECONDS" -ge 75 ]] || {
  print -u2 "--baseline-run-seconds must be >= 75 for 10s warm-up and 60s measurement"
  exit 2
}

if (( DRY_RUN )); then
  if [[ "$MODE" == all || "$MODE" == functional ]]; then
    print "functional direct-baseline main"
    print "functional direct-baseline virtual"
    print "functional production-relay main"
    print "functional production-relay virtual"
  fi
  if [[ "$MODE" == all || "$MODE" == baseline ]]; then
    for round in $(seq 1 "$ROUNDS"); do
      print "baseline $round direct-baseline virtual"
      print "baseline $round production-relay virtual"
    done
  fi
  exit 0
fi

[[ -r "$RUNTIME_CONFIG" ]] || {
  print -u2 "a readable TURN/UDP runtime config is required"
  exit 2
}
for tool in adb ffmpeg jq python3 shasum; do
  command -v "$tool" >/dev/null || { print -u2 "$tool is required"; exit 2; }
done
[[ "$(ffmpeg -hide_banner -filters 2>/dev/null)" == *libvmaf* ]] || {
  print -u2 "ffmpeg libvmaf filter is required"
  exit 2
}
jq -e '.turn.url | startswith("turn:") and contains("transport=udp")' \
  "$RUNTIME_CONFIG" >/dev/null
"$ROOT/scripts/check-virtual-display-state.py" --expect 0

if [[ -z "${JAVA_HOME:-}" || "$("$JAVA_HOME/bin/java" -XshowSettings:properties -version 2>&1 | awk '/java.specification.version/{print $3; exit}')" != 17 ]]; then
  JAVA_HOME="$(/usr/libexec/java_home -v 17)"
  export JAVA_HOME
  export PATH="$JAVA_HOME/bin:$PATH"
fi

if (( SKIP_MACOS_BUILD )); then
  [[ -x "$ROOT/DerivedData/Build/Products/Debug/WebRTCScreencast.app/Contents/MacOS/WebRTCScreencast" ]] || {
    print -u2 "--skip-macos-build requires an existing WebRTCScreencast.app"
    exit 2
  }
else
  make -C "$ROOT" build-macos
fi
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(git -C "$ROOT" rev-parse --short HEAD)-android-tv"
mkdir -p "$OUTPUT_ROOT"
artifact_root="$(mktemp -d "$OUTPUT_ROOT/$run_id.XXXXXX")"
mkdir -p "$artifact_root/functional" "$artifact_root/baseline"
chmod 700 "$artifact_root" "$artifact_root/functional" "$artifact_root/baseline"

versioned_json=""
versioned_markdown=""
scan_outputs() {
  typeset -a targets
  targets=("$artifact_root")
  [[ -n "$versioned_json" && -f "$versioned_json" ]] && targets+=("$versioned_json")
  [[ -n "$versioned_markdown" && -f "$versioned_markdown" ]] && targets+=("$versioned_markdown")
  "$ROOT/scripts/scan-artifacts-for-configured-secrets.sh" \
    --config "$RUNTIME_CONFIG" "${targets[@]}" >/dev/null
}
cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM
  scan_outputs || exit_code=1
  exit "$exit_code"
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
  --arg macos_version "$(sw_vers -productVersion)" \
  --arg macos_build "$(sw_vers -buildVersion)" \
  --arg java_version "$(java -version 2>&1 | head -1)" \
  --arg ffmpeg_version "$(ffmpeg -version | head -1)" \
  --arg libvmaf_version "$(pkg-config --modversion libvmaf 2>/dev/null || print unknown)" \
  --arg aar_sha256 "$(shasum -a 256 "$ROOT/artifacts/webrtc-m150-android-arm64-v8a.aar" | awk '{print $1}')" \
  --arg macos_archive_sha256 "$(shasum -a 256 "$ROOT/artifacts/webrtc-m150-macos-arm64.tar.gz" | awk '{print $1}')" \
  '{recorded_at:$recorded_at,git_commit:$git_commit,git_dirty:($git_dirty=="true"),host:{mac_model:$mac_model,memory_bytes:($memory_bytes|tonumber),macos_version:$macos_version,macos_build:$macos_build},tools:{java:$java_version,ffmpeg:$ffmpeg_version,libvmaf_version:$libvmaf_version,libvmaf_model:"vmaf_v0.6.1"},inputs:{android_aar_sha256:$aar_sha256,macos_archive_sha256:$macos_archive_sha256},capture:{shows_cursor:true},environment:{android_tv_avd:"WebRTCScreencast_TV_API_31",api:31,abi:"arm64-v8a",display:"1920x1080"}}' \
  >"$artifact_root/host-context.json"

run_case() {
  local phase="$1" profile="$2" source="$3" seconds="$4" round="${5:-}"
  local label="$profile-$source"
  [[ -n "$round" ]] && label="round-$round-$label"
  local parent="$artifact_root/$phase/$label"
  mkdir -p "$parent"
  typeset -a args
  args=(
    --profile "$profile"
    --source "$source"
    --runtime-config "$RUNTIME_CONFIG"
    --run-seconds "$seconds"
    --output-root "$parent"
    --skip-macos-build
  )
  [[ "$phase" == baseline ]] && args+=(--media-baseline)
  local started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  "$ROOT/scripts/run-android-tv-e2e.sh" "${args[@]}"
  local ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  "$ROOT/scripts/check-virtual-display-state.py" --expect 0
  local run_root="$(find "$parent" -mindepth 1 -maxdepth 1 -type d -name 'run.*' -print -quit)"
  [[ -d "$run_root" ]] || { print -u2 "unable to locate $phase run artifacts for $label"; exit 1; }
  if [[ "$phase" == baseline ]]; then
    local report="$run_root/android-tv-baseline-report.json"
    [[ -s "$report" ]] || { print -u2 "missing Android TV baseline report for $label"; exit 1; }
    jq \
      --arg profile "$profile" \
      --argjson round "$round" \
      --arg started_at "$started_at" \
      --arg ended_at "$ended_at" \
      '. + {profile:$profile,round:$round,started_at:$started_at,ended_at:$ended_at}' \
      "$report" >"$report.tmp"
    mv "$report.tmp" "$report"
    reports+=("$report")
  fi
}

typeset -a reports
reports=()
if [[ "$MODE" == all || "$MODE" == functional ]]; then
  run_case functional direct-baseline main "$FUNCTIONAL_RUN_SECONDS"
  run_case functional direct-baseline virtual "$FUNCTIONAL_RUN_SECONDS"
  run_case functional production-relay main "$FUNCTIONAL_RUN_SECONDS"
  run_case functional production-relay virtual "$FUNCTIONAL_RUN_SECONDS"
fi
if [[ "$MODE" == all || "$MODE" == baseline ]]; then
  for round in $(seq 1 "$ROUNDS"); do
    run_case baseline direct-baseline virtual "$BASELINE_RUN_SECONDS" "$round"
    run_case baseline production-relay virtual "$BASELINE_RUN_SECONDS" "$round"
  done
  "$ROOT/scripts/aggregate-android-tv-baseline.py" \
    --host-context "$artifact_root/host-context.json" \
    --output-json "$artifact_root/baseline.json" \
    --output-markdown "$artifact_root/baseline.md" \
    "${reports[@]}"
  baseline_slug="$(date -u +%Y-%m-%d)-$(git -C "$ROOT" rev-parse --short HEAD)-android-tv"
  mkdir -p "$ROOT/baselines"
  versioned_json="$ROOT/baselines/$baseline_slug.json"
  versioned_markdown="$ROOT/baselines/$baseline_slug.md"
  cp "$artifact_root/baseline.json" "$versioned_json"
  cp "$artifact_root/baseline.md" "$versioned_markdown"
fi

scan_outputs
print "Android TV baseline artifacts: $artifact_root"
