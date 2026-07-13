# macOS WebRTC Screencast Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and verify a native macOS Sender/Receiver app plus Go WebSocket signaling server that closes H.264 screencast sessions on one Mac over direct UDP and forced coturn TURN/UDP while exporting useful metrics.

**Architecture:** One macOS app process owns one Sender or Receiver role and one real PeerConnection; two independent processes provide the single-Mac acceptance topology. A Go server owns only receiver-first pairing and transparent signaling relay. ScreenCaptureKit feeds NV12 frames through a content-aware Frame Gate into WebRTC M150; the receiver renders with Metal and both sides write sanitized JSONL diagnostics.

**Tech Stack:** macOS 14+, Swift 6, SwiftUI/AppKit, ScreenCaptureKit, CoreMedia/CoreVideo, private `CGVirtualDisplay`, WebRTC M150 XCFramework, XcodeGen, Go 1.24, `github.com/coder/websocket` v1.8.15, `net/http`, JSONL, Prometheus text metrics.

**Design:** [`docs/superpowers/specs/2026-07-13-macos-webrtc-screencast-design.md`](../specs/2026-07-13-macos-webrtc-screencast-design.md)

---

### Task 1: Reproducible repository bootstrap

**Files:**
- Modify: `.gitignore`
- Create: `Makefile`
- Create: `scripts/bootstrap-webrtc.sh`
- Create: `config/runtime.example.json`
- Create: `config/cast-tuning.default.json`
- Create: `apps/macos/project.yml`
- Generate: `apps/macos/WebRTCScreencast.xcodeproj`
- Create: `apps/macos/WebRTCScreencast/Resources/Info.plist`

- [x] **Step 1: Add generated/vendor exclusions**

Add these exact entries to `.gitignore`:

```gitignore
Vendor/
.swiftpm/
.build/
server/signaling-server
runtime.json
diagnostics/
```

- [x] **Step 2: Add verified framework bootstrap**

Create `scripts/bootstrap-webrtc.sh` with `set -euo pipefail`, derive the repository root from the script location, run:

```bash
cd "$ROOT/artifacts"
shasum -a 256 -c SHA256SUMS
rm -rf "$ROOT/Vendor/WebRTC.xcframework"
mkdir -p "$ROOT/Vendor"
ditto -x -k WebRTC-m150-macos-universal.xcframework.zip "$ROOT/Vendor"
test -f "$ROOT/Vendor/WebRTC.xcframework/Info.plist"
```

- [x] **Step 3: Add non-secret runtime and CastTuning config**

`config/runtime.example.json` must contain signaling URL, profile, TURN URL with empty username/password, metrics directory and optional receiver PID exclusion. `config/cast-tuning.default.json` must be valid CastTuning schema v1:

```json
{
  "schema_version": 1,
  "profile": "DETAIL_ACTIVE",
  "sender": {
    "max_width": 1920,
    "max_height": 1080,
    "min_fps": 0,
    "max_fps": 30,
    "latest_frame_only": true,
    "content_mode": "TEXT",
    "min_bitrate_bps": 400000,
    "start_bitrate_bps": 2200000,
    "max_bitrate_bps": 3000000,
    "degradation_preference": "MAINTAIN_RESOLUTION"
  },
  "transport": {
    "disable_tcp_candidates": true,
    "screencast_min_bitrate_bps": 400000
  },
  "encoder": {
    "hardware_policy": "PREFER_HARDWARE",
    "realtime": true,
    "allow_frame_reordering": false,
    "h264_profile": "CONSTRAINED_BASELINE",
    "max_frame_delay_count": 1,
    "max_qp": 42
  },
  "recovery": {
    "nack_enabled": true,
    "nack_history_ms": 1000,
    "rtx_enabled": true,
    "fec_mode": "DISABLED",
    "pli_min_interval_ms": 300
  },
  "telemetry": { "sample_interval_ms": 1000, "rtc_event_log": true }
}
```

- [x] **Step 4: Add the XcodeGen project source**

Define one macOS application target and one unit-test target, deployment target 14.0, Swift 6, bridging header, framework search path `../../Vendor`, embed/sign `WebRTC.xcframework`, and link AppKit, SwiftUI, ScreenCaptureKit, CoreMedia, CoreVideo, CoreGraphics, MetalKit and VideoToolbox. Keep App Sandbox disabled and set a unique bundle ID under `cn.aweffr`.

- [x] **Step 5: Bootstrap and generate the project**

Run:

