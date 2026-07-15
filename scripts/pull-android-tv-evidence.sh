#!/bin/zsh
set -euo pipefail

PACKAGE="cn.aweffr.webrtcscreencast.tv"
OUTPUT_DIR=""

usage() {
  print -u2 "usage: $0 --output-dir path [--package application-id]"
  exit 2
}

while (( $# )); do
  case "$1" in
    --output-dir) [[ $# -ge 2 ]] || usage; OUTPUT_DIR="$2"; shift 2 ;;
    --package) [[ $# -ge 2 ]] || usage; PACKAGE="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$OUTPUT_DIR" ]] || usage
command -v adb >/dev/null || { print -u2 "adb is required"; exit 2; }
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"

remote_jsonl="$(
  adb shell run-as "$PACKAGE" find files/evidence -name receiver.jsonl \
    -type f -maxdepth 3 -print 2>/dev/null | tr -d '\r' | head -1
)"
[[ -n "$remote_jsonl" ]] || { print -u2 "receiver app-private evidence is missing"; exit 1; }
remote_directory="${remote_jsonl:h}"

adb exec-out run-as "$PACKAGE" cat "$remote_jsonl" >"$OUTPUT_DIR/receiver.jsonl"
jq -e -c . "$OUTPUT_DIR/receiver.jsonl" >/dev/null || {
  print -u2 "receiver evidence is not valid JSONL"
  exit 1
}

typeset -a remote_pngs
remote_pngs=("${(@f)$(
  adb shell run-as "$PACKAGE" find "$remote_directory" -maxdepth 1 -type f -name '*.png' -print \
    | tr -d '\r'
)}")
for remote_png in "${remote_pngs[@]}"; do
  [[ -n "$remote_png" ]] || continue
  name="${remote_png:t}"
  [[ "$name" == android-decoded-seq-<->.png ]] || {
    print -u2 "unexpected app-private PNG name: $name"
    exit 1
  }
  adb exec-out run-as "$PACKAGE" cat "$remote_png" >"$OUTPUT_DIR/$name"
done

receiver_pid="$(adb shell pidof "$PACKAGE" | tr -d '\r' | awk '{print $1}')"
[[ -n "$receiver_pid" ]] || { print -u2 "Android TV receiver process is not running"; exit 1; }
adb logcat -d --pid="$receiver_pid" -v threadtime >"$OUTPUT_DIR/receiver-logcat.txt"
adb exec-out screencap -p >"$OUTPUT_DIR/receiver-screen.png"

if LC_ALL=C grep -E -i -q \
  '"(sdp|candidate|pairing_code|password|credential)"[[:space:]]*:' \
  "$OUTPUT_DIR/receiver.jsonl"; then
  print -u2 "receiver evidence contains a forbidden signaling or credential field"
  exit 1
fi
if LC_ALL=C grep -E -i -q \
  'a=candidate:|(^|[^[:alpha:]])(sdp|pairing[_ -]?code|turn[_ -]?(username|password))([^[:alpha:]]|$)' \
  "$OUTPUT_DIR/receiver-logcat.txt"; then
  print -u2 "process-filtered logcat contains forbidden signaling or credential content"
  exit 1
fi

print "$OUTPUT_DIR"
