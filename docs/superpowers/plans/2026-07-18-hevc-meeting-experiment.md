# HEVC Meeting Screencast Experiment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and execute a bounded H.264/H.265 meeting-screencast experiment using a fixed Chrome document, the product's real STATIC/ACTIVE MaxQP policy, verified VideoToolbox telemetry, screenshot inspection, and decision gates.

**Architecture:** `my-webrtc-builds` adds encoder-level QP/drop evidence to the CastTuning snapshot and publishes verified macOS/Android artifacts. This repository adds optional-QP content-aware control, a pinned offline Chrome workload, a staged experiment orchestrator, evidence analysis, and the final execution report. Existing E2E, marker, image-quality, TURN/UDP, and secret-scanning paths are reused rather than duplicated.

**Tech Stack:** Objective-C++/VideoToolbox/libwebrtc M150, Swift/XCTest, Python `unittest`, zsh, Playwright CLI with Google Chrome, Android TV emulator, FFmpeg PSNR/SSIM/VMAF, jq.

---

### Task 1: Commit the approved experiment documents

**Files:**
- Create: `docs/superpowers/specs/2026-07-18-hevc-meeting-experiment-design.md`
- Create: `docs/superpowers/plans/2026-07-18-hevc-meeting-experiment.md`

- [ ] **Step 1: Review both documents for placeholders and contradictions**

Run:

```bash
rg -n 'T[B]D|TO[D]O|implement la[t]er|fill i[n]' docs/superpowers/{specs,plans}/2026-07-18-hevc-meeting-experiment*
git diff --check
```

Expected: no placeholder matches and no whitespace errors.

- [ ] **Step 2: Commit the approved documents**

```bash
git add docs/superpowers/specs/2026-07-18-hevc-meeting-experiment-design.md docs/superpowers/plans/2026-07-18-hevc-meeting-experiment.md
git commit -m "docs: design HEVC meeting experiment"
```

### Task 2: Add VideoToolbox QP/drop telemetry in the builder

**Files:**
- Modify: `/Users/aweffr/developer/aweffr/my-webrtc-builds/tests/test_cast_tuning_overlay.py`
- Modify: `/Users/aweffr/developer/aweffr/my-webrtc-builds/patches/m150/macos_hevc_cast_tuning.patch`
- Modify: `/Users/aweffr/developer/aweffr/my-webrtc-builds/patches/m150/cast_tuning_hooks.patch`
- Modify: `/Users/aweffr/developer/aweffr/my-webrtc-builds/tools/macos-videotoolbox-probe.mm`

- [ ] **Step 1: Write failing overlay contract tests**

Add assertions that the patched encoder snapshot exposes `key_frame_qp_histogram`, `delta_frame_qp_histogram`, `video_toolbox_frames_submitted`, `video_toolbox_frames_encoded`, and `video_toolbox_frames_dropped`; require the output callback to increment encoded or dropped exactly once.

- [ ] **Step 2: Run the focused test and verify RED**

```bash
python3 -m unittest tests.test_cast_tuning_overlay -v
```

Expected: FAIL because the new snapshot fields and counters do not exist.

- [ ] **Step 3: Implement minimal encoder counters and snapshot fields**

Maintain two fixed 52-entry histograms guarded by the encoder's existing synchronization. Increment submitted before `VTCompressionSessionEncodeFrame`; increment dropped when `kVTEncodeInfo_FrameDropped` is set; otherwise increment encoded and the appropriate key/delta QP bucket when parsing succeeds. Expose immutable NSDictionary/NSArray snapshots through the existing CastTuning snapshot boundary.

- [ ] **Step 4: Verify GREEN and run the hardware probe**

```bash
python3 -m unittest tests.test_cast_tuning_overlay -v
python3 -m unittest discover -s tests -v
tools/run-macos-videotoolbox-probe.sh
```

Expected: tests pass; probe reports H.265 encoder identity, QP evidence, and internally consistent submitted/encoded/dropped totals.

- [ ] **Step 5: Commit builder telemetry**

```bash
git add tests/test_cast_tuning_overlay.py patches/m150/macos_hevc_cast_tuning.patch patches/m150/cast_tuning_hooks.patch tools/macos-videotoolbox-probe.mm
git commit -m "feat: expose VideoToolbox QP and drop telemetry"
```

### Task 3: Build and install exact WebRTC artifacts

**Files:**
- Modify only generated/ignored artifact directories in both repositories.

- [ ] **Step 1: Run builder verification**

```bash
python3 -m unittest discover -s tests -v
```

Expected: full builder suite passes.

