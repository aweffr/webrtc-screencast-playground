#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
export LISTEN_ADDR="${LISTEN_ADDR:-127.0.0.1:8080}"

cd "$ROOT/server"
exec go run ./cmd/signaling-server