```bash
./scripts/bootstrap-webrtc.sh
cd apps/macos && xcodegen generate
xcodebuild -project WebRTCScreencast.xcodeproj -scheme WebRTCScreencast -showBuildSettings >/dev/null
```

Expected: checksum lines end in `OK`, XcodeGen succeeds, and Xcode can resolve the app target.

- [x] **Step 6: Add Makefile entry points and commit**

Provide `make bootstrap`, `make generate`, `make test-go`, `make test-macos`, `make build-macos`, `make verify`, and commit:

```bash
git add .gitignore Makefile scripts config apps/macos/project.yml apps/macos/WebRTCScreencast.xcodeproj apps/macos/WebRTCScreencast/Resources/Info.plist
git commit -m "build: bootstrap screencast workspace"
```

### Task 2: Go signaling protocol and one-time pairing registry

**Files:**
- Create: `server/go.mod`
- Create: `server/internal/protocol/message.go`
- Create: `server/internal/protocol/message_test.go`
- Create: `server/internal/session/registry.go`
- Create: `server/internal/session/registry_test.go`

- [x] **Step 1: Initialize the Go module**

Run:

```bash
cd server
go mod init github.com/aweffr/webrtc-screencast-playground/server
go get github.com/coder/websocket@v1.8.15
```

- [x] **Step 2: Write failing protocol tests**

Tests must prove: version 1 is required; `message_id` is non-empty and bounded; only the fixed message type set is accepted; register has no payload fields; join accepts exactly an 8-character normalized Crockford code; SDP and ICE fields have explicit length bounds; unknown JSON fields are rejected.

Use this public API:

```go
type Envelope struct {
    Version   int             `json:"version"`
    MessageID string          `json:"message_id"`
    Type      MessageType     `json:"type"`
    Payload   json.RawMessage `json:"payload"`
}

func Decode(data []byte) (Envelope, any, error)
func Encode(messageID string, typ MessageType, payload any) ([]byte, error)
func NormalizePairingCode(string) (string, error)
```

- [x] **Step 3: Run the protocol tests and verify RED**

Run `go test ./internal/protocol -run Test -count=1`.
Expected: compile failure because `Envelope`, `Decode`, `Encode`, and `NormalizePairingCode` do not exist.

- [x] **Step 4: Implement strict protocol decoding**

Use `json.Decoder.DisallowUnknownFields`, reject trailing JSON, define typed payload structs for register, registered, join, paired, SDP, ICE candidate, ICE complete, hangup and protocol error, and return stable sentinel errors. Do not parse SDP content or log payloads.

- [x] **Step 5: Run protocol tests and verify GREEN**

Run `go test ./internal/protocol -count=1`.
Expected: PASS.

- [x] **Step 6: Write failing registry tests**

Use a fake clock and deterministic code generator. Cover receiver creation, 10-minute expiry, one-time join, a second concurrent join losing atomically, removal on disconnect, capacity limits and lookup by peer ID. The public registry API is:

```go
type Registry struct { /* private */ }
type Pair struct { SessionID, ReceiverID, SenderID string }

func NewRegistry(clock Clock, codes CodeGenerator, limits Limits) *Registry
func (r *Registry) RegisterReceiver(receiverID string) (Pending, error)
func (r *Registry) JoinSender(senderID, code string) (Pair, error)
func (r *Registry) RemovePeer(peerID string) (removed *Pair)
func (r *Registry) Expire() []Pending
func (r *Registry) Snapshot() Snapshot
```

- [x] **Step 7: Verify RED, implement registry, verify race-safe GREEN**

Run before implementation: `go test ./internal/session -run Test -count=1` and observe missing API failure. Implement with a mutex around all indexes and cryptographic random session/code generation in production. Then run:

```bash
go test -race ./internal/session -count=50
```

Expected: PASS with no race.

- [x] **Step 8: Commit**

```bash
git add server
git commit -m "feat(signaling): add pairing protocol and registry"
```

### Task 3: WebSocket rendezvous, lifecycle and server observability

**Files:**
- Create: `server/internal/observability/metrics.go`
- Create: `server/internal/observability/metrics_test.go`
- Create: `server/internal/signaling/server.go`
- Create: `server/internal/signaling/peer.go`
- Create: `server/internal/signaling/server_test.go`
- Create: `server/cmd/signaling-server/main.go`

- [ ] **Step 1: Write failing metrics tests**

Assert that counters/gauges render deterministic Prometheus text without labels containing pairing code, SDP, ICE candidate or credentials. Required names:

