# macOS Sender 与 Android TV Receiver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `execute-long-horizon-task` to
> implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在一台 Apple Silicon Mac 上构建并验证 macOS H.264 Sender 到 Android TV
1080p arm64 emulator Receiver 的 Direct UDP 与强制 TURN/UDP 投屏闭环，并产出跨端
时钟校准的延迟和画质基线。

**Architecture:** 现有 Go signaling 和 macOS Sender 保持主干结构；Android TV 新增
Java + Views reference app，以 app-lifetime WebRTC runtime 承载 per-session Receiver。
Server `/clock` 把两端 monotonic timestamps 映射到共同时间域；自动化复用现有
marker/chart/quality pipeline，用 ADB 拉取 Android app-private JSONL 与 decoded PNG。

**Tech Stack:** Swift 6、ScreenCaptureKit、WebRTC M150 preview XCFramework、Java 17 reference app、
Java 8-compatible M150 arm64-v8a AAR、Android Views/Leanback、Gradle 9.4.1、AGP 9.2.1、OkHttp 5.3.0、
Go 1.24、Python 3、ADB/Android Emulator、FFmpeg/libvmaf、JSONL

**Design:**
[`docs/superpowers/specs/2026-07-16-macos-sender-android-tv-receiver-design.md`](../specs/2026-07-16-macos-sender-android-tv-receiver-design.md)

**Upstream evidence:**
[`my-webrtc-builds Android AAR and Apple low-latency plan`](/Users/aweffr/developer/aweffr/my-webrtc-builds/docs/superpowers/plans/2026-07-14-android-aar-apple-low-latency.md)

---

## File responsibilities

- `scripts/bootstrap-webrtc.sh` and `artifacts/SHA256SUMS`: verify exact preview inputs.
- `apps/android-tv/.../config`: readable XML-backed runtime configuration contract.
- `apps/android-tv/.../signaling`: protocol-v1 codec and OkHttp WebSocket.
- `apps/android-tv/.../session`: state machine, WebRTC runtime and per-cast session.
- `apps/android-tv/.../observability`: JSONL, RTCStats, marker and clock evidence.
- `apps/android-tv/.../ui`: TV-only Activity and three-state 10-foot UI.
- `server/internal/clock`: read-only common-time response contract.
- `apps/macos/.../LaunchOptions.swift`: direct pairing-code CLI contract.
- `scripts/run-android-tv-e2e.sh`: one authoritative cross-platform run.
- `scripts/run-android-tv-baseline.sh`: functional matrix and six-run baseline.

## Immutable inputs

```text
macOS release tag: webrtc-m150.7871.3-0ff0e8c-20260714-macos-android-preview.1
Android Action run/artifact: 29439085060 / 8353870165
AAR SHA-256: c79ba807b38cedd9b82f6c54ada8a89b9e4da6c14ec3dc4361b5d45410ba6744
XCFramework zip SHA-256: 8ae44b7ceab069e704acb5a8faaaea5aa4547ea6351bb1bf2bb38e5b343c9678
Android AVD: WebRTCScreencast_TV_API_31
Android image: system-images;android-31;android-tv;arm64-v8a
Android device: tv_1080p
```

### Task 1: Pin preview artifacts and scaffold Android TV build

**Files:**
- Modify: `.gitignore`
- Modify: `artifacts/SHA256SUMS`
- Modify: `scripts/bootstrap-webrtc.sh`
- Create: `apps/android-tv/settings.gradle.kts`
- Create: `apps/android-tv/build.gradle.kts`
- Create: `apps/android-tv/gradle.properties`
- Create: `apps/android-tv/gradlew`
- Create: `apps/android-tv/gradlew.bat`
- Create: `apps/android-tv/gradle/wrapper/gradle-wrapper.jar`
- Create: `apps/android-tv/gradle/wrapper/gradle-wrapper.properties`
- Create: `apps/android-tv/app/build.gradle.kts`
- Create: `scripts/provision-android-tv-avd.sh`
- Modify: `scripts/test-verifiers.sh`
- Modify: `Makefile`

- [x] **Step 1: Write the failing artifact contract**

Extend `scripts/test-verifiers.sh` with a temp release directory. Invoke bootstrap with
`ARTIFACTS_DIR`, `VENDOR_DIR` and `WEBRTC_RELEASE_BASE_URL=file://...`; assert corrupt AAR or
XCFramework bytes fail before extraction and exact fixture bytes pass.

