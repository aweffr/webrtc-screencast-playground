# WebRTC Screencast Playground

Minimal native macOS screen casting over WebRTC M150. One app binary runs as either Sender or Receiver; a small Go WebSocket service performs receiver-first pairing and relays SDP, trickle ICE and hangup messages. Media is H.264, one-way, 1920×1080, and never passes through the signaling service.

## Phase-one scope

- Sender: main-display mirror or a private 1920×1080 virtual extended display.
- Receiver: native Metal video rendering.
- Production network profile: relay-only TURN/UDP with fixed credentials supplied by an ignored runtime file.
- Development comparison profile: direct UDP, including two independent processes on one Mac.
- Observability: capture/render telemetry, normalized WebRTC stats, selected path, canonical signaling session ID and fail-closed diagnostic export.

Input forwarding, TURN/TCP, App Store distribution, dynamic ScreenCaptureKit cadence and `EnableLowLatencyRateControl` are intentionally outside phase one. Static content can use M150 zero-hertz behavior, including its approximately one-frame-per-second idle resend.

## Bootstrap and verify

```bash
./scripts/bootstrap-webrtc.sh
make verify
```

The bootstrap verifies the downloaded release checksums, extracts the local WebRTC dependency, and repairs the malformed `Versions/A/WebRTC` link target in the supplied XCFramework from its verified fat top-level binary. Downloaded archives and extracted dependencies remain untracked.

Run the signaling service:

```bash
./scripts/run-local-signaling.sh
```

Run the two-process baseline after granting Screen Recording permission:

```bash
./scripts/run-dual-client.sh --profile direct-baseline --source main
./scripts/run-dual-client.sh --profile direct-baseline --source virtual
```

For relay-only validation, pass an ignored runtime configuration containing the deployed coturn UDP endpoint and credentials:

```bash
./scripts/run-dual-client.sh \
  --profile production-relay \
  --source main \
  --runtime-config /absolute/path/to/runtime.json
```

See [local development](docs/runbooks/local-development.md), [runtime configuration](docs/runbooks/runtime-configuration.md), and [single-Mac E2E](docs/runbooks/single-mac-e2e.md).