```text
screencast_signaling_connections_total
screencast_signaling_connections_current
screencast_signaling_pairings_total
screencast_signaling_pending_current
screencast_signaling_sessions_current
screencast_signaling_messages_total
screencast_signaling_rejections_total
screencast_signaling_expired_total
```

- [ ] **Step 2: Verify RED, implement atomic metrics, verify GREEN**

Run `go test ./internal/observability -count=1`, implement an `http.Handler` backed by `atomic.Int64`, and rerun until PASS.

- [ ] **Step 3: Write failing real-WebSocket integration tests**

Use `httptest.NewServer`, convert its URL to `ws://.../ws`, and connect with `coder/websocket`. Tests must cover:

```text
receiver.register → receiver.registered(code, session_id)
sender.join(code) → session.paired on both sockets
sdp.offer / sdp.answer / ice.candidate / ice.complete transparent byte-equivalent relay
session.hangup → peer notification and registry cleanup
disconnect → peer notification and cleanup
invalid order / oversized message / second sender → stable error and close where required
slow writer queue → bounded session close rather than hub blockage
```

- [ ] **Step 4: Run integration tests and verify RED**

Run `go test ./internal/signaling -run Test -count=1`.
Expected: compile failure because `NewServer` and routes do not exist.

- [ ] **Step 5: Implement the server**

`Server` owns registry, metrics, limiter and peer index. Each peer has one reader goroutine and one writer goroutine with a bounded `chan []byte`; only registry methods mutate pairing state. Configure `websocket.Accept` with compression disabled and an origin policy that permits native clients. Set read limit to 256 KiB. Use context cancellation and `Ping` for liveness. Structured logs contain only event, result, role, message type, duration and short session ID.

Expose:

```go
func NewServer(cfg Config, logger *slog.Logger) *Server
func (s *Server) Handler() http.Handler
func (s *Server) Shutdown(ctx context.Context) error
```

- [ ] **Step 6: Verify GREEN and race behavior**

Run:

```bash
go test -race ./internal/signaling ./internal/session ./internal/observability -count=10
```

Expected: PASS with no race or leaked test goroutine.

- [ ] **Step 7: Add executable config and graceful shutdown**

`main.go` reads only non-secret server environment values (`LISTEN_ADDR`, TTL, capacities, timeouts), installs `/healthz`, `/metrics`, `/ws`, starts `http.Server` with deadlines, and handles SIGINT/SIGTERM with a 10-second grace period. It must not read coturn secrets.

- [ ] **Step 8: Commit**

```bash
git add server
git commit -m "feat(signaling): serve websocket rendezvous"
```

### Task 4: Signaling packaging and K3s manifests

**Files:**
- Create: `server/Dockerfile`
- Create: `server/.dockerignore`
- Create: `deploy/k3s/signaling.yaml`
- Create: `scripts/run-local-signaling.sh`
- Create: `docs/runbooks/signaling-server.md`

- [ ] **Step 1: Add a reproducible server image**

Use a pinned Go 1.24 build stage and a distroless/static runtime, run as non-root, expose 8080 and set the binary as entrypoint. Do not copy repository artifacts, secrets or macOS files into the image.

- [ ] **Step 2: Add K3s resources**

Create `apps` namespace-scoped Deployment, ClusterIP Service and Traefik Ingress for `cast.k3s.aweffr.cn`. Add readiness/liveness probes to `/healthz`, resource requests/limits, security context and rolling update. TLS is optional at the application layer but the ingress may reference the existing wildcard secret. Do not apply the manifest.

- [ ] **Step 3: Validate packaging**

Run:

```bash
cd server && go test ./... && go build ./cmd/signaling-server
docker build -f Dockerfile .
kubectl apply --dry-run=client -f ../deploy/k3s/signaling.yaml >/dev/null
```

If Docker or kubectl context-free schema validation is unavailable, record the exact unavailable command in the plan Execution findings and still run `go build` plus YAML parse/schema tooling available locally.

- [ ] **Step 4: Commit**

```bash
git add server/Dockerfile server/.dockerignore deploy scripts/run-local-signaling.sh docs/runbooks/signaling-server.md
git commit -m "build(signaling): add container and k3s manifests"
```

### Task 5: Swift domain model, runtime config and session state