- [x] **Step 2: Run RED**

Run `./scripts/test-verifiers.sh`.

Expected: FAIL because bootstrap hard-codes one old archive and has no Android AAR contract.

- [x] **Step 3: Implement preview download and verification**

Replace the manifest with exactly:

```text
8ae44b7ceab069e704acb5a8faaaea5aa4547ea6351bb1bf2bb38e5b343c9678  WebRTC-m150-macos-universal.xcframework.zip
c79ba807b38cedd9b82f6c54ada8a89b9e4da6c14ec3dc4361b5d45410ba6744  webrtc-m150-android-arm64-v8a.aar
```

Bootstrap downloads only missing assets from the immutable tag, checks both hashes, extracts the
XCFramework and requires AAR members `AndroidManifest.xml`, `classes.jar` and
`jni/arm64-v8a/libjingle_peerconnection_so.so`.

- [x] **Step 4: Generate the Gradle 9.4.1 wrapper**

Use a temporary Gradle 9.4.1 distribution to generate wrapper scripts/jar/properties. Commit the
published `distributionSha256Sum`; do not commit the distribution or Gradle caches.

- [x] **Step 5: Add the application module**

Use Android application plugin 9.2.1, Java 17, compile/target 36, min 26 and arm64-only packaging.
Add `directBaseline` and `productionRelay` flavors; each defines only
`R.string.reference_ice_profile`. Depend on the verified local AAR, OkHttp 5.3.0, JUnit 4.13.2,
AndroidX Test 1.7.0 and Espresso 3.7.0. Do not add Kotlin or Compose plugins.

- [x] **Step 6: Add idempotent AVD provisioning**

Install the exact API 31 TV arm64 image when absent and create
`WebRTCScreencast_TV_API_31 --device tv_1080p`. Re-running must keep a compatible existing AVD and
must not modify `Pixel_6_API_31`.

- [x] **Step 7: Verify and commit**

Run:

```zsh
./scripts/test-verifiers.sh
./scripts/bootstrap-webrtc.sh
./apps/android-tv/gradlew -p apps/android-tv tasks --all
zsh -n scripts/provision-android-tv-avd.sh
git diff --check
```

Commit: `build: scaffold Android TV receiver app`

### Task 2: Implement configuration, protocol, state and clock contracts

**Files:**
- Create: `apps/android-tv/app/src/main/java/cn/aweffr/webrtcscreencast/tv/config/ReferenceRuntimeConfig.java`
- Create: `apps/android-tv/app/src/main/java/cn/aweffr/webrtcscreencast/tv/signaling/SignalingMessage.java`
- Create: `apps/android-tv/app/src/main/java/cn/aweffr/webrtcscreencast/tv/signaling/SignalingCodec.java`
- Create: `apps/android-tv/app/src/main/java/cn/aweffr/webrtcscreencast/tv/session/ReceiverStateMachine.java`
- Create: `apps/android-tv/app/src/main/java/cn/aweffr/webrtcscreencast/tv/observability/ClockCalibration.java`
- Create: `apps/android-tv/app/src/main/res/values/reference_runtime.xml`
- Create: `apps/android-tv/app/reference_runtime.local.xml.example`
- Test: `apps/android-tv/app/src/test/java/cn/aweffr/webrtcscreencast/tv/config/ReferenceRuntimeConfigTest.java`
- Test: `apps/android-tv/app/src/test/java/cn/aweffr/webrtcscreencast/tv/signaling/SignalingCodecTest.java`
- Test: `apps/android-tv/app/src/test/java/cn/aweffr/webrtcscreencast/tv/session/ReceiverStateMachineTest.java`
- Test: `apps/android-tv/app/src/test/java/cn/aweffr/webrtcscreencast/tv/observability/ClockCalibrationTest.java`

- [x] **Step 1: Write RED unit tests**

Cover relay placeholder rejection, TURN/UDP validation, direct-without-credential, redacted hash,
strict version/type/payload handling, one-time pairing lifecycle, expiry reconnect, bounded backoff
`1,2,4,8,8`, fatal H.264/config errors and minimum-RTT calibration selection.

Use this calibration vector:

