# Runtime configuration

The native app reads JSON from `--config <absolute-path>`. Without that option it reads `~/Library/Application Support/WebRTCScreencast/runtime.json`. The file is machine-local, must be mode `0600`, and must never be committed.

```json
{
  "signaling_url": "ws://127.0.0.1:8080/ws",
  "ice_profile": "production-relay",
  "turn": {
    "url": "turn:turn.example.invalid:3478?transport=udp",
    "username": "REPLACE_LOCALLY",
    "password": "REPLACE_LOCALLY"
  },
  "metrics_directory": "~/Library/Application Support/WebRTCScreencast/Diagnostics",
  "excluded_receiver_pid": null
}
```

| Field | Contract |
| --- | --- |
| `signaling_url` | `ws://` or `wss://`; TLS is optional rather than enforced by the client. |
| `ice_profile` | `production-relay` or `direct-baseline`. |
| `turn.url` | Production only: one explicit `turn:` URL containing `transport=udp`. |
| `turn.username`, `turn.password` | Production only: non-empty fixed credentials for controlled clients. |
| `metrics_directory` | Parent directory for one session directory per app process. `~` is expanded. |
| `excluded_receiver_pid` | Direct baseline Sender only; used by single-Mac comparison to avoid capturing the Receiver window. |

Production mode sets `iceTransportPolicy=relay`, disables TCP candidates, and has no direct fallback. Direct baseline has no TURN server and is not a production setting.

The project-local [`config/runtime.example.json`](../../config/runtime.example.json) intentionally contains empty credentials. Populate an ignored copy from the existing coturn operational secret material without echoing values to the terminal. Validate the copy without printing credentials:

```bash
chmod 600 /absolute/path/to/runtime.json
jq -e '.turn.url | startswith("turn:") and contains("transport=udp")' /absolute/path/to/runtime.json >/dev/null
jq -e '.turn.username | length > 0' /absolute/path/to/runtime.json >/dev/null
jq -e '.turn.password | length > 0' /absolute/path/to/runtime.json >/dev/null
./scripts/verify-no-secret-leaks.sh --config /absolute/path/to/runtime.json
```

The app, signaling logs and metrics never record credentials. SDP, ICE candidate strings and pairing codes are recorded only as `<redacted>` values where an event needs to show that the operation occurred.

To convert the existing strict `KEY=VALUE` coturn file without executing it or printing values:

```bash
./scripts/runtime-config-from-coturn-env.sh \
  --env /absolute/path/to/coturn.env \
  --output ./secrets/runtime.json
```
