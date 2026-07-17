# Local development

## Prerequisites

- macOS 14 or newer on Apple Silicon for the current local package.
- Xcode, XcodeGen, Go 1.24+, `jq`, `curl` and standard macOS command-line tools.
- Screen Recording permission for the built `WebRTCScreencast.app` before capture can produce frames.

Bootstrap and generate the Xcode project:

```bash
./scripts/bootstrap-webrtc.sh
cd apps/macos && xcodegen generate
```

Run tests and a signed local build:

```bash
make test-go
make test-macos
make build-macos
```

`make verify` runs all three plus `git diff --check`.

The environment-dependent automated media baseline is deliberately separate:

```bash
RUNTIME_CONFIG="$PWD/secrets/runtime.json" make media-baseline
```

It requires Screen Recording permission, FFmpeg with `libvmaf`, and a runtime file whose TURN URL explicitly selects UDP. The runner alternates Direct and forced TURN/UDP three times with fresh processes and writes raw evidence to `artifacts/media-baseline/<run-id>/`. It refuses to start or continue when either managed virtual-display name remains online, so one failed cleanup cannot contaminate later rounds. High latency or low image scores are data, not failure thresholds; missing HEVC media, an invalid selected path, missing marker correlation, virtual-display residue, or report-generation failure returns non-zero.

Inspect the lifecycle invariant without changing display or power state:

```bash
./scripts/check-virtual-display-state.py --expect 0
```

A pre-existing orphaned `CGVirtualDisplay` belongs to the process that created it and cannot be released by a new process. Log out and back in, or reboot once, then wake and unlock the Mac before retrying. The checker and baseline runner never wake, remove or reconfigure displays themselves.

The signaling service bounds all WebSocket connections before upgrade (`MAX_CONNECTIONS`) and applies a separate per-source connection-attempt bucket. `TRUSTED_PROXY_CIDRS` is empty for direct local use. The K3s manifest trusts the cluster pod CIDR used by the Traefik hop; requests whose immediate peer is outside that CIDR ignore forwarded headers. Never configure a public/untrusted CIDR.

## Manual two-window workflow

Start signaling:

```bash
LISTEN_ADDR=127.0.0.1:8080 ./scripts/run-local-signaling.sh
```

Launch two independent instances of the app from Xcode or with `open -n`. In the Receiver, select the connection profile and click **开始接收**. Enter its one-time eight-character code in the Sender, select the same profile and a screen source, then click **开始投屏**.

For a local direct comparison, both processes use `direct-baseline`. Production validation must use `production-relay`; its selected path is rejected unless RTCStats proves a relay candidate over UDP.

## Sender CLI launch mode

The CLI mode is the same signed `.app`, window, Screen Recording permission identity and cleanup
path as the interactive client; there is no separate headless target. Build once, then invoke the
bundle executable with the Android TV pairing code:

```bash
APP="$PWD/DerivedData/Build/Products/Debug/WebRTCScreencast.app/Contents/MacOS/WebRTCScreencast"

"$APP" \
  --role sender \
  --profile direct-baseline \
  --pairing-code AB12-CD34 \
  --source main \
  --run-seconds 30
```

Use `--source virtual` for the managed 1920×1080 extended display. Automation that receives its
code asynchronously may keep using `--pairing-code-file`; the two pairing-code options are
mutually exclusive. A direct `--pairing-code` value is normalized before the session starts, and
invalid or missing values fail with a launch error rather than opening a partially configured
Sender.

The bundled CastTuning config uses schema 3 and keeps Apple VideoToolbox low-latency rate control
disabled while requesting the ordinary HEVC encoder with spatial adaptive QP at its system default.
Select the sender codec set and order separately with `video_codec_policy` in runtime JSON.

## Screen capture permission

If the Sender reports that capture is unavailable, follow the [capture permission runbook](macos-capture-permission.md). The permission helper and app must see at least one shareable display; a result such as `displays=0` means media E2E evidence cannot be claimed even when signaling and PeerConnection negotiation succeed.

## Diagnostics

Each process writes a distinct `<local-run-id>-sender` or `<local-run-id>-receiver` directory containing:

- `metrics.jsonl` with immediate lifecycle events and one-second RTC/capture/render samples. Records buffered before pairing are committed with the canonical server-assigned `session_id`, so Sender, Receiver and server evidence share one join key.

Raw `RTCFileLogger` and RTC event logs are intentionally disabled because they can contain ICE candidates and transient ICE ufrag/password values that cannot be reliably redacted. The UI first copies a private snapshot, then scans, hashes and archives that exact snapshot as a SHA-256-manifested zip of structured diagnostics. Export fails closed if configured TURN credentials or known raw libwebrtc artifacts, including hidden files, appear in the snapshot.
