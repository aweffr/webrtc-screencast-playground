#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PROFILE="direct-baseline"
SOURCE="main"
RUNTIME_CONFIG="${RUNTIME_CONFIG:-}"
RUN_SECONDS=20
SKIP_BUILD=0
MEDIA_BASELINE=0
OUTPUT_ROOT=""

usage() {
  print -u2 "usage: $0 [--profile direct-baseline|production-relay] [--source main|virtual] [--runtime-config path] [--run-seconds n] [--output-root path] [--media-baseline] [--skip-build]"
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
    --skip-build) SKIP_BUILD=1; shift ;;
    *) usage ;;
  esac
done

[[ "$PROFILE" == direct-baseline || "$PROFILE" == production-relay ]] || usage
[[ "$SOURCE" == main || "$SOURCE" == virtual ]] || usage
(( ! MEDIA_BASELINE )) || [[ "$SOURCE" == virtual ]] || { print -u2 "--media-baseline requires --source virtual"; exit 2; }
[[ "$RUN_SECONDS" == <-> && "$RUN_SECONDS" -ge 5 ]] || { print -u2 "--run-seconds must be an integer >= 5"; exit 2; }
command -v jq >/dev/null || { print -u2 "jq is required"; exit 2; }

if [[ "$PROFILE" == production-relay ]]; then
  [[ -n "$RUNTIME_CONFIG" && -r "$RUNTIME_CONFIG" ]] || {
    print -u2 "production-relay requires --runtime-config with TURN/UDP credentials"
    exit 2
  }
  jq -e '.turn.url | startswith("turn:") and contains("transport=udp")' "$RUNTIME_CONFIG" >/dev/null
  jq -e '.turn.username | type == "string" and length > 0' "$RUNTIME_CONFIG" >/dev/null
  jq -e '.turn.password | type == "string" and length > 0' "$RUNTIME_CONFIG" >/dev/null
fi

if (( ! SKIP_BUILD )); then
  make -C "$ROOT" build-macos
fi

APP="$ROOT/DerivedData/Build/Products/Debug/WebRTCScreencast.app"
EXECUTABLE="$APP/Contents/MacOS/WebRTCScreencast"
[[ -x "$EXECUTABLE" ]] || { print -u2 "app executable not found: $EXECUTABLE"; exit 1; }

if [[ -n "$OUTPUT_ROOT" ]]; then
  mkdir -p "$OUTPUT_ROOT"
  OUTPUT_ROOT="$(cd "$OUTPUT_ROOT" && pwd -P)"
  RUN_ROOT="$(mktemp -d "$OUTPUT_ROOT/run.XXXXXX")"
else
  RUN_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/webrtc-screencast-e2e.XXXXXX")"
fi
METRICS_ROOT="$RUN_ROOT/diagnostics"
PAIRING_FILE="$RUN_ROOT/pairing-code"
CONFIG_FILE="$RUN_ROOT/runtime.json"
mkdir -p "$METRICS_ROOT"
chmod 700 "$RUN_ROOT" "$METRICS_ROOT"

PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
SIGNALING_URL="ws://127.0.0.1:$PORT/ws"

if [[ "$PROFILE" == production-relay ]]; then
  jq --arg url "$SIGNALING_URL" --arg metrics "$METRICS_ROOT" '
    .signaling_url = $url
    | .ice_profile = "production-relay"
    | .metrics_directory = $metrics
    | .excluded_receiver_pid = null
  ' "$RUNTIME_CONFIG" >"$CONFIG_FILE"
else
  jq -n --arg url "$SIGNALING_URL" --arg metrics "$METRICS_ROOT" '{
    signaling_url: $url,
    ice_profile: "direct-baseline",
    turn: null,
    metrics_directory: $metrics,
    excluded_receiver_pid: null
  }' >"$CONFIG_FILE"
fi
chmod 600 "$CONFIG_FILE"

