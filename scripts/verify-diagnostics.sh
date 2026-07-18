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

android_receiver=0
receiver="$RECEIVER_DIR/metrics.jsonl"
if [[ -s "$RECEIVER_DIR/receiver.jsonl" ]]; then
  receiver="$RECEIVER_DIR/receiver.jsonl"
  android_receiver=1
fi
sender="$SENDER_DIR/metrics.jsonl"
[[ -s "$receiver" ]] || { print -u2 "missing receiver metrics: $receiver"; exit 1; }
[[ -s "$sender" ]] || { print -u2 "missing sender metrics: $sender"; exit 1; }

if find "$RECEIVER_DIR" "$SENDER_DIR" -type f \
  \( -name 'rtc-event.log' -o -name 'webrtc_log*' -o -name '.*rtc-event.log' -o -name '.*webrtc_log*' \) \
  -print -quit | grep -q .; then
  print -u2 "diagnostics contain unsupported raw libwebrtc logs"
  exit 1
fi

for file in "$receiver" "$sender"; do
  jq -e -c . "$file" >/dev/null || { print -u2 "invalid JSONL: $file"; exit 1; }
done

require_event() {
  local file="$1" event="$2" label="$3"
  jq -e --arg event "$event" 'select(.event == $event)' "$file" >/dev/null \
    || { print -u2 "missing $label evidence ($event)"; exit 1; }
}