**Files:**
- Create: `apps/macos/WebRTCScreencast/App/WebRTCScreencastApp.swift`
- Create: `apps/macos/WebRTCScreencast/Domain/CastingRole.swift`
- Create: `apps/macos/WebRTCScreencast/Domain/ICEProfile.swift`
- Create: `apps/macos/WebRTCScreencast/Domain/SessionState.swift`
- Create: `apps/macos/WebRTCScreencast/Configuration/RuntimeConfiguration.swift`
- Create: `apps/macos/WebRTCScreencast/Configuration/EffectiveConfiguration.swift`
- Create: `apps/macos/WebRTCScreencastTests/RuntimeConfigurationTests.swift`
- Create: `apps/macos/WebRTCScreencastTests/SessionStateTests.swift`

- [ ] **Step 1: Write failing runtime config tests**

Tests decode direct and relay profiles, reject missing TURN UDP credential for relay, reject `transport=tcp`, accept `ws` and `wss`, resolve CLI path over Application Support default, and prove sanitized/canonical config and SHA-256 hash never contain username/password.

Desired API:

```swift
struct RuntimeConfiguration: Decodable, Sendable {
    let signalingURL: URL
    let iceProfile: ICEProfile
    let turn: TURNCredentials?
    let metricsDirectory: URL
    let excludedReceiverPID: pid_t?
    static func load(arguments: [String], fileManager: FileManager = .default) throws -> Self
    func effective(role: CastingRole, source: CaptureSourceKind?) throws -> EffectiveConfiguration
}
```

- [ ] **Step 2: Run tests and verify RED**

Generate the project if needed and run:

```bash
xcodebuild test -project apps/macos/WebRTCScreencast.xcodeproj -scheme WebRTCScreencast -destination 'platform=macOS' -only-testing:WebRTCScreencastTests/RuntimeConfigurationTests
```

Expected: compile failure due to missing types.

- [ ] **Step 3: Implement minimal config and verify GREEN**

Use `JSONDecoder`, `CryptoKit.SHA256`, URL scheme validation and a redacted `EffectiveConfiguration`. Never conform the secret-bearing type to `CustomStringConvertible`. Rerun the test until PASS.

- [ ] **Step 4: Write failing session state tests**

Cover valid role-specific transitions, failure and idempotent cleanup; reject Sender code submission before signaling connection and Receiver offer creation. Desired reducer API:

```swift
enum SessionState: Equatable, Sendable { case idle, connectingSignaling, waitingForPeer, negotiating, connected, ending, failed(SessionFailure) }
struct SessionStateMachine: Sendable {
    private(set) var state: SessionState
    mutating func handle(_ event: SessionEvent) throws
}
```

- [ ] **Step 5: Verify RED, implement reducer, verify GREEN**

Run the focused test before and after implementation. Then run all macOS tests.

- [ ] **Step 6: Commit**

```bash
git add apps/macos
git commit -m "feat(macos): add session configuration model"
```

### Task 6: Dirty-region geometry and content-aware Frame Gate

**Files:**
- Create: `apps/macos/WebRTCScreencast/Capture/DirtyRegionAnalyzer.swift`
- Create: `apps/macos/WebRTCScreencast/Capture/FrameGate.swift`
- Create: `apps/macos/WebRTCScreencast/Capture/LetterboxGeometry.swift`
- Create: `apps/macos/WebRTCScreencastTests/DirtyRegionAnalyzerTests.swift`
- Create: `apps/macos/WebRTCScreencastTests/FrameGateTests.swift`
- Create: `apps/macos/WebRTCScreencastTests/LetterboxGeometryTests.swift`

- [ ] **Step 1: Write failing geometry tests**

Cover clipped disjoint/overlapping/nested/out-of-bounds dirty rectangles and exact union ratios; cover 16:9 fill, ultrawide letterbox and portrait letterbox destination rectangles.

```swift
enum DirtyRegionAnalyzer {
    static func unionArea(of rects: [CGRect], clippedTo bounds: CGRect) -> CGFloat
    static func dirtyRatio(of rects: [CGRect], frameSize: CGSize) -> Double
}

enum LetterboxGeometry {
    static func destinationRect(source: CGSize, canvas: CGSize) throws -> CGRect
}
```

- [ ] **Step 2: Verify RED, implement sweep-line geometry, verify GREEN**

Run the two focused suites, implement x-coordinate segmentation plus merged y-intervals, and rerun until PASS. Do not use a bounding rectangle.

- [ ] **Step 3: Write failing Frame Gate tests**

With a manual monotonic clock, prove 0.5%+ enters 30 fps, non-zero small change enters at least 15 fps, downshift dwell times are 500/800/300 ms, idle change wakes immediately, per-state send intervals are enforced and only the latest pending frame token is emitted.

