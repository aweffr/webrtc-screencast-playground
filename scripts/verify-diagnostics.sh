#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 "usage: $0 <receiver-dir> <sender-dir> <direct-baseline|production-relay> [runtime-config]"
  exit 2
}

[[ $# -ge 3 && $# -le 4 ]] || usage
RECEIVER_DIR="$1"
SENDER_DIR="$2"
PROFILE="$3"
CONFIG="${4:-${RUNTIME_CONFIG:-}}"

[[ "$PROFILE" == direct-baseline || "$PROFILE" == production-relay ]] || usage
command -v jq >/dev/null || { print -u2 "jq is required"; exit 2; }

receiver="$RECEIVER_DIR/metrics.jsonl"
sender="$SENDER_DIR/metrics.jsonl"
[[ -s "$receiver" ]] || { print -u2 "missing receiver metrics: $receiver"; exit 1; }
[[ -s "$sender" ]] || { print -u2 "missing sender metrics: $sender"; exit 1; }

for file in "$receiver" "$sender"; do
  jq -e -c . "$file" >/dev/null || { print -u2 "invalid JSONL: $file"; exit 1; }
done

require_event() {
  local file="$1" event="$2" label="$3"
  jq -e --arg event "$event" 'select(.event == $event)' "$file" >/dev/null \
    || { print -u2 "missing $label evidence ($event)"; exit 1; }
}

for event in session_started signaling_connected peer_paired rtc_stats; do
  require_event "$sender" "$event" "sender"
  require_event "$receiver" "$event" "receiver"
done
for event in sender_join_requested local_offer remote_answer capture_started; do
  require_event "$sender" "$event" "sender"
done
for event in receiver_registered remote_offer local_answer remote_video_track; do
  require_event "$receiver" "$event" "receiver"
done

jq -se '
  any(.[];
    .event == "rtc_stats"
    and (.fields.outbound_video.frames // 0) > 0
    and ((.fields.outbound_video.codec // "") | ascii_downcase | contains("h264")))
' "$sender" >/dev/null || { print -u2 "missing sender H.264 encode evidence"; exit 1; }

jq -se '
  any(.[];
    .event == "rtc_stats"
    and (.fields.inbound_video.frames // 0) > 0
    and ((.fields.inbound_video.codec // "") | ascii_downcase | contains("h264"))
    and (.fields.render.frames_rendered // 0) > 0)
' "$receiver" >/dev/null || { print -u2 "missing receiver H.264 decode/render evidence"; exit 1; }

for file in "$receiver" "$sender"; do
  jq -se 'any(.[];
    (.event == "rtc_stats" and .fields.selected_path.status == "verified")
    or (.event == "selected_path" and .fields.status == "verified"))' "$file" >/dev/null \
    || { print -u2 "missing verified selected-path evidence in $file"; exit 1; }
done

if [[ "$PROFILE" == production-relay ]]; then
  for file in "$receiver" "$sender"; do
    jq -se 'any(.[];
      (.event == "rtc_stats"
        and .fields.selected_path.status == "verified"
        and .fields.selected_path.local_candidate_type == "relay"
        and .fields.selected_path.protocol == "udp")
      or (.event == "selected_path"
        and .fields.status == "verified"
        and .fields.local_candidate_type == "relay"
        and .fields.protocol == "udp"))' "$file" >/dev/null \
      || { print -u2 "production path is not relay/udp in $file"; exit 1; }
  done
else
  for file in "$receiver" "$sender"; do
    jq -se 'any(.[];
      (.event == "rtc_stats"
        and .fields.selected_path.status == "verified"
        and .fields.selected_path.local_candidate_type != "relay"
        and .fields.selected_path.remote_candidate_type != "relay")
      or (.event == "selected_path"
        and .fields.status == "verified"
        and .fields.local_candidate_type != "relay"
        and .fields.remote_candidate_type != "relay"))' "$file" >/dev/null \
      || { print -u2 "direct baseline selected a relay candidate in $file"; exit 1; }
  done
fi

source_kind="$(jq -sr '[.[] | select(.event == "session_started")][0].fields.source // ""' "$sender")"
if [[ "$source_kind" == virtual-extended-display ]]; then
  require_event "$sender" virtual_display_created "virtual display"
  require_event "$sender" virtual_display_removed "virtual display cleanup"
fi

if [[ -n "$CONFIG" ]]; then
  [[ -r "$CONFIG" ]] || { print -u2 "runtime config is unreadable"; exit 1; }
  for field in username password; do
    secret="$(jq -r ".turn.$field // empty" "$CONFIG")"
    [[ -z "$secret" ]] && continue
    if LC_ALL=C grep -R -a -F -q -- "$secret" "$RECEIVER_DIR" "$SENDER_DIR"; then
      print -u2 "diagnostics contain configured TURN $field"
      exit 1
    fi
  done
fi

print "diagnostics verified: H.264 media, render metrics and $PROFILE selected path"