```java
ClockCalibration result = ClockCalibration.choose(List.of(
    new Sample(1_000L, 1_500L, 10_200L),
    new Sample(2_000L, 2_100L, 11_050L)));
assertEquals(100L, result.roundTripNs());
assertEquals(9_000L, result.offsetNs());
assertEquals(50L, result.uncertaintyNs());
```

- [x] **Step 2: Run RED**

Run both `:app:testDirectBaselineDebugUnitTest` and
`:app:testProductionRelayDebugUnitTest`; expect missing contract compilation failures.

- [x] **Step 3: Implement XML-backed config**

`ReferenceRuntimeConfig.load(Resources)` reads only `R.string.reference_*`; `validate()` emits
stable typed errors and `redactedHash()` excludes username/password. Commit schema 2 JSON with
explicit `CONSTRAINED_BASELINE`, `video_toolbox_low_latency_rate_control=false`,
`android_decoder_low_latency=true`, `prerender_smoothing=false` and `render_lead_ms=10`.

- [x] **Step 4: Implement protocol and state machine**

Use `org.json`. Reject unknown protocol fields/types and redact raw SDP/candidate from object text.
`ReceiverStateMachine.reduce(Event)` emits `CONNECT`, `REGISTER`, `CREATE_PEER`, `APPLY_OFFER`,
`SEND_ANSWER`, `ADD_ICE`, `CLEANUP`, `SCHEDULE_RETRY` or `SHOW_ERROR` commands.

- [x] **Step 5: Implement calibration math**

Compute midpoint, RTT, offset and RTT/2 uncertainty with overflow checks; choose smallest RTT and
expose `toCommonTimeNs(localMonotonicNs)`.

- [x] **Step 6: Verify and commit**

Run both unit suites and `git diff --check`.

Commit: `feat(android-tv): add receiver domain contracts`

### Task 3: Add server clock endpoint and Mac calibration client

**Files:**
- Create: `server/internal/clock/handler.go`
- Create: `server/internal/clock/handler_test.go`
- Modify: `server/internal/signaling/server.go`
- Create: `apps/macos/WebRTCScreencast/Observability/ClockCalibration.swift`
- Create: `apps/macos/WebRTCScreencastTests/ClockCalibrationTests.swift`
- Modify: `apps/macos/WebRTCScreencast/App/SessionCoordinator.swift`

- [x] **Step 1: Write RED Go and Swift tests**

Require `GET /clock` JSON schema 1 with `server_unix_ns`, `Cache-Control: no-store`, method
rejection and no session fields. Swift tests mirror Java vectors and invalid-sample handling.

- [x] **Step 2: Run RED**

Run `(cd server && go test ./internal/clock ./internal/signaling)` and `make test-macos`; expect
missing handler/type failures.

- [x] **Step 3: Implement `/clock`**

Use an injected `func() time.Time` and encode only:

```go
struct {
    SchemaVersion int   `json:"schema_version"`
    ServerUnixNS  int64 `json:"server_unix_ns"`
}{SchemaVersion: 1, ServerUnixNS: now().UnixNano()}
```

- [x] **Step 4: Implement five-sample Mac calibration**

Derive `ws→http` or `wss→https` plus `/clock`, take five sequential samples, select minimum RTT,
and record offset/RTT/uncertainty/sample count. Baseline mode fails without calibration; normal mode
records unavailable and continues.

- [x] **Step 5: Verify and commit**

Run `make test-go`, `make test-macos`, `git diff --check`.

Commit: `feat: add cross-platform clock calibration`

### Task 4: Implement Android WebRTC Receiver and observability

**Files:**
- Create: `apps/android-tv/app/src/main/java/cn/aweffr/webrtcscreencast/tv/observability/ReceiverMetricsRecorder.java`
- Create: `apps/android-tv/app/src/main/java/cn/aweffr/webrtcscreencast/tv/observability/ClockCalibrationHttpClient.java`
- Create: `apps/android-tv/app/src/main/java/cn/aweffr/webrtcscreencast/tv/observability/RtcStatsNormalizer.java`
- Create: `apps/android-tv/app/src/main/java/cn/aweffr/webrtcscreencast/tv/observability/AndroidMarkerProbe.java`
- Create: `apps/android-tv/app/src/main/java/cn/aweffr/webrtcscreencast/tv/signaling/SignalingClient.java`
- Create: `apps/android-tv/app/src/main/java/cn/aweffr/webrtcscreencast/tv/session/ReceiverRuntime.java`
- Create: `apps/android-tv/app/src/main/java/cn/aweffr/webrtcscreencast/tv/session/WebRtcReceiverSession.java`
- Create: `apps/android-tv/app/src/main/java/cn/aweffr/webrtcscreencast/tv/session/ReceiverController.java`
- Test: `apps/android-tv/app/src/test/java/cn/aweffr/webrtcscreencast/tv/observability/RtcStatsNormalizerTest.java`
- Test: `apps/android-tv/app/src/test/java/cn/aweffr/webrtcscreencast/tv/observability/AndroidMarkerProbeTest.java`
- Test: `apps/android-tv/app/src/test/java/cn/aweffr/webrtcscreencast/tv/session/H264CodecPolicyTest.java`

