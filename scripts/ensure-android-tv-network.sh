#!/bin/zsh
set -euo pipefail

ADB="${ADB:-adb}"
WAIT_ATTEMPTS="${ANDROID_TV_NETWORK_WAIT_ATTEMPTS:-30}"

[[ "$WAIT_ATTEMPTS" == <-> && "$WAIT_ATTEMPTS" -ge 1 ]] || {
  print -u2 "ANDROID_TV_NETWORK_WAIT_ATTEMPTS must be a positive integer"
  exit 2
}

route_ready() {
  "$ADB" shell ip route get 10.0.2.2 >/dev/null 2>&1
}

if route_ready; then
  print "Android TV emulator host route ready"
  exit 0
fi

"$ADB" shell cmd wifi connect-network AndroidWifi open >/dev/null
for _ in $(seq 1 "$WAIT_ATTEMPTS"); do
  if route_ready; then
    print "Android TV emulator host route restored through AndroidWifi"
    exit 0
  fi
  sleep 1
done

print -u2 "Android TV emulator cannot route to host alias 10.0.2.2"
exit 1
