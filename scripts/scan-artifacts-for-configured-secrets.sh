#!/bin/zsh
set -euo pipefail

CONFIG=""

usage() {
  print -u2 "usage: $0 --config runtime.json artifact-path [artifact-path ...]"
  exit 2
}

while (( $# )); do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || usage
      CONFIG="$2"
      shift 2
      ;;
    --*) usage ;;
    *) break ;;
  esac
done

[[ -r "$CONFIG" && $# -ge 1 ]] || usage
command -v jq >/dev/null || { print -u2 "jq is required"; exit 2; }

for artifact_path in "$@"; do
  [[ -e "$artifact_path" ]] || {
    print -u2 "artifact path does not exist: $artifact_path"
    exit 1
  }
done

for field in username password; do
  secret="$(jq -r ".turn.$field // empty" "$CONFIG")"
  [[ -z "$secret" ]] && continue
  for artifact_path in "$@"; do
    if LC_ALL=C grep -R -a -F -q -- "$secret" "$artifact_path"; then
      print -u2 "artifact output contains configured TURN $field: $artifact_path"
      exit 1
    fi
  done
done

print "configured TURN secret scan passed for complete artifact output"
