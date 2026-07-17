# Single-Mac dual-process E2E

This procedure runs a real Go WebSocket server and two independent app processes. It does not use an in-process PeerConnection loopback.

## Automated run

Grant Screen Recording permission first, then run both direct sources:

```bash
./scripts/run-dual-client.sh --profile direct-baseline --source main
./scripts/run-dual-client.sh --profile direct-baseline --source virtual
```

The main-display run can verify a stable initial frame without synthetic motion. A newly created virtual display is empty until it contains a window; during the bounded virtual run, move any ordinary app window onto the 1920×1080 extended display so the verifier can observe real pixels. This is only a minimal media stimulus, not a content-quality corpus.

The Sender prevents idle display sleep while capture is active. If a headless test starts after the physical display has already slept, wake it before launching the main-display run (for example, `caffeinate -u -t 2`); the activity assertion prevents a subsequent idle transition but cannot reactivate an already-inactive display.

The script:

1. builds the app and signaling binary;
2. allocates a random loopback signaling port;
3. starts Receiver first and waits for an atomically written mode-`0600` pairing-code file;
4. starts Sender as a second PID and consumes that code once;
5. gives the session a bounded run window, performs graceful app teardown, and preserves all artifacts;
6. requires diagnostics to prove HEVC encode/decode/render and a valid selected path.

Every run prints its temporary artifact root, process exit statuses and both session directories. Artifacts are preserved on success and failure.

For production relay:

```bash
./scripts/run-dual-client.sh \
  --profile production-relay \
  --source main \
  --runtime-config /absolute/path/to/runtime.json

./scripts/run-dual-client.sh \
  --profile production-relay \
  --source virtual \
  --runtime-config /absolute/path/to/runtime.json
```

Relay validation refuses empty TURN fields and requires selected candidate evidence to be `relay` over `udp` in both processes. It does not weaken policy when same-host NAT hairpinning or external UDP allocation fails; use the printed signaling/app logs and session directories as blocker evidence.

## Evidence verifier

Re-run verification for preserved artifacts with:

```bash
./scripts/verify-diagnostics.sh \
  /path/to/receiver-session \
  /path/to/sender-session \
  direct-baseline
```

The verifier fails on missing pairing, negotiation, capture, HEVC encoder/QP, HEVC decoder, render or selected-path evidence. It also requires both processes to contain exactly one identical canonical `session_id` and rejects raw libwebrtc log artifacts. For a virtual source it requires creation and removal events. When a runtime config is passed as the fourth argument, both directories are scanned for the configured TURN values without printing them.

## Permission blocker

Screen Recording is an external macOS authorization. If permission is absent, the expected bounded result is:

- two app PIDs and real signaling/SDP/ICE evidence may exist;
- Sender records `capture_failed` or fails before `capture_started`;
- `verify-diagnostics.sh` fails rather than inferring media success.

Grant permission in System Settings, relaunch both app processes, and rerun. Do not treat negotiation alone as a completed media E2E.