- [x] **Step 1: Write RED stats, marker and codec tests**

Fixture maps cover inbound RTP, candidate pair and candidates. Missing stats stay null; relay/UDP
verification is explicit; candidate strings are discarded. Port 12×12 marker version/sequence/CRC
vectors and one-bit corruption. H.264 filter keeps only H264 with `packetization-mode=1`.

- [x] **Step 2: Run RED**

Run both variant unit-test tasks; expect missing types.

- [x] **Step 3: Implement app-lifetime WebRTC runtime**

Initialize WebRTC/EGL once, parse schema 2, create `CastTuningController`, configure factory field
trials and use `createVideoDecoderFactory`. Dispose session → factory → controller → EGL.

- [x] **Step 4: Implement per-cast Receiver session**

Use no ICE server for direct and exactly one TURN/UDP server plus RELAY policy for production;
always disable TCP and use Unified Plan. Add one recv-only video transceiver, set H.264-only codec
preferences, apply offer/answer and trickle ICE serially. Accept one remote video track, attach
CastTuning receiver settings and renderer; a second track is a protocol error.

- [x] **Step 5: Implement JSONL and marker evidence**

Write `files/evidence/<run-id>/receiver.jsonl` on one executor. Sample RTCStats each second.
Baseline mode alone attaches a renderer frame listener, records
`baseline_android_render_detected` at callback entry and writes the three agreed decoded PNGs.

- [x] **Step 6: Implement retry-safe orchestration**

Expiry/hangup/transient disconnect performs idempotent cleanup then gets a fresh code. Config/H.264
errors require manual retry. Every callback carries a generation token so an old session cannot
mutate a replacement.

- [x] **Step 7: Verify and commit**

Run Android unit tests, lint, both debug assembles, and inspect APK for the exact arm64 JNI library.

Commit: `feat(android-tv): implement WebRTC receiver session`

Execution finding (2026-07-16): both ICE flavors pass their full local unit
suite, lint and debug assembly, and both APKs contain exactly
`lib/arm64-v8a/libjingle_peerconnection_so.so`. GitHub Actions run `29439085060`
produced the replacement AAR; all 418 classfiles are Java 8 major 52. The hosted
AAR-only Java 8 consumer and this reference app's two flavors both compile with
JDK 17 as the AGP runtime, so JDK 25 is no longer part of the downstream contract.

### Task 5: Build Android TV UX and lifecycle smoke

**Files:**
- Create: `apps/android-tv/app/src/main/AndroidManifest.xml`
- Create: `apps/android-tv/app/src/main/res/xml/network_security_config.xml`
- Create: `apps/android-tv/app/src/main/res/layout/activity_receiver.xml`
- Create: `apps/android-tv/app/src/main/res/drawable/*`
- Create: `apps/android-tv/app/src/main/res/mipmap-anydpi-v26/*`
- Create: `apps/android-tv/app/src/main/res/drawable-nodpi/tv_banner.png`
- Create: `apps/android-tv/app/src/main/res/values/strings.xml`
- Create: `apps/android-tv/app/src/main/res/values/colors.xml`
- Create: `apps/android-tv/app/src/main/res/values/dimens.xml`
- Create: `apps/android-tv/app/src/main/res/values/styles.xml`
- Create: `apps/android-tv/app/src/main/java/cn/aweffr/webrtcscreencast/tv/ui/ReceiverActivity.java`
- Test: `apps/android-tv/app/src/androidTest/java/cn/aweffr/webrtcscreencast/tv/ui/ReceiverActivityTest.java`
- Create: `scripts/smoke-android-tv-app.sh`