if (( android_receiver )); then
  sender_session_id="$(jq -sr '
    if length > 0
      and all(.[]; (.session_id | type == "string") and (.session_id | length > 0))
      and ([.[].session_id] | unique | length == 1)
    then .[0].session_id else empty end
  ' "$sender")"
  receiver_session_id="$(jq -sr '
    [.[] | select(.event == "session_paired") | .fields.session_id]
    | if length == 1 and .[0] != null and (.[0] | length > 0) then .[0] else empty end
  ' "$receiver")"
  jq -se 'length > 0
    and all(.[]; (.run_id | type == "string") and (.run_id | length > 0))
    and ([.[].run_id] | unique | length == 1)' "$receiver" >/dev/null \
    || { print -u2 "Android receiver evidence does not use one run_id"; exit 1; }
  [[ -n "$sender_session_id" && "$sender_session_id" == "$receiver_session_id" ]] \
    || { print -u2 "sender and Android receiver do not share one session_id"; exit 1; }

  for event in session_started signaling_connected peer_paired rtc_stats \
    sender_join_requested local_offer remote_answer capture_started; do
    require_event "$sender" "$event" "sender"
  done
  for event in receiver_runtime_initialized clock_calibration signaling_connected \
    receiver_registered session_paired sdp_offer_received sdp_answer_sent \
    remote_video_playing rtc_stats; do
    require_event "$receiver" "$event" "Android receiver"
  done
  media_codec="$(jq -sr '[.[] | select(.event == "rtc_stats")
    | .fields.outbound_video.codec // empty] | last // empty | ascii_downcase' "$sender")"
  [[ "$media_codec" == video/h264 || "$media_codec" == video/h265 ]] \
    || { print -u2 "sender did not publish an H.264/H.265 codec"; exit 1; }
  jq -se --arg codec "$media_codec" 'any(.[];
    .event == "rtc_stats"
    and (.fields.outbound_video.frames // 0) > 0
    and ((.fields.outbound_video.codec // "") | ascii_downcase) == $codec
    and ((($codec == "video/h264") and
      ((.fields.sender_media_boundary.video_toolbox_encoder_id // "")
        | ascii_downcase | contains("avc")))
      or (($codec == "video/h265") and
      ((.fields.sender_media_boundary.video_toolbox_encoder_id // "")
        | ascii_downcase | contains("hevc"))))
    and (.fields.sender_media_boundary.last_key_frame_qp // -1) >= 0)' \
    "$sender" >/dev/null || { print -u2 "missing sender hardware encoder/QP evidence"; exit 1; }
  jq -se --arg codec "$media_codec" 'any(.[];
    .event == "rtc_stats"
    and (.fields.frames_decoded // 0) > 0
    and ((.fields.codec // "") | ascii_downcase) == $codec
    and ((.fields.decoder // "") | length > 0)
    and .fields.frame_width == 1920
    and .fields.frame_height == 1080)' "$receiver" >/dev/null \
    || { print -u2 "missing Android $media_codec 1920x1080 decoder evidence"; exit 1; }

  jq -se 'any(.[]; .event == "selected_path" and .fields.status == "verified")' \
    "$sender" >/dev/null || { print -u2 "missing sender selected-path evidence"; exit 1; }
  if [[ "$PROFILE" == production-relay ]]; then
    jq -se 'any(.[]; .event == "selected_path"
      and .fields.status == "verified"
      and .fields.local_candidate_type == "relay"
      and .fields.remote_candidate_type == "relay"
      and .fields.protocol == "udp")' "$sender" >/dev/null \
      || { print -u2 "sender production path is not relay/relay udp"; exit 1; }
    jq -se 'any(.[]; .event == "rtc_stats"
      and .fields.path_status == "accepted"
      and .fields.local_path_type == "relay"
      and .fields.remote_path_type == "relay"
      and .fields.path_protocol == "udp")' "$receiver" >/dev/null \
      || { print -u2 "Android production path is not relay/relay udp"; exit 1; }
  else
    jq -se 'any(.[]; .event == "selected_path"
      and .fields.status == "verified"
      and .fields.local_candidate_type != "relay"
      and .fields.remote_candidate_type != "relay"
      and .fields.protocol == "udp")' "$sender" >/dev/null \
      || { print -u2 "sender direct baseline selected a relay or non-UDP path"; exit 1; }
    jq -se 'any(.[]; .event == "rtc_stats"
      and .fields.path_status == "accepted"
      and .fields.local_path_type != "relay"
      and .fields.remote_path_type != "relay"
      and .fields.path_protocol == "udp")' "$receiver" >/dev/null \
      || { print -u2 "Android direct baseline selected a relay or non-UDP path"; exit 1; }
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
  print "diagnostics verified: Android $media_codec 1920x1080 media and $PROFILE selected path"
  exit 0
fi

canonical_session_id() {
  jq -sr '
    if length > 0
      and all(.[]; (.session_id | type == "string") and (.session_id | length > 0))
      and ([.[].session_id] | unique | length == 1)
    then .[0].session_id
    else empty
    end
  ' "$1"
}

receiver_session_id="$(canonical_session_id "$receiver")"
sender_session_id="$(canonical_session_id "$sender")"
[[ -n "$receiver_session_id" && "$receiver_session_id" == "$sender_session_id" ]] \
  || { print -u2 "sender and receiver metrics do not share one canonical session_id"; exit 1; }

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
    and ((.fields.outbound_video.codec // "") | ascii_downcase | contains("h265"))
    and ((.fields.sender_media_boundary.video_toolbox_encoder_id // "")
      | ascii_downcase | contains("hevc"))
    and (.fields.sender_media_boundary.last_key_frame_qp // -1) >= 0)
' "$sender" >/dev/null || { print -u2 "missing sender HEVC encoder/QP evidence"; exit 1; }

jq -se '
  any(.[];
    .event == "rtc_stats"
    and (.fields.inbound_video.frames // 0) > 0
    and ((.fields.inbound_video.codec // "") | ascii_downcase | contains("h265"))
    and ((.fields.inbound_video.decoder // "") | length > 0)
    and (.fields.render.frames_rendered // 0) > 0)
' "$receiver" >/dev/null || { print -u2 "missing receiver HEVC decoder/render evidence"; exit 1; }

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
        and .fields.selected_path.remote_candidate_type == "relay"
        and .fields.selected_path.protocol == "udp")
      or (.event == "selected_path"
        and .fields.status == "verified"
        and .fields.local_candidate_type == "relay"
        and .fields.remote_candidate_type == "relay"
        and .fields.protocol == "udp"))' "$file" >/dev/null \
      || { print -u2 "production path is not relay/relay udp in $file"; exit 1; }
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

print "diagnostics verified: HEVC media, encoder/QP, decoder/render and $PROFILE selected path"