```swift
struct FrameGateDecision: Equatable { let shouldSubmit: Bool; let state: FrameGateState; let dirtyRatio: Double }
struct FrameGate {
    mutating func evaluate(dirtyRatio: Double, timestamp: Duration) -> FrameGateDecision
}
```

- [ ] **Step 4: Verify RED, implement state machine, verify GREEN**

Run the focused suite before/after and then all macOS unit tests.

- [ ] **Step 5: Commit**

```bash
git add apps/macos
git commit -m "feat(macos): add content-aware frame gate"
```

### Task 7: Swift signaling client and protocol parity

**Files:**
- Create: `apps/macos/WebRTCScreencast/Signaling/SignalingMessage.swift`
- Create: `apps/macos/WebRTCScreencast/Signaling/SignalingClient.swift`
- Create: `apps/macos/WebRTCScreencastTests/SignalingMessageTests.swift`
- Create: `apps/macos/WebRTCScreencastTests/SignalingClientTests.swift`

- [ ] **Step 1: Write failing Codable parity tests**

Use JSON fixtures copied from Go integration-test outputs. Assert exact version/type/payload field names, pairing code normalization, SDP/ICE round trips and stable error decoding. Unknown message type must fail.

- [ ] **Step 2: Verify RED, implement typed messages, verify GREEN**

Use an envelope plus enum payload, not `[String: Any]`. Run the focused suite until PASS.

- [ ] **Step 3: Write failing client lifecycle tests**

Inject a `WebSocketTransport` protocol implemented by a deterministic in-memory actor. Cover connect/register/join/send/receive/close, one reader task, serialized sends, cancellation and no automatic session resume.

```swift
protocol WebSocketTransport: Sendable {
    func connect(to url: URL) async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

actor SignalingClient {
    func connect(url: URL, role: CastingRole) async throws
    func registerReceiver() async throws
    func join(code: String) async throws
    func events() -> AsyncThrowingStream<SignalingEvent, Error>
    func close() async
}
```

- [ ] **Step 4: Verify RED, implement URLSession transport, verify GREEN**

The production adapter uses `URLSessionWebSocketTask` and accepts both WS and WSS. Do not send TURN credentials. Run all tests.

- [ ] **Step 5: Add cross-language fixture verification and commit**

Have Go tests write/check `server/testdata/protocol-v1/*.json` and Swift tests load the same repository fixtures. Commit:

```bash
git add apps/macos server/testdata server/internal/protocol
git commit -m "feat: share signaling protocol across clients"
```

### Task 8: Virtual display provider and ScreenCaptureKit source

**Files:**
- Create: `apps/macos/WebRTCScreencast/Bridging/WebRTCScreencast-Bridging-Header.h`
- Create: `apps/macos/WebRTCScreencast/Bridging/CGVirtualDisplayPrivate.h`
- Create: `apps/macos/WebRTCScreencast/Capture/ScreenSourceProvider.swift`
- Create: `apps/macos/WebRTCScreencast/Capture/VirtualExtendedDisplayProvider.swift`
- Create: `apps/macos/WebRTCScreencast/Capture/ScreenCaptureSource.swift`
- Create: `apps/macos/WebRTCScreencastTests/VirtualDisplayConfigurationTests.swift`
- Create: `apps/macos/WebRTCScreencastTests/ScreenCaptureConfigurationTests.swift`

- [ ] **Step 1: Write failing pure configuration tests**

Extract testable builders that prove virtual display mode is exactly 1920×1080, 1×, 60 Hz; capture is 1920×1080 NV12 video range, 30 fps, queue depth 3, cursor visible and aspect preserving; main mirror uses the tested letterbox destination; receiver PID exclusion is only allowed in direct-baseline local validation.

- [ ] **Step 2: Verify RED and implement configuration values**

Run focused tests, implement the value builders, and rerun until PASS.

- [ ] **Step 3: Implement isolated private API provider**

Declare only the four private CoreGraphics classes and properties needed. `VirtualExtendedDisplayProvider` strongly retains the display, applies one mode, publishes display ID after `NSApplication.didChangeScreenParametersNotification`, and has idempotent async stop that observes removal. Return a typed unsupported/creation/settings/timeout error. Keep the DeskPad MIT attribution in `NOTICE`.

- [ ] **Step 4: Implement ScreenCaptureKit callback**

Request shareable content, resolve `SCDisplay`, construct `SCContentFilter`, add a screen output on a serial queue, parse `.status`, `.dirtyRects`, `.contentRect`, `.scaleFactor` and PTS, feed Frame Gate, and deliver selected `CVPixelBuffer` plus nanosecond timestamp to an injected sink. Callback must not block or retain a backlog.