- [x] **Step 1: Write RED TV behavior tests**

Assert Leanback launcher resolution, landscape, focusable retry action, pairing-code presentation,
WAITING→PLAYING visibility, Back cleanup and D-pad-only operation using a fake controller.

- [x] **Step 2: Confirm RED instrumentation compile**

Run `:app:compileDirectBaselineDebugAndroidTestJavaWithJavac`; expect missing Activity/resources.

- [x] **Step 3: Implement TV-only manifest and layout**

Declare Internet, required Leanback, touchscreen false, banner/icon, landscape exported Activity
and `LEANBACK_LAUNCHER`. Permit cleartext only for `10.0.2.2`, `127.0.0.1` and `localhost`.
Use 5% safe-area padding, at least 32sp primary text, 48dp D-pad targets, visible focus and a 16:9
`SurfaceViewRenderer` filling PLAYING state.

- [x] **Step 4: Implement Activity lifecycle**

Render only WAITING/PLAYING/ERROR, keep screen on only while playing, and forward
start/stop/destroy to controller. Do not expose a settings screen, credential or engineering text.

- [x] **Step 5: Run real TV emulator smoke**

Provision and boot the AVD, install direct APK, launch Leanback Activity, verify API/ABI/1920×1080,
exercise D-pad retry, capture a screenshot, pull app-private evidence with `run-as`, and require the
JNI/WebRTC initialization event.

- [x] **Step 6: Verify and commit**

Run unit/lint/assemble/connected tests and `scripts/smoke-android-tv-app.sh`.

Commit: `feat(android-tv): add TV receiver experience`

Execution evidence: API 31 Android TV arm64 AVD reported `1920x1080`; five connected tests and
the lifecycle smoke passed. The smoke requires `receiver_runtime_initialized` and
`receiver_registered`, verifies the pairing-code shape without exporting its value, and writes a
screenshot plus app-private JSONL under ignored `diagnostics/android-tv-smoke/`. During the first
real registration, the Go server's RFC 3339 timestamp with a local `+08:00` offset exposed an
Android `Instant.parse` incompatibility; the Receiver now parses it through `OffsetDateTime` and
keeps safe stage-specific protocol error codes.

### Task 6: Upgrade macOS runtime and direct CLI pairing

**Files:**
- Modify: `config/cast-tuning.default.json`
- Modify: `apps/macos/WebRTCScreencast/App/LaunchOptions.swift`
- Modify: `apps/macos/WebRTCScreencast/App/SessionCoordinator.swift`
- Modify: `apps/macos/WebRTCScreencastTests/LaunchOptionsTests.swift`
- Modify: `apps/macos/WebRTCScreencastTests/RuntimeConfigurationTests.swift`
- Modify: `docs/runbooks/local-development.md`

- [x] **Step 1: Write RED CLI/schema tests**

Cover `--pairing-code AB12-CD34` normalization, missing/invalid values and mutual exclusion with
`--pairing-code-file`. Assert schema 2 loads with Constrained Baseline and Apple low latency.

- [x] **Step 2: Run focused RED**

Run LaunchOptions and RuntimeConfiguration suites; expect missing field/schema mismatch.

- [x] **Step 3: Implement direct pairing code**

Add `pairingCode: String?`, normalize eagerly, and throw a stable conflicting-options error when
both code sources occur. Complete launch arguments still use the same `.app`, window, permission
identity and coordinator cleanup path.

- [x] **Step 4: Migrate to schema 2**

Keep current bitrate, screen-content, NACK/RTX and 30fps values; explicitly use Baseline plus Apple
low-latency rate control and Android receiver fields. Verify the linked framework metadata/hash is
the preview input, not the old `eeca1bc` asset.

- [x] **Step 5: Verify and commit**

Run focused/full Mac tests, build the app, and launch its executable with `--pairing-code` against a
local signaling fixture.

Commit: `feat(macos): support Android TV sender launch`

Execution evidence: the complete Mac test suite and signed Debug build passed against the pinned
preview XCFramework (`builder_commit=0ff0e8c…`, archive SHA-256 `8ae44b7c…`). The same app
executable was launched twice with an Android TV one-time code and `--source main`; both runs
reached server `session_paired`, Android `sdp_offer_received`/`remote_video_playing`, periodic
RTCStats, timed Sender cleanup, and Receiver re-registration with a fresh code.

