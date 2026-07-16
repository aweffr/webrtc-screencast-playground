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

mkdir -p "$WORK/android-receiver"
jq -nc '[
  {event:"receiver_runtime_initialized",fields:{decoder_low_latency:true}},
  {event:"clock_calibration",fields:{sample_count:5,offset_ns:1,round_trip_ns:2,uncertainty_ns:1}},
  {event:"signaling_connected",fields:{}},
  {event:"receiver_registered",fields:{session_id:"server-session-1"}},
  {event:"session_paired",fields:{session_id:"server-session-1"}},
  {event:"sdp_offer_received",fields:{}},
  {event:"sdp_answer_sent",fields:{}},
  {event:"remote_video_playing",fields:{}},
  {event:"rtc_stats",fields:{frames_decoded:2,codec:"video/H264",frame_width:1920,frame_height:1080,path_status:"accepted",local_path_type:"host",remote_path_type:"host",path_protocol:"udp"}}
] | .[] | . + {schema_version:1,run_id:"android-run-1",monotonic_ns:1}' \
  >"$WORK/android-receiver/receiver.jsonl"
"$ROOT/scripts/verify-diagnostics.sh" \
  "$WORK/android-receiver" "$WORK/sender" direct-baseline >/dev/null

mkdir -p "$WORK/relay-android-receiver" "$WORK/relay-sender"
jq 'if .event == "rtc_stats" then
  .fields.local_path_type = "relay"
  | .fields.remote_path_type = "host"
  else . end' "$WORK/android-receiver/receiver.jsonl" \
  >"$WORK/relay-android-receiver/receiver.jsonl"
jq 'if .event == "selected_path" then
  .fields.local_candidate_type = "relay"
  | .fields.remote_candidate_type = "host"
  elif .event == "rtc_stats" then
  .fields.selected_path.local_candidate_type = "relay"
  | .fields.selected_path.remote_candidate_type = "host"
  else . end' "$WORK/sender/metrics.jsonl" >"$WORK/relay-sender/metrics.jsonl"
if "$ROOT/scripts/verify-diagnostics.sh" \
  "$WORK/relay-android-receiver" "$WORK/relay-sender" production-relay \
  >/dev/null 2>&1; then
  print -u2 "verifier accepted a production path whose remote candidate was not relay"
  exit 1
fi

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

mkdir -p "$WORK/artifacts" "$WORK/versioned"
print "safe log output" >"$WORK/artifacts/receiver.log"
print '{"summary":"safe"}' >"$WORK/versioned/baseline.json"
"$ROOT/scripts/scan-artifacts-for-configured-secrets.sh" \
  --config "$WORK/runtime.json" "$WORK/artifacts" "$WORK/versioned" >/dev/null

print "unexpected credential: $password" >"$WORK/artifacts/sender.log"
if "$ROOT/scripts/scan-artifacts-for-configured-secrets.sh" \
  --config "$WORK/runtime.json" "$WORK/artifacts" "$WORK/versioned" >/dev/null 2>&1; then
  print -u2 "artifact scanner accepted a configured TURN password"
  exit 1
fi
rm "$WORK/artifacts/sender.log"

print "unexpected credential: $username" >"$WORK/versioned/baseline.md"
if "$ROOT/scripts/scan-artifacts-for-configured-secrets.sh" \
  --config "$WORK/runtime.json" "$WORK/artifacts" "$WORK/versioned" >/dev/null 2>&1; then
  print -u2 "artifact scanner accepted a configured TURN username in versioned output"
  exit 1
fi

bootstrap_root="$WORK/bootstrap"
bootstrap_artifacts="$bootstrap_root/artifacts"
bootstrap_vendor="$bootstrap_root/Vendor"
bootstrap_release="$bootstrap_root/release"
bootstrap_bin="$bootstrap_root/bin"
framework_stage="$bootstrap_root/framework-stage/WebRTC.xcframework"
aar_stage="$bootstrap_root/aar-stage"
mkdir -p \
  "$bootstrap_artifacts" \
  "$bootstrap_release" \
  "$bootstrap_bin" \
  "$framework_stage/macos-arm64_x86_64/WebRTC.framework/Versions/A" \
  "$aar_stage/jni/arm64-v8a"