- [ ] **Step 5: Build and run capture permission smoke**

Run unit tests and `xcodebuild build`. Launch a small app path that calls `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly:true)`; record the Screen Recording prompt/runbook behavior. Do not claim capture works until a real frame callback is observed.

- [ ] **Step 6: Commit**

```bash
git add apps/macos NOTICE
git commit -m "feat(macos): capture physical and virtual displays"
```

### Task 9: WebRTC H.264 session, ICE profiles and receiver rendering

**Files:**
- Create: `apps/macos/WebRTCScreencast/WebRTC/IceServerProvider.swift`
- Create: `apps/macos/WebRTCScreencast/WebRTC/H264CodecPolicy.swift`
- Create: `apps/macos/WebRTCScreencast/WebRTC/WebRTCSession.swift`
- Create: `apps/macos/WebRTCScreencast/WebRTC/MetricsVideoRenderer.swift`
- Create: `apps/macos/WebRTCScreencast/WebRTC/MetalVideoView.swift`
- Create: `apps/macos/WebRTCScreencastTests/IceServerProviderTests.swift`
- Create: `apps/macos/WebRTCScreencastTests/H264CodecPolicyTests.swift`

- [ ] **Step 1: Write failing ICE profile tests**

Assert direct uses `.all`, `.disabled` TCP and no ICE server; production uses `.relay`, `.disabled` TCP and exactly one `turn:...?transport=udp` server with runtime credential. Reject TURN URL without explicit UDP transport.

- [ ] **Step 2: Verify RED, implement ICE provider, verify GREEN**

The provider returns an `RTCConfiguration` and a redacted evidence struct. Run focused tests until PASS.

- [ ] **Step 3: Write failing H.264 policy tests**

Given synthetic capability descriptors, prove only video/H264 with `packetization-mode=1` remains, Baseline is preferred, RTX associated with retained H.264 payload is retained when represented, and no H.264 yields a typed failure. The pure selection logic must not touch SDP strings.

- [ ] **Step 4: Verify RED, implement codec selection, verify GREEN**

Map the selected descriptors to WebRTC `RTCRtpCodecCapability` instances from factory capabilities and call `setCodecPreferences:error:` before negotiation.

- [ ] **Step 5: Implement WebRTCSession**

Load CastTuning JSON, create factory with default encoder/decoder, create Unified Plan PeerConnection, add one send-only or recv-only video transceiver, apply codec preferences, and expose async wrappers for create/set offer/answer and ICE candidate add. Sender creates `RTCVideoSource(forScreenCast: true)`, `RTCVideoCapturer(delegate:)`, wraps selected NV12 buffer in `RTCCVPixelBuffer` and delivers `RTCVideoFrame`; Receiver attaches first remote video track to both renderers. More than one video track is a protocol error.

- [ ] **Step 6: Add selected path verification**

Parse candidate-pair/local-candidate/remote-candidate stats by IDs. Direct baseline passes only when selected path is not relay; production relay passes only with relay candidate and UDP relay protocol. Emit `unknown` until enough stats exist and `violation` when connected data contradicts requested profile.

- [ ] **Step 7: Build/link smoke and commit**

Run:

```bash
xcodebuild test -project apps/macos/WebRTCScreencast.xcodeproj -scheme WebRTCScreencast -destination 'platform=macOS'
xcodebuild build -project apps/macos/WebRTCScreencast.xcodeproj -scheme WebRTCScreencast -configuration Debug -destination 'platform=macOS,arch=arm64'
```

Confirm the built app embeds a signed `WebRTC.framework`. Commit:

```bash
git add apps/macos config/cast-tuning.default.json
git commit -m "feat(macos): negotiate H264 WebRTC sessions"
```

### Task 10: Client metrics, stats normalization and diagnostic export

**Files:**
- Create: `apps/macos/WebRTCScreencast/Observability/MetricsRecord.swift`
- Create: `apps/macos/WebRTCScreencast/Observability/MetricsRecorder.swift`
- Create: `apps/macos/WebRTCScreencast/Observability/RTCStatsNormalizer.swift`
- Create: `apps/macos/WebRTCScreencast/Observability/DiagnosticExporter.swift`
- Create: `apps/macos/WebRTCScreencastTests/RTCStatsNormalizerTests.swift`
- Create: `apps/macos/WebRTCScreencastTests/DiagnosticExporterTests.swift`

- [ ] **Step 1: Write failing stats normalization tests**