### Task 7: Implement one-run cross-platform E2E and calibrated analysis

**Files:**
- Create: `scripts/run-android-tv-e2e.sh`
- Create: `scripts/pull-android-tv-evidence.sh`
- Create: `scripts/analyze-android-tv-baseline.py`
- Create: `scripts/test_android_tv_baseline_analyzer.py`
- Modify: `scripts/verify-diagnostics.sh`
- Modify: `Makefile`
- Create: `docs/runbooks/android-tv-e2e.md`

- [x] **Step 1: Write RED analyzer tests**

Use fixture JSONL with different monotonic epochs/calibration offsets. Assert correlation occurs
only after common-time mapping and reports Marker Commit-to-Capture,
Capture-to-Android Render and Android Render Software End-to-End. Reject missing calibration,
selected-path violation, no 1920×1080 frame, incomplete triplet or credential occurrence.

- [x] **Step 2: Run RED**

Run `python3 -m unittest scripts/test_android_tv_baseline_analyzer.py` plus shell syntax checks.

- [x] **Step 3: Implement authoritative one-run orchestration**

Start local Go server, launch Android Receiver first, read its pairing-code event through
app-private JSONL, then launch Mac Sender with direct `--pairing-code`. Wait for both connected and
selected-path evidence; stop Sender and prove Android returns to a new code. Install the matching
direct/relay APK flavor for the requested profile.

- [x] **Step 4: Collect and secure evidence**

Pull Android JSONL/PNGs, process-filtered logcat and TV screenshot; copy Mac metrics, server log/
metrics and host/AVD identity. Scan the whole retained tree for actual configured username/password
before success. Never retain local XML or full pairing code. Existing metrics serialization keeps
SDP/candidate payloads redacted; no additional whole-tree protocol scanner is introduced.

- [x] **Step 5: Implement calibrated image/latency analysis**

Reuse current crop/PSNR/SSIM/VMAF/heatmap logic. Join marker sequence after applying each side's
selected calibration; retain raw and common timestamps and never label results glass-to-glass.

- [x] **Step 6: Verify and commit**

Run script tests, syntax checks, Android/Go/Swift tests and one short direct virtual E2E.

Commit: `test: add macOS to Android TV E2E`

### Task 8: Execute the four-case functional matrix

**Files:**
- Generate ignored: `artifacts/android-tv-e2e/<run-id>/functional/`
- Modify: this plan's `Execution findings`

- [x] **Step 1: Preflight the exact environment**

Require preview hashes, API 31 arm64 TV AVD at 1920×1080, Screen Recording permission, zero managed
virtual displays and valid ignored TURN/UDP configuration.

- [x] **Step 2: Run four fresh sessions**

Run direct/main, direct/virtual, relay/main and relay/virtual. Use new pairing code and
PeerConnection each time; `showsCursor` remains true.

- [x] **Step 3: Audit each run**

Require receiver-first pairing, H.264-only evidence, 1920×1080 Android render, requested selected
path, both metrics sets, decoder/CastTuning evidence, signaling timings, normal teardown and
fresh-code recovery. Relay must be relay/relay+UDP and never TCP; direct must be non-relay UDP. Virtual runs
must prove display removal.

- [x] **Step 4: Inspect TV screenshots**

Open waiting and playing screenshots from both profiles. Confirm TV-safe layout, visible cursor in
main capture, full-frame video, no engineering/secret text and no phone UI.

- [x] **Step 5: Record evidence**

Fix only reproduced failures, rerun affected entries, then append immutable run IDs, artifact roots
and summaries. Commit findings as `docs: record Android TV functional E2E`.

### Task 9: Execute and version the six-run quantitative baseline

**Files:**
- Generate ignored: `artifacts/android-tv-e2e/<run-id>/baseline/`
- Create generated: `baselines/<date>-<commit>-android-tv.json`
- Create generated: `baselines/<date>-<commit>-android-tv.md`
- Modify: this plan's `Execution findings`

- [x] **Step 1: Run alternating sessions**

Run Direct 1, TURN 1, Direct 2, TURN 2, Direct 3, TURN 3 with virtual chart, 10-second warm-up,
60-second measurement, 500ms markers and three PNG triplets per run.

- [x] **Step 2: Audit calibrated timing**