server_pid=""
receiver_pid=""
sender_pid=""
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  for pid in "$sender_pid" "$receiver_pid" "$server_pid"; do
    [[ -n "$pid" ]] && kill "$pid" >/dev/null 2>&1 || true
  done
  [[ -n "${CONFIG_FILE:-}" ]] && rm -f "$CONFIG_FILE"
  if [[ "$PROFILE" == production-relay && -n "$RUNTIME_CONFIG" ]]; then
    if ! "$ROOT/scripts/scan-artifacts-for-configured-secrets.sh" \
      --config "$RUNTIME_CONFIG" "$RUN_ROOT"; then
      status=1
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

(cd "$ROOT/server" && go build -o "$RUN_ROOT/signaling-server" ./cmd/signaling-server)
LISTEN_ADDR="127.0.0.1:$PORT" "$RUN_ROOT/signaling-server" >"$RUN_ROOT/signaling.log" 2>&1 &
server_pid=$!

for _ in {1..100}; do
  curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
  kill -0 "$server_pid" 2>/dev/null || { print -u2 "signaling server exited; see $RUN_ROOT/signaling.log"; exit 1; }
  sleep 0.1
done
curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null || { print -u2 "signaling health check timed out"; exit 1; }

typeset -a receiver_args
receiver_args=(
  --role receiver
  --profile "$PROFILE"
  --config "$CONFIG_FILE"
  --pairing-code-file "$PAIRING_FILE"
  --run-seconds "$(( RUN_SECONDS + 8 ))"
)
(( MEDIA_BASELINE )) && receiver_args+=(--media-baseline)
"$EXECUTABLE" "${receiver_args[@]}" >"$RUN_ROOT/receiver.log" 2>&1 &
receiver_pid=$!

for _ in {1..300}; do
  [[ -s "$PAIRING_FILE" ]] && break
  kill -0 "$receiver_pid" 2>/dev/null || { print -u2 "receiver exited before pairing; see $RUN_ROOT/receiver.log"; exit 1; }
  sleep 0.1
done
[[ -s "$PAIRING_FILE" ]] || { print -u2 "pairing code timed out"; exit 1; }
[[ "$(stat -f '%Lp' "$PAIRING_FILE")" == 600 ]] || { print -u2 "pairing-code file is not mode 0600"; exit 1; }

typeset -a sender_args
sender_args=(
  --role sender
  --profile "$PROFILE"
  --config "$CONFIG_FILE"
  --pairing-code-file "$PAIRING_FILE"
  --source "$SOURCE"
  --run-seconds "$RUN_SECONDS"
)
(( MEDIA_BASELINE )) && sender_args+=(--media-baseline)
if [[ "$PROFILE" == direct-baseline && "$SOURCE" == main ]]; then
  sender_args+=(--exclude-receiver-pid "$receiver_pid")
fi

"$EXECUTABLE" "${sender_args[@]}" >"$RUN_ROOT/sender.log" 2>&1 &
sender_pid=$!

set +e
wait "$sender_pid"
sender_status=$?
wait "$receiver_pid"
receiver_status=$?
set -e
sender_pid=""
receiver_pid=""

sender_dir="$(find "$METRICS_ROOT" -mindepth 1 -maxdepth 1 -type d -name '*-sender' -print -quit)"
receiver_dir="$(find "$METRICS_ROOT" -mindepth 1 -maxdepth 1 -type d -name '*-receiver' -print -quit)"
[[ -n "$sender_dir" && -n "$receiver_dir" ]] || {
  print -u2 "missing diagnostics directories; run artifacts: $RUN_ROOT"
  exit 1
}

print "run artifacts: $RUN_ROOT"
print "process exit status: receiver=$receiver_status sender=$sender_status"
print "receiver diagnostics: $receiver_dir"
print "sender diagnostics: $sender_dir"

[[ "$sender_status" -eq 0 && "$receiver_status" -eq 0 ]] || exit 1
"$ROOT/scripts/verify-diagnostics.sh" "$receiver_dir" "$sender_dir" "$PROFILE" "$CONFIG_FILE"
