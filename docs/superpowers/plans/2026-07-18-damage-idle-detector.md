# Damage Idle Detector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace callback-coupled luma stability detection with a ScreenCaptureKit damage/quiet-deadline detector and prove that it improves reliable STATIC/ACTIVE switching without degrading meeting-cast latency or clarity.

**Architecture:** A pure `DamageIdleDetector` owns the two-state model and monotonic deadline. `ScreenCaptureSource` serializes callbacks and one self-rearming quiet check on its existing capture queue, caches the latest complete frame, and submits a synthetic clarity refresh when the deadline expires. Existing FrameGate and WebRTC content-aware QP controller remain separate.

**Tech Stack:** Swift 6, ScreenCaptureKit, CoreVideo, VideoToolbox through CastTuning, XCTest, Python unittest, Playwright CLI, Android TV API 31 E2E.

---

### Task 1: Preserve the D0 executable and implement the pure detector with TDD

**Files:**
- Create: `apps/macos/WebRTCScreencast/Capture/DamageIdleDetector.swift`
- Create: `apps/macos/WebRTCScreencastTests/DamageIdleDetectorTests.swift`
- Delete after green: `apps/macos/WebRTCScreencast/Capture/VisualStabilityDetector.swift`
- Delete after green: `apps/macos/WebRTCScreencastTests/VisualStabilityDetectorTests.swift`

- [ ] Build the unchanged app and retain its ignored app bundle as D0:

```bash
make build-macos
mkdir -p artifacts/damage-idle/apps
ditto DerivedData/Build/Products/Debug/WebRTCScreencast.app artifacts/damage-idle/apps/D0-WebRTCScreencast.app
shasum -a 256 artifacts/damage-idle/apps/D0-WebRTCScreencast.app/Contents/MacOS/WebRTCScreencast
```

- [ ] Write failing XCTest cases for initial ACTIVE, 600 ms deadline, repeated damage deadline extension, STATIC→ACTIVE, out-of-order timestamps, and stale lifecycle generation. The intended public contract is:

```swift
enum ContentActivityMode: String, Equatable, Sendable {
    case active
    case staticClarity = "static_clarity"
}

enum ContentActivityTransition: Equatable, Sendable {
    case none
    case enterStaticClarity
    case exitStaticClarity
}

struct DamageIdleDecision: Equatable, Sendable {
    let mode: ContentActivityMode
    let transition: ContentActivityTransition
    let lastDamageMonotonicNs: UInt64?
    let quietDeadlineMonotonicNs: UInt64?
    let nextQuietDeadlineMonotonicNs: UInt64?
}

struct DamageIdleDetector: Sendable {
    init(quietDurationNs: UInt64 = 600_000_000)
    mutating func start() -> UInt64
    mutating func stop()
    mutating func observeDamage(at monotonicNs: UInt64) -> DamageIdleDecision
    mutating func settleIfDue(at monotonicNs: UInt64, generation: UInt64) -> DamageIdleDecision
}
```

- [ ] Generate the Xcode project and verify RED:

```bash
cd apps/macos && xcodegen generate && cd ../..
xcodebuild test -project apps/macos/WebRTCScreencast.xcodeproj -scheme WebRTCScreencast -destination 'platform=macOS' -derivedDataPath DerivedData -only-testing:WebRTCScreencastTests/DamageIdleDetectorTests
```

Expected: compile/test failure because `DamageIdleDetector` does not exist.

- [ ] Implement the smallest two-state detector. `observeDamage` ignores timestamps older than the latest observation; accepted damage always moves the deadline to `now + quietDurationNs`; `settleIfDue` ignores stale generations and enters STATIC once.

- [ ] Replace the generated project references from the deleted VisualStability files with DamageIdle files by regenerating, then rerun the focused test until PASS.

- [ ] Commit:

```bash
git add apps/macos/WebRTCScreencast/Capture apps/macos/WebRTCScreencastTests apps/macos/WebRTCScreencast.xcodeproj/project.pbxproj
git commit -m "feat: add damage idle detector"
```

### Task 2: Drive the detector from the existing capture queue