Require five clock samples per side, selected minimum RTT, offset/uncertainty and no raw cross-epoch
subtraction. Report signaling-ready and WebRTC-negotiation timing separately.

- [x] **Step 3: Audit quality and counts**

Require six reports, 18 source, 18 capture and 18 Android decoded PNGs, heatmaps and all
PSNR/SSIM/VMAF results. VMAF stays reference-only; no latency/quality threshold is introduced.

- [x] **Step 4: Inspect representative evidence**

Open beginning/middle/end decoded PNG and a TV screenshot for one Direct and one TURN run; confirm
marker, Chinese/Latin text, fine lines, grayscale/color patches and 1920×1080 dimensions.

- [x] **Step 5: Audit security and version aggregate**

Recompute checksums; scan raw/versioned artifacts for configured TURN credentials and full pairing
codes. Version only aggregates, tool versions, config identities and safe checksums.

- [x] **Step 6: Verify and commit**

Run `make verify`, Android lint/unit/connected tests, both APK builds and `git diff --check`.
Commit reports/findings as `docs: record Android TV media baseline`.

### Task 10: Clean-context review and completion audit

**Files:**
- Modify implementation/tests/docs only for validated Critical/High findings.

- [ ] **Step 1: Prepare the review package**

Include requirements, research, design, plan, upstream preview evidence, commits/diff, test commands,
functional matrix, baseline, screenshot/PNG inspection, secret scan and emulator-only boundary.

- [ ] **Step 2: Dispatch a no-history reviewer**

Limit review to requirement alignment, TV correctness, negotiation/path, lifecycle cleanup, clock
math, evidence integrity, secret safety and missing Critical/High verification.

- [ ] **Step 3: Fix and re-review**

Reproduce accepted findings, add the smallest regression test, rerun affected real E2E, and return
to the same reviewer. Stop with no mandatory finding or after three rounds.

- [ ] **Step 4: Completion audit**

Prove preview inputs, TV-only APK, reference config, receiver lifecycle, Mac CLI code, H.264-only
1080p render, both paths, four functional runs, six calibrated runs, signaling timing, Android
metrics, image/quality evidence, secret scan, cleanup, full verification and clean worktree.

- [ ] **Step 5: Final repository report**

Report implementation, files, design choices, test/E2E evidence, review/fixes, commits, branch/
worktree state and physical-TV/public-signaling/optical-latency follow-ups.

## Execution findings

- 2026-07-16: The approved research boundary is formalized by design commit `aacebef` on
  `codex/android-tv-receiver`.
- 2026-07-16: Preview AAR local SHA and upstream runtime evidence match the immutable release. The
  downstream repository still contains the old XCFramework checksum, so Task 1 must replace bytes
  and manifest before E2E evidence is admissible.
- 2026-07-16: M150 AAR exposes CastTuning controller/decoder factory, recv-only transceivers, codec
  preferences, RTCStats and SurfaceViewRenderer. Decoder low-latency fallback has no public callback;
  evidence combines app JSONL requested state, RTCStats implementation and process-filtered logcat.
- 2026-07-16: Task 1 pinned and locally verified both preview assets. The AAR JNI bytes are identical
  after APK packaging (`e8fe64a1097141f440e0f354895ee2827bc28a210a50502b17774134ca143a49`),
  Gradle/AGP configure both ICE variants, and the provisioned `WebRTCScreencast_TV_API_31` is an
  Android 12 TV `arm64-v8a` AVD with the `tv_1080p` 1920×1080 device definition.
- 2026-07-16: Task 2's config, protocol, lifecycle and clock contracts pass both ICE-flavor unit
  suites and lint. Android resource merging treats arbitrary files inside `res/values` as XML
  resources even with an `.example` suffix, so the credential-free override example lives at the
  app module root and documents the ignored `src/debug/res/values` destination.
- 2026-07-16: Android API 26 does not provide `java.util.HexFormat`; the redacted config identity
  uses a local lowercase SHA-256 hex encoder instead of raising the minimum SDK or hiding the issue
  with a lint baseline.
- 2026-07-16: Upstream Action run `29439085060` succeeded and published artifact `8353870165`.
  Its AAR SHA-256 is `c79ba807b38cedd9b82f6c54ada8a89b9e4da6c14ec3dc4361b5d45410ba6744`;
  all 418 classfiles are Java 8 major 52, raw-package equivalence passes, and the exact AAR is also
  available at `~/Downloads/webrtc-m150-android-arm64-v8a.aar`.
