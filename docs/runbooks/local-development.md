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

The signaling service bounds all WebSocket connections before upgrade (`MAX_CONNECTIONS`) and applies a separate per-source connection-attempt bucket. `TRUSTED_PROXY_CIDRS` is empty for direct local use. The K3s manifest trusts the cluster pod CIDR used by the Traefik hop; requests whose immediate peer is outside that CIDR ignore forwarded headers. Never configure a public/untrusted CIDR.

## Manual two-window workflow

Start signaling:

```bash
LISTEN_ADDR=127.0.0.1:8080 ./scripts/run-local-signaling.sh
```

Launch two independent instances of the app from Xcode or with `open -n`. In the Receiver, select the connection profile and click **开始接收**. Enter its one-time eight-character code in the Sender, select the same profile and a screen source, then click **开始投屏**.

For a local direct comparison, both processes use `direct-baseline`. Production validation must use `production-relay`; its selected path is rejected unless RTCStats proves a relay candidate over UDP.

## Screen capture permission

If the Sender reports that capture is unavailable, follow the [capture permission runbook](macos-capture-permission.md). The permission helper and app must see at least one shareable display; a result such as `displays=0` means media E2E evidence cannot be claimed even when signaling and PeerConnection negotiation succeed.

## Diagnostics

Each process writes a distinct `<local-run-id>-sender` or `<local-run-id>-receiver` directory containing:

- `metrics.jsonl` with immediate lifecycle events and one-second RTC/capture/render samples. Records buffered before pairing are committed with the canonical server-assigned `session_id`, so Sender, Receiver and server evidence share one join key.

Raw `RTCFileLogger` and RTC event logs are intentionally disabled because they can contain ICE candidates and transient ICE ufrag/password values that cannot be reliably redacted. The UI first copies a private snapshot, then scans, hashes and archives that exact snapshot as a SHA-256-manifested zip of structured diagnostics. Export fails closed if configured TURN credentials or known raw libwebrtc artifacts, including hidden files, appear in the snapshot.