- [ ] **Step 2: Build macOS arm64 and Android artifacts using existing workflows**

Dispatch the existing GitHub workflows from the builder's committed main SHA, wait for success, download the macOS tarball and Android AAR, and verify release metadata and SHA-256 with existing builder commands.

- [ ] **Step 3: Install exact artifacts downstream**

Set `WEBRTC_MACOS_TAR_GZ` and `WEBRTC_ANDROID_AAR` to the downloaded files, run `scripts/bootstrap-webrtc.sh`, then record builder SHA and artifact hashes in the experiment preparation notes.

Expected: downstream bootstrap and checksum verification succeed without tracked artifact changes.

### Task 4: Make content-aware QP optional for RTVC

**Files:**
- Modify: `apps/macos/WebRTCScreencast/WebRTC/StaticClarityRefreshController.swift`
- Modify: `apps/macos/WebRTCScreencast/WebRTC/WebRTCSession.swift`
- Modify: `apps/macos/WebRTCScreencastTests/StaticClarityRefreshControllerTests.swift`

- [ ] **Step 1: Write failing XCTest cases**

Add a case where `staticMaxQp` and `motionMaxQp` are nil. Assert STATIC/ACTIVE still apply 1/15 fps and bitrate, no MaxQP is included in either live patch, and force-key-frame behavior remains unchanged.

- [ ] **Step 2: Run focused XCTest and verify RED**

```bash
xcodebuild test -project apps/macos/WebRTCScreencast.xcodeproj -scheme WebRTCScreencast -destination 'platform=macOS' -only-testing:WebRTCScreencastTests/StaticClarityRefreshControllerTests
```

Expected: compile/test failure because MaxQP is currently non-optional.

- [ ] **Step 3: Implement optional MaxQP**

Change `ApplyLivePolicy` to accept `Int?`. For ordinary sessions pass static/motion values and set `patch.maxQp`; when CastTuning requests Apple Low Latency Rate Control pass nil and omit `patch.maxQp`. Keep FPS, bitrate, rollback, IDR, and counters unchanged.

- [ ] **Step 4: Verify GREEN**

