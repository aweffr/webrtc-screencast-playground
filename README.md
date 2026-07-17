# WebRTC Screencast Playground

[简体中文](README_CN.md)

A reference implementation for low-latency, one-way HEVC/H.264 desktop casting from a native macOS
Sender to an Android TV Receiver. A small Go WebSocket service issues one-time pairing codes and
relays WebRTC signaling; media travels directly over ICE or through a configured TURN/UDP relay.

The repository is intentionally a sample, not a production SDK. It keeps the complete path easy to
inspect: ScreenCaptureKit → VideoToolbox/WebRTC M150 → UDP → Android WebRTC decoder → TV renderer.

## What is included

- **macOS app (Swift 6):** GUI Sender, same-app CLI launch mode, main-display mirror, and a private
  1920×1080 virtual extended display. Main-display mirror uses a luma-based static-clarity mode
  with H264-only, H265-only, prefer-H265, and default prefer-H264 sender policies. Static clarity
  requests a fresh keyframe and runs the stable picture at about 1 fps.
- **Android TV app (Java 8-compatible source):** TV-only launcher, receiver-first registration,
  one-time pairing-code screen, HEVC playback, D-pad-safe recovery, and app-private telemetry.
- **Signaling server (Go):** `/ws`, `/clock`, `/healthz`, and Prometheus `/metrics`; it never carries
  media or TURN credentials.
- **Network profiles:** `direct-baseline` for local comparison and `production-relay` for forced
  `relay/relay + UDP`. TURN/TCP is deliberately unsupported.
- **Observability:** signaling timing, clock calibration, capture/encode/decode/render events,
  normalized RTCStats, selected-path verification, static-clarity transitions/keyframes, and
  redacted JSONL diagnostics.
- **Automated evidence:** calibrated software-marker latency plus 1920×1080 screenshots, PSNR,
  SSIM, VMAF reference values, and heatmaps. These metrics are not optical glass-to-glass latency.

## Scope and constraints

- The validated reference environment is one Apple Silicon Mac and an API 31 arm64-v8a Android TV
  emulator configured at 1920×1080. Real TV hardware remains a follow-up.
- The virtual display uses private `CGVirtualDisplay` compatibility declarations and is not intended
  for App Store distribution.
- Cursor capture is always enabled.
- Global keyboard/mouse forwarding, TURN/TCP, public signaling deployment, and Apple
  `EnableLowLatencyRateControl` activation are out of the initial scope.
- The automated macOS-to-Android path explicitly uses `h265-only`. Without a
  `video_codec_policy`, the Sender prefers H264 and retains H265 as fallback.

## Repository layout

```text
apps/macos/        SwiftUI macOS Sender and legacy macOS Receiver baseline
apps/android-tv/   Java Android TV Receiver reference app
server/            Go WebSocket signaling and clock-calibration service
config/            Non-secret runtime and media-tuning examples
scripts/           Bootstrap, verification, E2E, evidence, and analysis tools
baselines/         Versioned aggregate reports; raw screenshots/metrics stay ignored
deploy/k3s/        Example signaling-server Kubernetes manifest
docs/              Architecture decisions, research, runbooks, plans, and follow-ups
```

## Prerequisites

- Apple Silicon Mac running macOS 14 or newer
- Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Go 1.24+
- JDK 17 for Gradle/AGP (the packaged M150 AAR remains Java 8 classfile-compatible)
- Android SDK command-line tools and emulator
- `jq`, `curl`, Python 3, and FFmpeg built with `libvmaf` for quantitative baselines

## Bootstrap and verify