Use captured/synthetic `type`, `id`, `timestamp_us`, `values` dictionaries for outbound-rtp, remote-inbound-rtp, candidate-pair, local/remote-candidate, inbound-rtp and codec. Assert safe numeric coercion, derived averages/deltas, selected path linkage and null capability fields when absent; never interpret absent counters as zero.

- [ ] **Step 2: Verify RED, implement normalizer, verify GREEN**

Keep dynamic WebRTC dictionaries at the adapter boundary and output typed sample structs. Run focused tests until PASS.

- [ ] **Step 3: Write failing recorder/export tests**

Prove JSONL includes schema/session/role/profile/hash/revision/wall/monotonic fields; concurrent event/sample writes remain one JSON object per line; pairing code, TURN username/password, SDP and candidate values are redacted. Export must abort if an injected secret appears in any file.

- [ ] **Step 4: Verify RED, implement recorder/exporter, verify GREEN**

Use one actor as the file writer, sanitized config only, `ditto -c -k` or `FileManager.zipItem` availability fallback for bundle creation, and a manifest with SHA-256 per file. Do not include runtime config.

- [ ] **Step 5: Wire one-second RTCStats and capture/render samples**

Start sampling only after PeerConnection creation, record state changes immediately, and stop/flush before teardown. Store CastTuning telemetry and WebRTC logs in the same session directory with non-secret paths supplied in generated tuning JSON.

- [ ] **Step 6: Run tests and commit**

```bash
xcodebuild test -project apps/macos/WebRTCScreencast.xcodeproj -scheme WebRTCScreencast -destination 'platform=macOS'
git add apps/macos
git commit -m "feat(macos): export screencast diagnostics"
```

### Task 11: SessionCoordinator and minimal native UI

**Files:**
- Create: `apps/macos/WebRTCScreencast/App/SessionCoordinator.swift`
- Create: `apps/macos/WebRTCScreencast/UI/StartView.swift`
- Create: `apps/macos/WebRTCScreencast/UI/SenderView.swift`
- Create: `apps/macos/WebRTCScreencast/UI/ReceiverView.swift`
- Create: `apps/macos/WebRTCScreencast/UI/MetricsSummaryView.swift`
- Create: `apps/macos/WebRTCScreencastTests/SessionCoordinatorTests.swift`

- [ ] **Step 1: Write failing coordinator behavior tests**

Inject signaling, WebRTC, capture, metrics and virtual-display protocols. Cover Receiver register/display code, Sender join/offer, Receiver answer, trickle ICE both ways, connected state, hangup, capture failure, profile violation and idempotent teardown order. Verify a consumed code is never retried automatically.

- [ ] **Step 2: Verify RED, implement coordinator, verify GREEN**

Make `SessionCoordinator` `@MainActor`, isolate media/network adapters behind actors, and map stable failures to user-safe actions. Run focused and full tests.

- [ ] **Step 3: Implement task-focused UI**

Start view selects role, signaling URL and profile. Receiver view shows pairing code, video canvas, connection/path/metrics summary, stop and export. Sender view accepts code, selects Main Display Mirror or Virtual Extended Display, shows connection/path/metrics summary, stop and export. Production relay is default; direct baseline is marked development. Do not display TURN secrets, requirements text, protocol fields or implementation instructions.

- [ ] **Step 4: Add launch argument automation**

Parse `--role`, `--profile`, `--config`, `--pairing-code-file`, `--source`, and `--exclude-receiver-pid`. Receiver atomically writes pairing code to the requested mode-0600 file; Sender waits bounded time and reads it. These switches orchestrate two real app processes but do not create an in-process loopback.

- [ ] **Step 5: Build, inspect UI and commit**

Run all tests/build, launch each role, inspect that the main task is clear and no developer text or mock data is visible, then commit:

```bash
git add apps/macos
git commit -m "feat(macos): add sender and receiver workflows"
```

### Task 12: Single-Mac dual-process E2E and operational docs

**Files:**
- Create: `scripts/run-dual-client.sh`
- Create: `scripts/verify-diagnostics.sh`
- Create: `scripts/verify-no-secret-leaks.sh`
- Create: `docs/runbooks/local-development.md`
- Create: `docs/runbooks/single-mac-e2e.md`
- Create: `docs/runbooks/runtime-configuration.md`
- Modify: `README.md`
- Modify: `docs/superpowers/plans/2026-07-14-macos-webrtc-screencast.md`

- [ ] **Step 1: Add deterministic orchestration script**