**Files:**
- Modify: `apps/macos/WebRTCScreencast/Capture/ScreenCaptureSource.swift`
- Modify: `apps/macos/WebRTCScreencast/WebRTC/StaticClarityRefreshController.swift`
- Modify: `apps/macos/WebRTCScreencast/WebRTC/WebRTCSession.swift`
- Modify: `apps/macos/WebRTCScreencastTests/StaticClarityRefreshControllerTests.swift`

- [ ] Write failing tests that rename controller state/transition contracts to `ContentActivityMode` and `ContentActivityTransition`, and verify the boundary applies ACTIVE policy before forwarding an activity frame. Keep the existing failure-retry tests.

- [ ] Verify RED with:

```bash
xcodebuild test -project apps/macos/WebRTCScreencast.xcodeproj -scheme WebRTCScreencast -destination 'platform=macOS' -derivedDataPath DerivedData -only-testing:WebRTCScreencastTests/StaticClarityRefreshControllerTests -only-testing:WebRTCScreencastTests/WebRTCSessionConstructionTests
```

- [ ] Replace luma sampling in `ScreenCaptureSource` with these rules:
  - `.started`, `dirtyRects == nil`, or non-empty dirty rects call `observeDamage` with `MediaBaselineClock.nowNs`.
  - Empty dirty rects do not update activity.
  - Cache every valid `.started`/`.complete` pixel buffer and its display metadata before FrameGate decides whether to submit.
  - Maintain one `quietCheckScheduled` flag. The first damage schedules `captureQueue.asyncAfter`; later damage only updates the detector deadline. A check that fires early schedules the remaining interval; a due check emits one synthetic frame.
  - Capture the detector generation in the closure. `stop()` advances generation and clears the cached frame on `captureQueue`, invalidating old checks without another thread or lock.

- [ ] Synthetic frames use `MediaBaselineClock.nowNs` for both callback evidence and a fresh `Int64` WebRTC timestamp. They carry `enterStaticClarity`, bypass FrameGate, apply 1 fps/static MaxQP, force IDR, and then forward the cached pixel buffer.

- [ ] Change `WebRTCSession.screenCaptureSource` so a failed transition returns `false` without forwarding that frame. Successful ACTIVE restoration therefore happens before the first real activity frame. Keep the transition latch pending on failure.

- [ ] Run focused detector/controller/session tests, then commit:

```bash
git add apps/macos/WebRTCScreencast apps/macos/WebRTCScreencastTests
git commit -m "feat: switch static clarity on damage deadlines"
```

### Task 3: Replace visual telemetry with exact activity evidence

**Files:**
- Modify: `apps/macos/WebRTCScreencast/Capture/ScreenCaptureSource.swift`
- Modify: `apps/macos/WebRTCScreencast/Observability/SessionMetricsSampler.swift`
- Modify: `apps/macos/WebRTCScreencast/WebRTC/WebRTCSession.swift`
- Modify: `apps/macos/WebRTCScreencastTests/SessionMetricsSamplerTests.swift`
- Modify: `apps/macos/WebRTCScreencastTests/WebRTCSessionConstructionTests.swift`

- [ ] Write failing serialization tests for these capture fields:

```text
content_activity_mode
last_damage_monotonic_ns
quiet_deadline_monotonic_ns
last_active_transition_monotonic_ns
last_static_transition_monotonic_ns
active_transition_count
static_transition_count
synthetic_clarity_refreshes
```

The two transition timestamps are retained because the 1 Hz metrics sampler must still prove ACTIVE response time and the 600–900 ms quiet gate exactly.

- [ ] Verify RED, implement the fields under the existing telemetry lock, and remove `visual_stability_mode`, `visual_changed_sample_ratio`, and `clarity_refresh_requests`.

- [ ] Rename sender-boundary clarity mode to the same two-state type without changing existing QP/session/keyframe counters.

- [ ] Run all macOS tests and commit:

```bash
make test-macos
git add apps/macos
git commit -m "feat: expose content activity telemetry"
```

### Task 4: Build the fixed six-episode Chrome workload