print '<plist version="1.0"><dict/></plist>' >"$framework_stage/Info.plist"
print 'universal-framework-binary' >"$framework_stage/macos-arm64_x86_64/WebRTC.framework/WebRTC"
print 'versioned-framework-binary' >"$framework_stage/macos-arm64_x86_64/WebRTC.framework/Versions/A/WebRTC"
(cd "$bootstrap_root/framework-stage" && zip -qry \
  "$bootstrap_artifacts/WebRTC-m150-macos-universal.xcframework.zip" WebRTC.xcframework)
print '<manifest package="org.webrtc"/>' >"$aar_stage/AndroidManifest.xml"
print 'classes' >"$aar_stage/classes.jar"
print 'jni' >"$aar_stage/jni/arm64-v8a/libjingle_peerconnection_so.so"
(cd "$aar_stage" && zip -qry \
  "$bootstrap_artifacts/webrtc-m150-android-arm64-v8a.aar" \
  AndroidManifest.xml classes.jar jni/arm64-v8a/libjingle_peerconnection_so.so)
(cd "$bootstrap_artifacts" && shasum -a 256 \
  WebRTC-m150-macos-universal.xcframework.zip \
  webrtc-m150-android-arm64-v8a.aar >SHA256SUMS)
mv "$bootstrap_artifacts"/*.zip "$bootstrap_release/"
mv "$bootstrap_artifacts"/*.aar "$bootstrap_release/"
cat >"$bootstrap_bin/lipo" <<'SH'
#!/bin/zsh
[[ "$1" == "-archs" && -f "$2" ]] || exit 2
print 'arm64 x86_64'
SH
chmod +x "$bootstrap_bin/lipo"

PATH="$bootstrap_bin:$PATH" \
ARTIFACTS_DIR="$bootstrap_artifacts" \
VENDOR_DIR="$bootstrap_vendor" \
WEBRTC_RELEASE_BASE_URL="file://$bootstrap_release" \
  "$ROOT/scripts/bootstrap-webrtc.sh" >/dev/null
[[ -f "$bootstrap_vendor/WebRTC.xcframework/Info.plist" ]] || {
  print -u2 "bootstrap ignored the isolated vendor destination"
  exit 1
}
[[ -f "$bootstrap_artifacts/webrtc-m150-android-arm64-v8a.aar" ]] || {
  print -u2 "bootstrap did not preserve the verified Android AAR"
  exit 1
}

print 'corrupt' >>"$bootstrap_artifacts/webrtc-m150-android-arm64-v8a.aar"
if PATH="$bootstrap_bin:$PATH" \
  ARTIFACTS_DIR="$bootstrap_artifacts" \
  VENDOR_DIR="$bootstrap_vendor" \
  WEBRTC_RELEASE_BASE_URL="file://$bootstrap_release" \
    "$ROOT/scripts/bootstrap-webrtc.sh" >/dev/null 2>&1; then
  print -u2 "bootstrap accepted an AAR with a mismatched checksum"
  exit 1
fi

fake_android_home="$WORK/fake-android-home"
fake_home="$WORK/fake-home"
fake_tools="$WORK/fake-android-tools"
mkdir -p "$fake_android_home" "$fake_home" "$fake_tools"
cat >"$fake_tools/sdkmanager" <<'SH'
#!/bin/zsh
if [[ "$1" == "--list_installed" ]]; then
  [[ -f "$FAKE_ANDROID_STATE/image-installed" ]] && \
    print 'system-images;android-31;android-tv;arm64-v8a'
  exit 0
fi
read -r _confirmation
mkdir -p "$FAKE_ANDROID_STATE"
touch "$FAKE_ANDROID_STATE/image-installed"
SH
cat >"$fake_tools/avdmanager" <<'SH'
#!/bin/zsh
if [[ "$1 $2" == "list avd" ]]; then
  [[ -f "$FAKE_ANDROID_STATE/avd-created" ]] && \
    print '    Name: WebRTCScreencast_TV_API_31'
  exit 0
fi
read -r _confirmation
mkdir -p "$HOME/.android/avd/WebRTCScreencast_TV_API_31.avd" "$FAKE_ANDROID_STATE"
print 'image.sysdir.1=system-images/android-31/android-tv/arm64-v8a/' \
  >"$HOME/.android/avd/WebRTCScreencast_TV_API_31.avd/config.ini"
touch "$FAKE_ANDROID_STATE/avd-created"
SH
chmod +x "$fake_tools/sdkmanager" "$fake_tools/avdmanager"

HOME="$fake_home" \
ANDROID_HOME="$fake_android_home" \
SDKMANAGER="$fake_tools/sdkmanager" \
AVDMANAGER="$fake_tools/avdmanager" \
FAKE_ANDROID_STATE="$WORK/fake-android-state" \
  "$ROOT/scripts/provision-android-tv-avd.sh" >/dev/null
[[ -f "$WORK/fake-android-state/image-installed" && \
   -f "$WORK/fake-android-state/avd-created" ]] || {
  print -u2 "Android TV provisioning did not install the image and create the AVD"
  exit 1
}

cat >"$fake_tools/adb" <<'SH'
#!/bin/zsh
set -euo pipefail
state="$FAKE_ANDROID_NETWORK_STATE"
mkdir -p "$state"
case "$*" in
  'shell ip route get 10.0.2.2')
    [[ -f "$state/route-ready" ]]
    ;;
  'shell cmd wifi connect-network AndroidWifi open')
    touch "$state/connect-requested"
    [[ "${FAKE_ANDROID_NETWORK_NEVER_CONNECT:-0}" == 1 ]] || touch "$state/route-ready"
    ;;
  *)
    print -u2 "unexpected fake adb call: $*"
    exit 2
    ;;
esac
SH
chmod +x "$fake_tools/adb"

network_state="$WORK/fake-android-network"
FAKE_ANDROID_NETWORK_STATE="$network_state" \
ADB="$fake_tools/adb" \
ANDROID_TV_NETWORK_WAIT_ATTEMPTS=2 \
  "$ROOT/scripts/ensure-android-tv-network.sh" >/dev/null
[[ -f "$network_state/connect-requested" && -f "$network_state/route-ready" ]] || {
  print -u2 "Android TV network recovery did not reconnect AndroidWifi"
  exit 1
}

rm -f "$network_state/connect-requested"
FAKE_ANDROID_NETWORK_STATE="$network_state" \
ADB="$fake_tools/adb" \
ANDROID_TV_NETWORK_WAIT_ATTEMPTS=2 \
  "$ROOT/scripts/ensure-android-tv-network.sh" >/dev/null
[[ ! -e "$network_state/connect-requested" ]] || {
  print -u2 "Android TV network recovery changed an already ready route"
  exit 1
}

rm -f "$network_state/route-ready"
if FAKE_ANDROID_NETWORK_STATE="$network_state" \
  FAKE_ANDROID_NETWORK_NEVER_CONNECT=1 \
  ADB="$fake_tools/adb" \
  ANDROID_TV_NETWORK_WAIT_ATTEMPTS=2 \
    "$ROOT/scripts/ensure-android-tv-network.sh" >/dev/null 2>&1; then
  print -u2 "Android TV network recovery accepted an unavailable host route"
  exit 1
fi

print "script verifier tests passed"

baseline_plan="$($ROOT/scripts/run-android-tv-baseline.sh \
  --dry-run --skip-macos-build --runtime-config /not/read/in/dry-run)"
expected_plan=$'functional direct-baseline main\nfunctional direct-baseline virtual\nfunctional production-relay main\nfunctional production-relay virtual\nbaseline 1 direct-baseline virtual\nbaseline 1 production-relay virtual\nbaseline 2 direct-baseline virtual\nbaseline 2 production-relay virtual\nbaseline 3 direct-baseline virtual\nbaseline 3 production-relay virtual'
[[ "$baseline_plan" == "$expected_plan" ]] || {
  print -u2 "Android TV baseline dry-run did not preserve the approved functional and alternating baseline order"
  exit 1
}