Build app, start local signaling on a random free port, start Receiver as a new process, wait for its mode-0600 pairing-code file, start Sender as a second process, and collect exit/status/log paths. Parameters select `direct-baseline|production-relay` and `main|virtual`; relay refuses to start when runtime TURN fields are empty. The script must trap EXIT and terminate both processes/server without deleting diagnostics.

- [ ] **Step 2: Add evidence verifier**

`verify-diagnostics.sh <receiver-dir> <sender-dir> <profile>` parses JSONL with `jq`, requires pairing/negotiation/capture/encode/decode/render and selected-pair records, checks production relay candidate type + UDP, checks direct is not relay, verifies virtual display removal when applicable, and scans all exported text for configured secrets. It must fail on missing evidence rather than infer success.

- [ ] **Step 3: Run direct-baseline E2E**

Grant Screen Recording when macOS prompts, then run both source modes:

```bash
./scripts/run-dual-client.sh --profile direct-baseline --source main
./scripts/run-dual-client.sh --profile direct-baseline --source virtual
```

Expected: two independent PIDs, H.264 selected, renderer receives frames, direct selected path verified, metrics verifier passes, virtual display removed after stop.

- [ ] **Step 4: Run production-relay TURN/UDP E2E**

Load ignored runtime config from the existing coturn secret material without printing it, then run:

```bash
./scripts/run-dual-client.sh --profile production-relay --source main
./scripts/run-dual-client.sh --profile production-relay --source virtual
```

Expected: selected candidate evidence includes relay and UDP; no TCP or direct fallback; metrics verifier passes. If NAT hairpin or external UDP allocation prevents same-host relay, preserve logs and record the exact external blocker rather than weakening ICE policy.

- [ ] **Step 5: Run full static and automated verification**

```bash
make verify
git diff --check
./scripts/verify-no-secret-leaks.sh --config "$RUNTIME_CONFIG"
```

`verify-no-secret-leaks.sh` reads the configured TURN values without echoing them, enumerates tracked files with `git grep`, and fails if either non-empty value occurs. Expected: all tests/build/checks pass and the secret scan returns no tracked match.

- [ ] **Step 6: Record execution findings and commit**

Update this plan’s `Execution findings` with exact tool versions, commands, E2E evidence directories, selected ICE path results and any unavailable external verification. Commit:

```bash
git add README.md docs scripts Makefile
git commit -m "test: verify single-mac screencast flows"
```

### Task 13: Independent review, fixes and completion audit

**Files:**
- Modify: files identified by review
- Modify: `docs/superpowers/plans/2026-07-14-macos-webrtc-screencast.md`

- [ ] **Step 1: Prepare the clean-context review package**

Include original user requirements, design, plan, `git diff main~N..HEAD`, commit list, tests/build/E2E commands, diagnostic evidence, known limits and follow-ups. Ask reviewer only for requirement mismatches and Critical/High correctness, security, concurrency, lifecycle, compatibility, observability or validation gaps.

- [ ] **Step 2: Fix accepted findings with TDD**

For every real defect, reproduce with a failing test or E2E check, observe RED, implement the smallest correct fix, rerun affected and full verification, and send the same reviewer the updated evidence. Stop after no mandatory issue or three rounds.

- [ ] **Step 3: Audit every requirement against authoritative evidence**

Build a table in Execution findings covering: two release assets/checksums; native single app supporting both roles; main mirror and app-created 1920×1080 virtual display; H.264 only; Go WS signaling; receiver-first code; WS/WSS; direct baseline; relay-only TURN/UDP; no TURN/TCP; sender/receiver/server metrics; dual-process E2E; secret hygiene; follow-up docs. Mark any missing evidence incomplete and continue implementation.

- [ ] **Step 4: Final verification and commit**

Run `make verify`, E2E evidence verifiers, `git status --short`, `git log --oneline`, and commit accepted review fixes using conventional commit messages. Completion requires a clean worktree except ignored local runtime/artifacts.

## Execution findings

- 2026-07-14: Host toolchain before implementation: Xcode 26.5 (17F42), Apple Swift 6.3.2, Go 1.24.13, XcodeGen available at `/opt/homebrew/bin/xcodegen`.
- 2026-07-14: `github.com/coder/websocket` latest enumerated module version is v1.8.15; the plan pins it.
- 2026-07-14: Spec and research verified the supplied universal XCFramework supports arm64/x86_64, targets macOS 14.0 and exposes `RTCCastTuning`, `setCodecPreferences`, screen-cast video source, RTCStats and `RTCMTLNSVideoView`.
