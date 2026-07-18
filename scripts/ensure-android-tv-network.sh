#!/bin/zsh
set -euo pipefail

ADB="${ADB:-adb}"
WAIT_ATTEMPTS="${ANDROID_TV_NETWORK_WAIT_ATTEMPTS:-30}"
HOST_HTTP_PORT=""

if (( $# )); then
  [[ $# -eq 2 && "$1" == --host-http-port ]] || {
    print -u2 "usage: $0 [--host-http-port port]"
    exit 2
  }
  HOST_HTTP_PORT="$2"
fi

[[ "$WAIT_ATTEMPTS" == <-> && "$WAIT_ATTEMPTS" -ge 1 ]] || {
  print -u2 "ANDROID_TV_NETWORK_WAIT_ATTEMPTS must be a positive integer"
  exit 2
}
[[ -z "$HOST_HTTP_PORT" || ( "$HOST_HTTP_PORT" == <-> \
    && "$HOST_HTTP_PORT" -ge 1 && "$HOST_HTTP_PORT" -le 65535 ) ]] || {
  print -u2 "--host-http-port must be an integer between 1 and 65535"
  exit 2
}

route_ready() {
  "$ADB" shell ip route get 10.0.2.2 >/dev/null 2>&1
}

if ! route_ready; then
  "$ADB" shell cmd wifi connect-network AndroidWifi open >/dev/null
  for _ in $(seq 1 "$WAIT_ATTEMPTS"); do
    if route_ready; then
      print "Android TV emulator host route restored through AndroidWifi"
      break
    fi
    sleep 1
  done
  route_ready || {
    print -u2 "Android TV emulator cannot route to host alias 10.0.2.2"
    exit 1
  }
else
  print "Android TV emulator host route ready"
fi

[[ -n "$HOST_HTTP_PORT" ]] || exit 0

host_http_ready() {
  local response
  response="$(print -rn -- $'GET /healthz HTTP/1.0\r\nHost: 10.0.2.2\r\nConnection: close\r\n\r\n' \
    | "$ADB" shell toybox nc -w 1 10.0.2.2 "$HOST_HTTP_PORT" 2>/dev/null)" || return 1
  print -r -- "$response" | head -1 | grep -Eq '^HTTP/[0-9.]+ 200([[:space:]]|$)'
}

for _ in $(seq 1 "$WAIT_ATTEMPTS"); do
  if host_http_ready; then
    print "Android TV emulator host HTTP ready"
    exit 0
  fi
  sleep 1
done

print -u2 "Android TV emulator cannot reach host HTTP port $HOST_HTTP_PORT"
exit 1
