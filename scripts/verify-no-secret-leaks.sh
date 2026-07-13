#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CONFIG=""

while (( $# )); do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || { print -u2 "--config requires a path"; exit 2; }
      CONFIG="$2"
      shift 2
      ;;
    *)
      print -u2 "unknown option: $1"
      exit 2
      ;;
  esac
done

[[ -n "$CONFIG" && -r "$CONFIG" ]] || { print -u2 "a readable --config is required"; exit 2; }
command -v jq >/dev/null || { print -u2 "jq is required"; exit 2; }

if git -C "$ROOT" ls-files --error-unmatch "$CONFIG" >/dev/null 2>&1; then
  print -u2 "runtime configuration must not be tracked"
  exit 1
fi

typeset -a secret_fields
secret_fields=(username password)
for field in $secret_fields; do
  secret="$(jq -er ".turn.$field | select(type == \"string\" and length > 0)" "$CONFIG")" || {
    print -u2 "TURN $field is missing"
    exit 1
  }
  if git -C "$ROOT" grep -F -q -- "$secret"; then
    print -u2 "tracked files contain the configured TURN $field"
    exit 1
  fi
done

print "secret scan passed: runtime file is untracked and configured TURN values are absent from tracked files"
