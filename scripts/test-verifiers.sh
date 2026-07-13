#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/webrtc-verifier-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/receiver" "$WORK/sender"

jq -nc '[
  {event:"session_started",fields:{source:null}},
  {event:"signaling_connected",fields:{}},
  {event:"peer_paired",fields:{}},
  {event:"receiver_registered",fields:{}},
  {event:"remote_offer",fields:{}},
  {event:"local_answer",fields:{}},
  {event:"remote_video_track",fields:{}},
  {event:"selected_path",fields:{status:"verified",local_candidate_type:"host",remote_candidate_type:"host",protocol:"udp"}},
  {event:"rtc_stats",fields:{selected_path:{status:"verified",local_candidate_type:"host",remote_candidate_type:"host",protocol:"udp"},inbound_video:{frames:2,codec:"video/H264"},render:{frames_rendered:2}}}
] | .[] | . + {session_id:"server-session-1"}' >"$WORK/receiver/metrics.jsonl"

jq -nc '[
  {event:"session_started",fields:{source:"main-display-mirror"}},
  {event:"signaling_connected",fields:{}},
  {event:"peer_paired",fields:{}},
  {event:"sender_join_requested",fields:{}},
  {event:"local_offer",fields:{}},
  {event:"remote_answer",fields:{}},
  {event:"capture_started",fields:{}},
  {event:"selected_path",fields:{status:"verified",local_candidate_type:"host",remote_candidate_type:"host",protocol:"udp"}},
  {event:"rtc_stats",fields:{selected_path:{status:"verified",local_candidate_type:"host",remote_candidate_type:"host",protocol:"udp"},outbound_video:{frames:2,codec:"video/H264"},render:{frames_rendered:0}}}
] | .[] | . + {session_id:"server-session-1"}' >"$WORK/sender/metrics.jsonl"

"$ROOT/scripts/verify-diagnostics.sh" "$WORK/receiver" "$WORK/sender" direct-baseline >/dev/null

touch "$WORK/sender/webrtc_log_0"
if "$ROOT/scripts/verify-diagnostics.sh" "$WORK/receiver" "$WORK/sender" direct-baseline >/dev/null 2>&1; then
  print -u2 "verifier accepted a raw libwebrtc log"
  exit 1
fi
rm "$WORK/sender/webrtc_log_0"

touch "$WORK/sender/.webrtc_log_0"
if "$ROOT/scripts/verify-diagnostics.sh" "$WORK/receiver" "$WORK/sender" direct-baseline >/dev/null 2>&1; then
  print -u2 "verifier accepted a hidden raw libwebrtc log"
  exit 1
fi
rm "$WORK/sender/.webrtc_log_0"

cp "$WORK/receiver/metrics.jsonl" "$WORK/receiver/original.jsonl"
jq 'if .event == "session_started" then del(.session_id) else . end' \
  "$WORK/receiver/metrics.jsonl" >"$WORK/receiver/invalid.jsonl"
mv "$WORK/receiver/invalid.jsonl" "$WORK/receiver/metrics.jsonl"
if "$ROOT/scripts/verify-diagnostics.sh" "$WORK/receiver" "$WORK/sender" direct-baseline >/dev/null 2>&1; then
  print -u2 "verifier accepted a record without session_id"
  exit 1
fi
mv "$WORK/receiver/original.jsonl" "$WORK/receiver/metrics.jsonl"

jq 'if .event == "rtc_stats" then .fields.outbound_video.frames = 0 else . end' \
  "$WORK/sender/metrics.jsonl" >"$WORK/sender/invalid.jsonl"
mv "$WORK/sender/invalid.jsonl" "$WORK/sender/metrics.jsonl"
if "$ROOT/scripts/verify-diagnostics.sh" "$WORK/receiver" "$WORK/sender" direct-baseline >/dev/null 2>&1; then
  print -u2 "verifier accepted missing encode evidence"
  exit 1
fi

username="test-user-$(uuidgen)"
password="test-password-$(uuidgen)"
jq -n --arg username "$username" --arg password "$password" '{turn:{username:$username,password:$password}}' >"$WORK/runtime.json"
"$ROOT/scripts/verify-no-secret-leaks.sh" --config "$WORK/runtime.json" >/dev/null

print "script verifier tests passed"