- 2026-07-16: Task 3 adds a session-free `/clock` response and matching Java/Swift minimum-RTT
  calibration math. macOS records five-sample offset, RTT and uncertainty; automated media-baseline
  mode fails if calibration is unavailable, while normal interactive operation records the absence
  and continues.
- 2026-07-16: Real emulator runs proved Direct host/prflx/UDP and production relay/relay/UDP H.264
  1920×1080 media, but also showed that WindowServer does not feed a chart window owned by the
  capturing process into the virtual-display stream. Both `desktopIndependentWindow` and
  `display + included window` variants produced zero capture callbacks and retained the private
  display until user-session reset. The selected design restores the normal display filter and
  presents the chart from an internal child process; direct frame injection was rejected because
  it would remove ScreenCaptureKit from the measured capture path.
- 2026-07-16: After Screen Recording permission was refreshed by logout/login, short fresh-code E2E
  `run.7Uw0wi` passed Direct/main and `run.bAsNma` passed Direct/virtual media-baseline. Both rendered
  H.264 at 1920x1080 over non-relay UDP, recovered a new pairing code after teardown and finished
  with zero managed virtual displays. The virtual run correlated 40 marker sequences; its 18
  post-warm-up samples measured calibrated software-marker end-to-end p50 61.26 ms and p95 76.78 ms.
  These short runs intentionally skipped image-quality scoring; formal 80-second runs provide
  PSNR/SSIM/VMAF and heatmaps.
- 2026-07-16: The API 31 TV AVD can persistently disable `AndroidWifi` after a no-internet decision,
  removing the route to `10.0.2.2`. The authoritative E2E now checks that route and reconnects the
  existing network before clock calibration. Script tests cover recovery, already-ready and bounded
  failure paths. Formal baseline supports `--skip-macos-build` so the already authorized app is not
  rebuilt or re-signed between Screen Recording grant and E2E execution.
- 2026-07-16: Formal functional artifact root
  `artifacts/android-tv-e2e/20260715T233910Z-3bc825c-android-tv.5lNrht` passed all four fresh
  sessions: Direct/main `run.muOEZG`, Direct/virtual `run.fR1j2A`, TURN/main `run.6SikBN` and
  TURN/virtual `run.1wykmX`. Every run proved H.264 1920x1080 render, the requested UDP selected
  path, sender/receiver telemetry, fresh-code recovery and zero managed virtual displays. Visual
  inspection confirmed a TV-safe waiting-code screen and full-frame playback for both profiles;
  `showsCursor` remained true.
- 2026-07-16: The same root completed six alternating 80-second quantitative sessions:
  Direct `run.X01gzk`, TURN `run.LQgISi`, Direct `run.gYDIR6`, TURN `run.2nUz1G`, Direct
  `run.pigJMN`, TURN `run.HZxVyF`. The aggregate contains 360 Direct and 359 TURN calibrated marker
  samples; one measurement-edge TURN marker lacked a complete triplet and was excluded rather than
  synthesized. Direct software-marker E2E is p50 62.24 ms / p95 77.39 ms; TURN/UDP is p50 70.58 ms
  / p95 84.69 ms. TURN minus Direct paired p50 deltas are +8.01, +5.95 and +11.89 ms.
- 2026-07-16: The quantitative tree contains six reports, 18 source/capture/decoded 1920x1080 PNGs,
  54 heatmaps and 54 VMAF JSON outputs. Median capture-to-Android quality is Direct PSNR-Y 38.41 dB,
  SSIM-Y 0.99797 and VMAF reference 96.50; TURN is 38.38 dB, 0.99786 and 96.38. Versioned reports
  are `baselines/2026-07-15-3bc825c-android-tv.{json,md}`; their recorded input hashes match the
  pinned AAR/XCFramework, `git_dirty=false`, and the complete raw/versioned secret scan passed.
- 2026-07-16: Post-baseline verification passed `make verify`, including Go race tests, macOS tests
  and build, Android dual-flavor unit/lint/build, script/analyzer/aggregate suites and artifact
  verification. The API 31 arm64 TV emulator also passed all five
  `connectedDirectBaselineDebugAndroidTest` tests; emulator shutdown and managed-display count zero
  were verified afterward.
