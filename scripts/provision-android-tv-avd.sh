#!/bin/zsh
set -euo pipefail

AVD_NAME="${ANDROID_TV_AVD_NAME:-WebRTCScreencast_TV_API_31}"
SYSTEM_IMAGE="system-images;android-31;android-tv;arm64-v8a"
DEVICE="tv_1080p"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
SDKMANAGER="${SDKMANAGER:-$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager}"
AVDMANAGER="${AVDMANAGER:-$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager}"

[[ -x "$SDKMANAGER" ]] || SDKMANAGER="$(command -v sdkmanager)"
[[ -x "$AVDMANAGER" ]] || AVDMANAGER="$(command -v avdmanager)"

install_system_image() {
  setopt localoptions no_pipe_fail
  yes | "$SDKMANAGER" "$SYSTEM_IMAGE"
}

if ! "$SDKMANAGER" --list_installed | grep -Fq "$SYSTEM_IMAGE"; then
  install_system_image
fi

avd_path="$HOME/.android/avd/$AVD_NAME.avd"
if "$AVDMANAGER" list avd | grep -Fq "Name: $AVD_NAME"; then
  [[ -f "$avd_path/config.ini" ]] || {
    print -u2 "AVD is registered but config is missing: $avd_path/config.ini"
    exit 1
  }
  grep -Fq "image.sysdir.1=system-images/android-31/android-tv/arm64-v8a/" "$avd_path/config.ini" || {
    print -u2 "Existing AVD $AVD_NAME does not use $SYSTEM_IMAGE"
    exit 1
  }
  print "Android TV AVD already ready: $AVD_NAME"
  exit 0
fi

print no | "$AVDMANAGER" create avd \
  --force \
  --name "$AVD_NAME" \
  --package "$SYSTEM_IMAGE" \
  --device "$DEVICE"
print "Android TV AVD created: $AVD_NAME"
