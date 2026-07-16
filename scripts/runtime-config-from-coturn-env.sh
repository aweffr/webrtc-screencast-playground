#!/bin/zsh
set -euo pipefail

ENV_FILE=""
OUTPUT=""
SIGNALING_URL="ws://127.0.0.1:8080/ws"
METRICS_DIRECTORY="$HOME/Library/Application Support/WebRTCScreencast/Diagnostics"

usage() {
  print -u2 "usage: $0 --env coturn.env --output runtime.json [--signaling-url ws://...] [--metrics-directory path]"
  exit 2
}

while (( $# )); do
  case "$1" in
    --env) [[ $# -ge 2 ]] || usage; ENV_FILE="$2"; shift 2 ;;
    --output) [[ $# -ge 2 ]] || usage; OUTPUT="$2"; shift 2 ;;
    --signaling-url) [[ $# -ge 2 ]] || usage; SIGNALING_URL="$2"; shift 2 ;;
    --metrics-directory) [[ $# -ge 2 ]] || usage; METRICS_DIRECTORY="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -r "$ENV_FILE" && -n "$OUTPUT" ]] || usage
command -v jq >/dev/null || { print -u2 "jq is required"; exit 2; }
[[ "$SIGNALING_URL" == ws://* || "$SIGNALING_URL" == wss://* ]] || { print -u2 "signaling URL must use ws or wss"; exit 2; }

runtime_value() {
  local key="$1"
  awk -F= -v key="$key" '
    $0 ~ /^[[:space:]]*(#|$)/ { next }
    $1 == key {
      if (found) exit 2
      value = substr($0, index($0, "=") + 1)
      sub(/\r$/, "", value)
      found = 1
    }
    END {
      if (!found || value == "") exit 1
      print value
    }
  ' "$ENV_FILE"
}

public_ip="$(runtime_value COTURN_PUBLIC_IP)" || { print -u2 "missing or duplicate COTURN_PUBLIC_IP"; exit 1; }
listen_port="$(runtime_value COTURN_LISTEN_PORT)" || { print -u2 "missing or duplicate COTURN_LISTEN_PORT"; exit 1; }
username="$(runtime_value TURN_USERNAME)" || { print -u2 "missing or duplicate TURN_USERNAME"; exit 1; }
password="$(runtime_value TURN_PASSWORD)" || { print -u2 "missing or duplicate TURN_PASSWORD"; exit 1; }
[[ "$listen_port" == <-> && "$listen_port" -ge 1 && "$listen_port" -le 65535 ]] \
  || { print -u2 "COTURN_LISTEN_PORT is invalid"; exit 1; }

output_directory="${OUTPUT:h}"
mkdir -p "$output_directory"
temporary="$(mktemp "$output_directory/.runtime.XXXXXX")"
trap 'rm -f "$temporary"' EXIT
umask 077
jq -n \
  --arg signaling "$SIGNALING_URL" \
  --arg turn_url "turn:$public_ip:$listen_port?transport=udp" \
  --arg username "$username" \
  --arg password "$password" \
  --arg metrics "$METRICS_DIRECTORY" \
  '{
    signaling_url: $signaling,
    ice_profile: "production-relay",
    turn: {url: $turn_url, username: $username, password: $password},
    metrics_directory: $metrics,
    excluded_receiver_pid: null,
    static_max_qp: 24
  }' >"$temporary"
chmod 600 "$temporary"
mv -f "$temporary" "$OUTPUT"
trap - EXIT
print "runtime configuration created with mode 0600: $OUTPUT"