The bootstrap verifies the pinned M150 macOS arm64 archive and Android AAR produced by
[`aweffr/my-webrtc-builds`](https://github.com/aweffr/my-webrtc-builds), then stages only ignored
local dependencies.

For a locally built experiment artifact, set `WEBRTC_MACOS_TAR_GZ` to an
absolute tar path. The override remains machine-local; bootstrap still verifies
both pinned checksums and validates the extracted arm64 framework layout.

```bash
git clone https://github.com/aweffr/webrtc-screencast-playground.git
cd webrtc-screencast-playground

./scripts/bootstrap-webrtc.sh
make verify
```

`make verify` runs Go race tests, macOS tests/build, Android unit/lint/two-flavor builds, script and
analysis tests, artifact checks, and `git diff --check`.

## Run the reference path

### 1. Start signaling

```bash
./scripts/run-local-signaling.sh
```

### 2. Configure and launch Android TV

Provision the validated emulator once:

```bash
./scripts/provision-android-tv-avd.sh
```

For Direct UDP, the committed defaults use `ws://10.0.2.2:8080/ws`. For TURN/UDP, copy the
credential-free example into the ignored debug resource path and replace its placeholder values:

```bash
mkdir -p apps/android-tv/app/src/debug/res/values
cp apps/android-tv/app/reference_runtime.local.xml.example \
  apps/android-tv/app/src/debug/res/values/reference_runtime.local.xml
```

Build and install the matching flavor:

```bash
export JAVA_HOME=$(/usr/libexec/java_home -v 17)
./apps/android-tv/gradlew -p apps/android-tv installDirectBaselineDebug
```

Opening the TV app registers the Receiver and displays an eight-character pairing code.

### 3. Launch the macOS Sender

Build once, grant the resulting app Screen Recording permission, then either use its GUI or invoke
the same app executable in CLI mode:

```bash
make build-macos

APP="$PWD/DerivedData/Build/Products/Debug/WebRTCScreencast.app/Contents/MacOS/WebRTCScreencast"
"$APP" \
  --role sender \
  --profile direct-baseline \
  --pairing-code AB12-CD34 \
  --source main
```

`--source main` captures the complete main display without changing the Mac desktop layout. The
stream canvas remains 1920×1080. When the source is not 16:9, ScreenCaptureKit scales it
proportionally and centers it on a black background, producing pillarbox or letterbox bars as
needed without stretching or cropping the desktop. Use `--source virtual` for the managed
1920×1080 extended display. Use `--profile production-relay --config /absolute/path/to/runtime.json`
for forced TURN/UDP.

## Runtime configuration

Machine-local credentials must never be committed. Start from
[`config/runtime.example.json`](config/runtime.example.json), store the populated file under the
ignored `secrets/` directory with mode `0600`, and keep the TURN URL explicit:

```text
turn:turn.example.invalid:3478?transport=udp
```

The client accepts both `ws://` and `wss://`; HTTPS/WSS is not forced by the sample. See the
[runtime configuration runbook](docs/runbooks/runtime-configuration.md) for every field and the
local secret scan.

## Automated Android TV baseline

After the emulator is running, the runtime config exists, and Screen Recording permission is
effective:

```bash
./scripts/run-android-tv-baseline.sh \
  --runtime-config "$PWD/secrets/runtime.json"
```

The runner executes four functional sessions (Direct/TURN × main/virtual), followed by three
alternating Direct/TURN 80-second virtual-chart measurements. Raw evidence remains ignored under
`artifacts/android-tv-e2e/`; safe aggregate reports are versioned under `baselines/`.

The current single-Mac emulator baseline is summarized in
[`baselines/2026-07-15-3bc825c-android-tv.md`](baselines/2026-07-15-3bc825c-android-tv.md): Direct
software-marker E2E p50/p95 is 62.24/77.39 ms; forced TURN/UDP is 70.58/84.69 ms. Median
capture-to-Android VMAF reference is 96.50 and 96.38 respectively. No performance gate is inferred
from these measurements.

## Documentation

Start with the [documentation index](docs/README.md). The most useful operational guides are:

- [Local development](docs/runbooks/local-development.md)
- [Android TV E2E](docs/runbooks/android-tv-e2e.md)
- [macOS capture permission](docs/runbooks/macos-capture-permission.md)
- [Signaling server](docs/runbooks/signaling-server.md)
- [Architecture vocabulary](CONTEXT.md)

## Security and diagnostics

Runtime credentials, populated Android XML, downloaded binaries, build outputs, raw screenshots,
and session metrics are ignored. Structured recorders redact signaling payloads, and automated
runs scan retained outputs for the configured TURN values and full pairing code before success.
See [SECURITY.md](SECURITY.md) for vulnerability reporting.

## License

Licensed under the [Apache License 2.0](LICENSE). Private virtual-display compatibility declarations
include third-party MIT-licensed work documented in [NOTICE](NOTICE).