Run the focused test and the complete macOS XCTest suite. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/WebRTCScreencast/WebRTC/StaticClarityRefreshController.swift apps/macos/WebRTCScreencast/WebRTC/WebRTCSession.swift apps/macos/WebRTCScreencastTests/StaticClarityRefreshControllerTests.swift
git commit -m "fix(macos): preserve content cadence with HEVC RTVC"
```

### Task 5: Normalize new sender telemetry

**Files:**
- Modify: `apps/macos/WebRTCScreencast/WebRTC/WebRTCSession.swift`
- Modify: `apps/macos/WebRTCScreencast/Observability/SessionMetricsSampler.swift`
- Modify: `apps/macos/WebRTCScreencastTests/RTCStatsNormalizerTests.swift`

- [ ] **Step 1: Write failing snapshot serialization tests**

Create a sender snapshot with 52-entry key/delta histograms and submitted/encoded/dropped values. Assert JSON fields preserve all buckets and counters without converting absent data to zero.

- [ ] **Step 2: Verify RED**

Run the focused macOS test. Expected: FAIL because the new fields are missing.

- [ ] **Step 3: Implement minimal typed fields and JSON serialization**

Read the new CastTuning snapshot values in `senderMediaBoundarySnapshot()` and serialize them under `sender_media_boundary`.

- [ ] **Step 4: Verify GREEN and commit**

Run focused and full macOS tests, then commit with:

```bash
git commit -m "feat(macos): record encoder QP and drop distributions"
```

### Task 6: Add the pinned offline Chrome document

**Files:**
- Create: `experiments/hevc-meeting/source.json`
- Create: `experiments/hevc-meeting/document.html`
- Create: `experiments/hevc-meeting/document.css`
- Create: `scripts/prepare-hevc-meeting-document.py`
- Create: `scripts/test_hevc_meeting_document.py`

- [ ] **Step 1: Write failing preparation tests**

Test exact source commit/path/SHA-256, front-matter removal, shortcode removal, absence of HTTP(S) subresources, presence of Chinese text/table/code, fixed marker container, and deterministic repeated output.

- [ ] **Step 2: Verify RED**

```bash
python3 -m unittest scripts.test_hevc_meeting_document -v
```

Expected: FAIL because the preparation module and fixture do not exist.

- [ ] **Step 3: Implement and generate fixture**

Fetch the pinned source through GitHub API, verify SHA-256, normalize source, render Markdown through GitHub's Markdown endpoint, wrap it with fixed local CSS, source attribution, and the existing marker layout. Generated HTML must reference only `document.css`.

- [ ] **Step 4: Verify render**

Run the test, serve `experiments/hevc-meeting` on localhost, open it with headed Google Chrome, resize/fullscreen, and capture a PNG. Inspect the PNG with the image viewer for Chinese text, code, tables, no missing assets, and sufficient scroll length.

- [ ] **Step 5: Commit**

```bash
git add experiments/hevc-meeting scripts/prepare-hevc-meeting-document.py scripts/test_hevc_meeting_document.py
git commit -m "feat(experiment): add fixed Chrome meeting document"
```

### Task 7: Implement deterministic Chrome workload control

**Files:**
- Create: `scripts/hevc_meeting_workload.py`
- Create: `scripts/test_hevc_meeting_workload.py`

- [ ] **Step 1: Write failing schedule and evidence tests**

Assert six 720 px scrolls at eight-second intervals, each decomposed into twelve 60 px steps at 50 ms, expected offsets 720…4320, 20-second initial static and 20-second final settle. Assert offset mismatch makes a run invalid. The eight-second window is part of the experiment contract because it gives the existing STATIC/ACTIVE controller enough observable time to return to STATIC before the next burst.

- [ ] **Step 2: Verify RED**

```bash
python3 -m unittest scripts.test_hevc_meeting_workload -v
```

- [ ] **Step 3: Implement workload orchestration**

Use a named Playwright CLI session with `--browser chrome --headed` and a temporary profile. Wait for page readiness, verify Chrome version, execute `mousemove`/`mousewheel`, query `scrollY`, and append JSONL events containing sequence, planned/actual monotonic time, expected/actual offset, and validity.

- [ ] **Step 4: Run live Chrome smoke and inspect screenshots**

Serve the fixture, execute a shortened schedule, inspect initial/middle/final PNGs with the image viewer, and verify offset JSONL.

- [ ] **Step 5: Commit**

```bash
git add scripts/hevc_meeting_workload.py scripts/test_hevc_meeting_workload.py
git commit -m "feat(experiment): automate deterministic Chrome scrolling"
```

### Task 8: Define the bounded policy matrix and gates

**Files:**
- Create: `scripts/hevc_meeting_experiment.py`
- Create: `scripts/test_hevc_meeting_experiment.py`

- [ ] **Step 1: Write failing policy tests**

Assert A0=`h264-only/24/32`, A1=`h265-only/24/32`, B0=`h265-only/33/39`, B1=`h265-only/30/39`; assert C0/C1/C2 modify exactly one flag; assert the stage order, early-stop rule, per-case retry limit, global retry limit four, and total attempt cap 23.

- [ ] **Step 2: Write failing gate tests**

Use small JSON fixtures to cover first-frame +100 ms, ACTIVE p95 +10 ms, freeze 500 ms, drop 1%, exact 6/6 marker sequence delivery, bitrate 5 Mbps, SSIM -0.002 and PSNR -0.5 dB boundaries. Test the documented winner ordering and tie behavior.

- [ ] **Step 3: Verify RED**

```bash
python3 -m unittest scripts.test_hevc_meeting_experiment -v
```

- [ ] **Step 4: Implement policy generation and analysis**

Generate per-case runtime and CastTuning JSON, consume existing E2E analysis plus workload/telemetry evidence, validate six state cycles and screenshot bindings, aggregate repeats, apply gates, and emit JSON plus Chinese Markdown.

- [ ] **Step 5: Verify GREEN and commit**

```bash
python3 -m unittest scripts.test_hevc_meeting_experiment -v
git commit -m "feat(experiment): add bounded HEVC policy analysis"
```

### Task 9: Integrate the experiment runner

**Files:**
- Create: `scripts/run-hevc-meeting-experiment.sh`
- Modify: `scripts/run-android-tv-e2e.sh`
- Modify: `scripts/test-verifiers.sh`

- [ ] **Step 1: Write failing script/verifier cases**

Require explicit codec policy, Chrome evidence, exact requested/effective QP for ordinary cases, RTVC encoder identity for C2, complete initial/middle/final image evidence, state transitions, and attempt limits.

- [ ] **Step 2: Verify RED**

```bash
./scripts/test-verifiers.sh
python3 -m unittest scripts.test_hevc_meeting_experiment -v
```

- [ ] **Step 3: Implement orchestration**

Reuse `run-android-tv-e2e.sh` for signaling, TURN, Android lifecycle, diagnostics and cleanup. Start the localhost document server and Chrome workload around the main-screen Sender. Preserve failed attempts, never overwrite evidence, and run the configured-secret scanner before accepting a case.

- [ ] **Step 4: Verify GREEN and commit**

Run script tests and shell syntax checks, then commit with:

```bash
git commit -m "feat(experiment): orchestrate HEVC meeting trials"
```

### Task 10: Run smoke and the formal experiment

**Files:**
- Create only ignored files under `artifacts/hevc-meeting/` during execution.
- Append execution findings to this plan after results are final.

- [ ] **Step 1: Run preflight and one short A0/A1 smoke**

Verify Screen Recording, Chrome version, Android route, TURN credentials, selected relay/UDP path, codec, state transitions, QP binding, screenshots, and cleanup.

- [ ] **Step 2: Inspect smoke screenshots personally**

Open initial/middle/final source and Android images with the image viewer. Confirm readable Chinese text/code, actual scroll displacement, no black frame/crop/scale error, and final static recovery.

- [ ] **Step 3: Execute A0/A1 and B0/B1 stages**

Run the documented interleaved order. Stop after 12 valid runs if every HEVC policy fails hard gates.

- [ ] **Step 4: Execute C0/C1/C2 and optional confirmation**

Only run feature flags when a normal HEVC winner exists. Enforce global retry and attempt caps.

- [ ] **Step 5: Inspect every formal case's screenshots personally**

Use the image viewer on each case's initial static, middle scroll and final static Android image. Record case-level observations in the report; metrics alone are insufficient.

- [ ] **Step 6: Render and audit final report**

Confirm raw evidence, aggregate JSON, Markdown, artifact hashes, no credentials, no stale Chrome process, no managed virtual display, and a clean Android emulator state.

### Task 11: Full verification and review

**Files:**
- Modify the design/plan only for material execution findings or follow-ups.

- [ ] **Step 1: Run complete verification**

```bash
make verify
git diff --check
git status --short
```

Expected: all macOS, Android, Go, script and artifact checks pass; only intentional tracked changes remain before commit.

- [ ] **Step 2: Commit final implementation/findings**

Use focused conventional commits; do not add logs, credentials, caches or raw experiment artifacts.

- [ ] **Step 3: Request clean-context code review**

Provide the original requirement, approved design/plan, builder/downstream SHAs, diff, test/E2E evidence, screenshot-inspection notes, and known emulator-only boundary. Limit review to requirement alignment and Critical/High risks.

- [ ] **Step 4: Fix valid findings and rerun verification**

Use at most three review/fix rounds. Reject low-value style or unrelated refactor suggestions.

- [ ] **Step 5: Completion audit**

Map every design requirement to code, tests, raw runtime evidence, viewed images, report output, git commits and clean repository state before marking the long-horizon goal complete.

## Execution findings

The bounded base experiment completed on 2026-07-18 from app commit `5f24ad1f6e2a8eedb0b9523ffbdf7792facdbb2b`, builder commit `da7818a854bb5d227f306af9816d2b54ebc7a74e`, and Chrome `150.0.7871.129`. The accepted evidence root is `artifacts/hevc-meeting/20260718T022620Z/`; all 12 A0/A1/B0/B1 runs were valid with no infrastructure retry. The first launch correctly failed before E2E when Chrome had auto-updated from the previously pinned version, after which the version contract was updated in a clean commit and the experiment restarted in a fresh evidence root.

All three HEVC base candidates failed at least the static-image-quality and content-aware state-cycle gates. A1 also exceeded the freeze threshold; B1 exceeded both the ACTIVE-latency and freeze thresholds. Per the predefined early-stop rule, C0/C1/C2 were not run. This is completion of the experiment plan, not missing coverage: feature flags do not have deployment value until an ordinary HEVC base policy passes.

The operator opened the 12 original-resolution inspection sheets covering sender full view, Android full view, and Android text detail for every case across initial/middle/final samples. HEVC remained readable but showed a consistent brighter/washed Y-plane and weaker pale-border contrast relative to A0; B0 and B1 were visually indistinguishable. Direct comparison of B0 run-2 workload and sender originals also showed that the fixed overlay marker can precede the body compositor update, so marker ACTIVE p95 is retained only as directional evidence.

The final tracked result and follow-up boundary are in `docs/experiments/2026-07-18-hevc-meeting.md`. The production decision is to keep the default sender policy as prefer H.264 while retaining all four explicit codec strategies. The next bounded iteration is limited to HEVC color-range consistency, STATIC/ACTIVE detector stability, and content-bound latency evidence, followed by a rerun of A0/A1/B0/B1 only.