**Files:**
- Modify: `experiments/hevc-meeting/document.html`
- Modify: `experiments/hevc-meeting/document.css`
- Create: `scripts/damage_idle_workload.py`
- Create: `scripts/test_damage_idle_workload.py`
- Modify: `apps/macos/WebRTCScreencast/MediaBaseline/MediaBaselineChart.swift`
- Modify: `apps/android-tv/app/src/main/java/cn/aweffr/webrtcscreencast/tv/observability/AndroidMarkerProbe.java`
- Modify: corresponding macOS and Android marker tests

- [ ] Write failing Python schedule/program tests for exactly:

```text
20s initial static
t=20 fast scroll: 12 × 60 px × 50 ms
t=28 fast scroll: 12 × 60 px × 50 ms
t=36 fast scroll: 12 × 60 px × 50 ms
t=44 slow scroll: 40 × 18 px × 50 ms
t=52 type fixed 16 px Chinese/ASCII text × 80 ms, then blur
t=60 move cursor over 12 fixed points × 50 ms
t=68 begin final static; finish at t=88
```

- [ ] Convert the browser marker from `position: fixed` to an absolute element in document flow. Before each scroll, place it at `targetScrollY + 64 px` so the fixed-distance scroll brings it into the existing on-screen probe ROI. Typing and the first cursor movement update sequences 6 and 7 respectively. Do not create a final marker update after the sixth episode.

- [ ] Retain marker PNGs for sequences 1–8 in both sender and Android probes while preserving existing 30/80/130 virtual-baseline samples.

- [ ] Capture workload screenshots named `initial`, `fast`, `slow`, `typed`, `cursor`, and `final`; record SHA-256 and exact monotonic episode timing in JSONL.

- [ ] Run Python, macOS marker, and Android marker tests, then commit:

```bash
python3 -m unittest scripts.test_damage_idle_workload
xcodebuild test -project apps/macos/WebRTCScreencast.xcodeproj -scheme WebRTCScreencast -destination 'platform=macOS' -derivedDataPath DerivedData -only-testing:WebRTCScreencastTests/MediaBaselineMarkerTests
./apps/android-tv/gradlew -p apps/android-tv test
git add experiments scripts apps/macos apps/android-tv
git commit -m "test: add fixed damage idle workload"
```

### Task 5: Add bounded D0/D1 experiment orchestration and gates

**Files:**
- Create: `scripts/damage_idle_experiment.py`
- Create: `scripts/test_damage_idle_experiment.py`
- Create: `scripts/run-damage-idle-experiment.sh`
- Modify: `scripts/run-android-tv-e2e.sh`
- Modify: `scripts/test-verifiers.sh`

- [ ] Test-first add `--macos-app-bundle` to the E2E runner. A supplied bundle must be absolute/readable, skips the macOS build, and is the exact executable launched and hashed; default behavior remains unchanged.

- [ ] Write failing analyzer tests for:
  - D1 six ACTIVE transitions within 200 ms of episode marker commits;
  - seven STATIC transitions 600–900 ms after the latest damage;
  - exactly 6 restores, 7 successful/static transitions, and 7 synthetic refreshes;
  - 6/6 marker delivery, QP generation/session binding, first frame, active E2E p95, render gap, VT drop, bitrate, SSIM/PSNR and manual image gate;
  - D0 as reference without requiring D1-only capture fields;
  - H.265 smoke authorization only after aggregate D1 gates pass.

- [ ] Implement only three cases:

```text
D0: archived old app, H.264-only, STATIC/ACTIVE MaxQP 24/32
D1: new app, H.264-only, STATIC/ACTIVE MaxQP 24/32
H1: new app, H.265-only, STATIC/ACTIVE MaxQP 33/39
```

The formal order is `D0,D1,D1,D0,D0,D1`; H1 runs once only after D1 passes. Each formal case may retry once for infrastructure failure, with no parameter sweep.

- [ ] Implement aggregate gates: D1 p95 ≤ D0 +10 ms, first frame ≤ D0 +100 ms, render gap ≤500 ms, VT drop ≤1%, bitrate ≤D0 +5%, SSIM loss ≤0.002, PSNR loss ≤0.5 dB, and all manual screenshots clear.

- [ ] Run script tests and shell verifier tests, then commit:

```bash
python3 -m unittest scripts.test_damage_idle_experiment
./scripts/test-verifiers.sh
git add scripts
git commit -m "test: automate damage idle experiment"
```

### Task 6: Static verification and formal E2E experiment

**Files:**
- Modify only if findings affect confirmed design: design/plan `Execution findings`
- Create after privacy strip: `docs/experiments/2026-07-18-damage-idle-detector.md`
- Create after privacy strip: selected PNGs under `docs/experiments/2026-07-18-damage-idle-detector/`

- [ ] Run the complete static suite from a clean tracked worktree:

```bash
make verify
git diff --check
```

- [ ] Build and archive D1, then run the six formal H.264 runs with the fixed Chrome version, local Kubernetes document, production-relay UDP profile and API 31 Android emulator. Run H1 once only after D1 gates pass.

- [ ] If and only if D1's sole failure is compositor damage between 600 and 1000 ms, change the quiet duration to 1000 ms and rerun D1 three times. Otherwise stop and diagnose without adding states or cases.

- [ ] Inspect every initial/fast/slow/typed/cursor/final sender and Android image using original-resolution image viewing. Record blur, cropping, stale frame, marker corruption, or privacy findings per case.

- [ ] Scan retained evidence for configured secrets, local paths, usernames, pairing codes, IPs, and unrelated desktop content. Publish only sanitized aggregate JSON/Markdown and selected document/receiver images.

- [ ] Commit conclusions and sanitized images:

```bash
git add docs/experiments docs/superpowers
git commit -m "docs(experiment): report damage idle results"
```

### Task 7: Focused Code Review, final verification, and merge

- [ ] Run a clean-context reviewer with the original request, approved spec/plan, commit range, diff, verification evidence, experiment report and known risks. Limit findings to requirement alignment, Critical/High correctness, concurrency/lifecycle, telemetry truthfulness, E2E gate validity, privacy, and missing verification.

- [ ] Evaluate feedback using `receiving-code-review`; fix only confirmed Critical/High, blocking requirement gaps, or low-cost Medium issues in scope. Re-test each fix and return it to the same reviewer, for at most three rounds.

- [ ] Run final completion audit:

```bash
make verify
git diff --check
git status --short --branch
git log --oneline main..HEAD
```

- [ ] Merge the feature branch into local `main` with a non-destructive fast-forward or regular merge only if main has not diverged. Confirm main is clean, then remove the linked worktree and feature branch.

## Follow-ups deliberately excluded

- A 1→10→15 fps ramp, hybrid luma fallback, more STATIC/ACTIVE states, VideoToolbox flag sweeps, codec-default changes, and Android hardware-decoder testing require separate evidence and are not part of this implementation.

## Execution findings (2026-07-18)

- The implementation and full static verification completed. The detector remained a two-state value type; lifecycle scheduling stays on the existing capture queue and uses generation invalidation.
- D0 produced three analyzable H.264 runs. D1 produced two; both allowed attempts for D1 run-3 failed in Android emulator/receiver infrastructure, so the bounded runner correctly stopped without a third retry.
- Both D1 runs restored ACTIVE for all six business actions within 79.0 ms, applied the expected 24/32 MaxQP values, and reported zero VideoToolbox drops.
- The exact 6 ACTIVE / 7 STATIC assumption was invalid for this Chrome workload. Screenshots and compositor/scrollbar tail updates generated additional real dirty rects, producing 14/14 transitions per D1 run. Filtering those updates would contradict the approved detector contract.
- The sole 1000 ms fallback was not used because observed tail damage could occur about 1.4 seconds after the initiating scroll, outside its allowed condition.
- The Android gap tracker observes marker-decodable frames rather than every render callback, so its 21–22 second values cannot support the 500 ms render-gap gate. The report treats that gate as unmeasured instead of weakening it.
- H1 was not authorized. Sanitized conclusions and key screenshots are published in `docs/experiments/2026-07-18-damage-idle-detector.md`.
- The feature branch is not eligible for merge under the original gates: D1 has only two valid runs, the exact-count assumption failed, render gap is unmeasured, and the post-experiment mainline color-range merge has not been exercised by the D0/D1 workload. Merging requires an explicit gate waiver or a new current-HEAD formal run after measurement repair.
