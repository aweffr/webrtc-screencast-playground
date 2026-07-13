# Single-Mac dual-process E2E

This procedure runs a real Go WebSocket server and two independent app processes. It does not use an in-process PeerConnection loopback.

## Automated run

Grant Screen Recording permission first, then run both direct sources:

```bash
./scripts/run-dual-client.sh --profile direct-baseline --source main
./scripts/run-dual-client.sh --profile direct-baseline --source virtual
```

The script:

1. builds the app and signaling binary;
2. allocates a random loopback signaling port;
3. starts Receiver first and waits for an atomically written mode-`0600` pairing-code file;
4. starts Sender as a second PID and consumes that code once;
5. gives the session a bounded run window, performs graceful app teardown, and preserves all artifacts;
6. requires diagnostics to prove H.264 encode/decode/render and a valid selected path.

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

The verifier fails on missing pairing, negotiation, capture, H.264 encode, H.264 decode, render or selected-path evidence. For a virtual source it also requires creation and removal events. When a runtime config is passed as the fourth argument, both directories are scanned for the configured TURN values without printing them.

## Expected permission blocker

Screen Recording is an external macOS authorization. If permission is absent, the expected bounded result is:

- two app PIDs and real signaling/SDP/ICE evidence may exist;
- Sender records `capture_failed` or fails before `capture_started`;
- `verify-diagnostics.sh` fails rather than inferring media success.

Grant permission in System Settings, relaunch both app processes, and rerun. Do not treat negotiation alone as a completed media E2E.
