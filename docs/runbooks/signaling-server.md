# Signaling server runbook

## Responsibility

The Go service creates receiver-first one-time pairing codes and transparently relays validated SDP, trickle ICE and hangup messages between exactly one Sender and one Receiver. It never handles media, modifies SDP or reads coturn credentials.

## Local run

```bash
./scripts/run-local-signaling.sh
curl http://127.0.0.1:8080/healthz
curl http://127.0.0.1:8080/metrics
```

The WebSocket endpoint is `ws://127.0.0.1:8080/ws`. The same binary accepts plain HTTP only; a TLS reverse proxy or Traefik Ingress provides HTTPS/WSS when desired.

## Configuration

| Environment | Default | Meaning |
| --- | --- | --- |
| `LISTEN_ADDR` | `:8080` | HTTP listen address |
| `PAIRING_TTL` | `10m` | Unused pairing-code lifetime |
| `MAX_PENDING` | `1000` | Maximum pending receivers |
| `MAX_ACTIVE` | `1000` | Maximum paired sessions |
| `READ_HEADER_TIMEOUT` | `5s` | HTTP header deadline |
| `IDLE_TIMEOUT` | `60s` | HTTP idle deadline |
| `SHUTDOWN_TIMEOUT` | `10s` | Graceful shutdown deadline |
| `RATE_LIMIT_BURST` | `20` | Register/join burst per source IP |
| `RATE_LIMIT_INTERVAL` | `1s` | Refill interval per token |

All duration values use Go duration syntax. Invalid or non-positive values stop startup with exit code 2.

## K3s deployment

[`deploy/k3s/signaling.yaml`](../../deploy/k3s/signaling.yaml) is an example targeting an `apps`
namespace with placeholder registry, hostname, and TLS Secret values. Replace them, pin the image
immutably, validate the manifest, and apply it through your deployment workflow.

The deployment intentionally uses one replica and `Recreate`. Pairing/session state is in memory, so multiple replicas would split Receiver and Sender across independent registries unless a shared registry or routing affinity were added. A restart ends existing sessions and clients pair again.

Publish an immutable multi-architecture image because the development Mac is arm64 while K3s node architecture is an independent deployment fact:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag ghcr.io/your-org/webrtc-screencast-signaling:<immutable-version> \
  --push \
  server
```

Replace the manifest image only after the registry contains both platforms.

## Observability

`/metrics` returns Prometheus text counters and gauges. Standard output is one JSON object per event. Logs never contain pairing codes, SDP, ICE candidate strings or TURN credentials; session and peer identifiers are shortened.

Useful checks:

```bash
curl -fsS http://127.0.0.1:8080/healthz
curl -fsS http://127.0.0.1:8080/metrics | grep '^screencast_signaling_'
```

## Rollback

Roll back to the previous immutable container tag and recreate the single Pod. Active sessions end during either rollout or rollback because the registry is intentionally ephemeral.
