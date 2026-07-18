# HEVC Color Range Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Identify and repair the first boundary that applies an extra limited-to-full luma expansion to HEVC meeting-cast video while preserving H.264 quality and the zero-copy low-latency sender path.

**Architecture:** A deterministic native VideoToolbox probe isolates Apple encoding from WebRTC and Android, then the existing RTC encoder probe and a direct Android decode probe isolate wrapper and renderer boundaries. Exactly one evidence-selected repair is implemented; final validation is limited to aligned H.264/HEVC static E2E runs.

**Tech Stack:** Objective-C++17, CoreVideo/CoreMedia/VideoToolbox, FFmpeg/ffprobe, Python 3 `unittest`, Swift 6/ScreenCaptureKit/XCTest, Java 17/MediaCodec/OpenGL ES, WebRTC M150, zsh.

**Design:** `docs/superpowers/specs/2026-07-18-hevc-color-range-design.md`

---

### Task 1: Prepare isolated builder workspace and verify baselines

**Files:**
- Modify only if required: `<my-webrtc-builds>/.gitignore`

- [ ] **Step 1: Create an ignored builder worktree**

Detect existing worktree isolation and `.worktrees/` ignore state. From the builder's local `main` commit, create branch `fix/hevc-color-range` at `<my-webrtc-builds>/.worktrees/hevc-color-range`. If `.worktrees/` is not ignored, add it and commit `chore: ignore local worktrees` before creation.

- [ ] **Step 2: Run builder baseline verification**

Run:

```bash
python3 -m unittest discover -s tests -v
./tools/run-macos-videotoolbox-probe.sh /absolute/path/to/webrtc-m150-macos-arm64.tar.gz
```

Expected: all repository tests pass and the existing H.264/H.265 hardware probe succeeds on Apple Silicon. Record artifact SHA-256 and evidence path in the execution findings.

### Task 2: Add behavior-tested range analysis

**Files:**
- Create: `<my-webrtc-builds>/tools/analyze-color-range-probe.py`
- Create: `<my-webrtc-builds>/tests/test_color_range_probe.py`

- [ ] **Step 1: Write RED tests for identity and limited-to-full detection**

Define `fit_mapping(expected, actual)` and `classify_mapping(expected, actual)` contracts. Tests use fixed vectors:

```python
FULL_CODES = [0, 1, 15, 16, 17, 32, 64, 128, 180, 219, 235, 240, 254, 255]
IDENTITY = FULL_CODES
LIMITED_EXPANDED = [max(0, min(255, round((value - 16) * 255 / 219))) for value in FULL_CODES]
```

Assert identity slope/intercept are approximately `1/0`, expanded mapping is classified `limited_to_full`, clipping counts include values below 16 and above 235, and malformed/missing cell data fails with an actionable exception.

- [ ] **Step 2: Verify RED**

Run:

```bash
python3 -m unittest tests.test_color_range_probe -v
```

Expected: import failure because `analyze-color-range-probe.py` does not exist.

- [ ] **Step 3: Implement the minimum analyzer**

Implement least-squares slope/intercept, MAE against identity and limited-to-full models, clipping counts, and a report gate. The gate compares H.264/H.265 cells with the same input contract and requires slope delta `<= 0.01`, intercept delta `<= 2`, patch median absolute error `<= 2`, and matching declared/observed range semantics.

- [ ] **Step 4: Verify GREEN and commit**

Run the focused test and `python3 -m unittest discover -s tests -v`. Commit:

```bash
git add tools/analyze-color-range-probe.py tests/test_color_range_probe.py
git commit -m "test: define color range probe contracts"
```

### Task 3: Implement the four-cell native VideoToolbox probe

**Files:**
- Create: `<my-webrtc-builds>/tools/macos-color-range-probe/main.mm`
- Create: `<my-webrtc-builds>/tools/run-macos-color-range-probe.sh`
- Modify: `<my-webrtc-builds>/tests/test_color_range_probe.py`

- [ ] **Step 1: Add RED runner-contract tests**

Add tests for the manifest schema: cells must be exactly `h264_420f`, `hevc_420f`, `h264_420v`, `hevc_420v`; each cell must contain input pixel format, input patch values, encoder identifier, output format extensions, elementary-stream hash, ffprobe color fields, decoded patch values, slope/intercept/MAE, and clipping counts. Reject duplicate/missing cells and unknown range labels.

- [ ] **Step 2: Verify RED**

Run the focused unittest. Expected: failure because no native runner produces the required manifest.

- [ ] **Step 3: Generate semantic NV12 fixtures**

In `main.mm`, create 512×256 IOSurface-backed NV12 buffers. Full-range cells use the 14 `FULL_CODES`; video-range cells quantize the same semantic levels using `round(16 + full * 219 / 255)`. Fill neutral chroma at 128 and attach Rec.709 primaries, transfer, and matrix with `kCVAttachmentMode_ShouldPropagate`. Record actual center-patch Y values after filling.

- [ ] **Step 4: Encode with raw VideoToolbox**

For each cell create a hardware-required H.264 or HEVC `VTCompressionSession`, set RealTime true, frame reordering false, and a high fixed bitrate, then encode one IDR plus repeated static frames. Convert the length-prefixed sample to Annex-B with parameter sets from the output `CMFormatDescription`. Record actual encoder identifier and serialized format-description extensions.

- [ ] **Step 5: Decode and analyze without WebRTC**

The runner compiles `main.mm`, executes it, uses `ffprobe` to record `color_range`, `color_space`, `color_transfer`, and `color_primaries`, and uses FFmpeg software decode to raw NV12. Invoke `analyze-color-range-probe.py` to sample patch centers and write `report.json`. Preserve raw evidence only under the ignored evidence directory.

- [ ] **Step 6: Run the four cells and inspect the result**

Run:

```bash
./tools/run-macos-color-range-probe.sh
jq '.cells[] | {id, encoder_id, declared_range, mapping, slope, intercept, identity_mae, limited_to_full_mae}' evidence/macos-color-range/*/report.json
```

Expected: exactly four successful hardware cells. Determine whether the first HEVC divergence is already present in raw VT output. Do not change production code in this step.

- [ ] **Step 7: Commit the diagnostic milestone**

Run focused/full tests, `bash -n tools/run-macos-color-range-probe.sh`, and `git diff --check`. Commit source, runner, analyzer changes, and a sanitized aggregate finding:

```bash
git commit -m "feat: probe VideoToolbox color range boundaries"
```

### Task 4: Isolate the libwebrtc encoder boundary when required

**Files:**
- Modify: `<my-webrtc-builds>/tools/macos-videotoolbox-probe/main.mm`
- Modify: `<my-webrtc-builds>/tools/run-macos-videotoolbox-probe.sh`
- Modify: `<my-webrtc-builds>/tests/test_color_range_probe.py`

- [ ] **Step 1: Apply the raw-probe decision gate**

If raw VT HEVC already diverges, record the wrapper as not yet implicated and skip directly to Task 6's sender-contract candidate. If raw VT is correct, continue the remaining steps in this task.

- [ ] **Step 2: Add RED wrapper evidence tests**

Require the existing H.264/H.265 RTC encoder callbacks to save the first keyframe Annex-B stream and parameter-set SHA-256 for both `420f` and `420v`. Require decoded patch metrics to use the same analyzer schema as Task 3.

- [ ] **Step 3: Implement and run the wrapper comparison**

Reuse the semantic fixtures, encode through `RTCVideoEncoderH264` and `RTCVideoEncoderH265`, and compare VUI/parameter-set hashes and decoded patch values with raw VT output. The first changed boundary decides whether the builder H.265 patch is a repair target.

- [ ] **Step 4: Verify and commit**

Run the focused test, full builder tests, and hardware wrapper probe. Commit only if wrapper evidence was required:

```bash
git commit -m "feat: trace RTC encoder color range"
```

### Task 5: Isolate Android decoder core and texture rendering when required

**Files:**
- Create: `apps/android-tv/app/src/androidTest/java/cn/aweffr/webrtcscreencast/tv/media/ColorRangeProbeTest.java`
- Create: `apps/android-tv/app/src/androidTest/assets/color-range/manifest.json`
- Copy generated ignored fixtures at runtime; do not version raw streams unless privacy/hash review explicitly accepts them.

- [ ] **Step 1: Add a four-stream instrumentation contract**

The test loads the four hashed streams from Task 3/4, configures `MediaCodec` without WebRTC/network, records codec name and input/output color fields, and renders to a `SurfaceTexture`. A GLES framebuffer readback samples the same patch centers used on macOS. If YUV ByteBuffer output is supported, save its plane samples as additional evidence; do not fail solely because a hardware codec exposes Surface output only.

- [ ] **Step 2: Build and run on the existing emulator**

Run:

```bash
./apps/android-tv/gradlew -p apps/android-tv assembleDirectBaselineDebug assembleDirectBaselineDebugAndroidTest
adb shell am instrument -w -e class cn.aweffr.webrtcscreencast.tv.media.ColorRangeProbeTest cn.aweffr.webrtcscreencast.tv.test/androidx.test.runner.AndroidJUnitRunner
```

Expected: four direct-decode results, each with codec identity, output format, texture patch metrics, and stream SHA-256. Compare the first divergence with the macOS report. Do not use `AndroidMarkerProbe.toArgb()` as the measured renderer.

- [ ] **Step 3: Commit only durable probe code**

Run focused instrumentation build, both Android unit variants, lint, and `git diff --check`. Commit:

```bash
git commit -m "test(android): isolate codec color range rendering"
```

### Task 6: Implement the single evidence-selected repair with TDD

**Files for candidate A:**
- Modify: `apps/macos/WebRTCScreencast/Capture/ScreenSourceProvider.swift`
- Modify: `apps/macos/WebRTCScreencastTests/ScreenCaptureConfigurationTests.swift`
- Modify: `docs/superpowers/specs/2026-07-13-macos-webrtc-screencast-design.md`

**Files for candidate B/C:**
- Modify only the builder patch or Android render file proven by Tasks 3–5, plus its focused contract test.

- [ ] **Step 1: Write one RED production-contract test**

For candidate A, change the existing test to require `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` and assert the produced `SCStreamConfiguration` retains 1920×1080, 15 fps, queue depth 3, aspect fit, and native NV12. For candidate B or C, write the equivalent smallest test against the proven wrapper/VUI/dataspace boundary.

- [ ] **Step 2: Verify RED**

Run the single focused XCTest/builder test/instrumentation test. Expected: it fails for the old range contract.

- [ ] **Step 3: Implement only the selected repair**

Candidate A changes ScreenCaptureKit output to `420v` and updates the existing architecture statement from full-range to video-range. Candidate B normalizes only at the HEVC encoder boundary and records its conversion cost. Candidate C changes only the incorrect metadata or texture dataspace behavior proven by the probes. Do not combine candidates.

- [ ] **Step 4: Verify GREEN and commit**

Run focused tests, full affected-repository tests, and builds. Re-run the four-cell probes. Commit with the specific boundary, for example:

```bash
git commit -m "fix(macos): align capture video range across codecs"
```

### Task 7: Rebuild artifacts and run bounded product validation

**Files:**
- Modify: `artifacts/SHA256SUMS` only if a new builder artifact is required
- Modify: `docs/superpowers/plans/2026-07-18-hevc-color-range.md` execution findings
- Create: `docs/experiments/2026-07-18-hevc-color-range.md`

- [ ] **Step 1: Build and verify affected artifacts**

If builder code changed, apply the complete macOS and Android patch chains to every affected snapshot, build XCFramework/AAR, verify hashes, replace the ignored downstream artifacts, and remove downstream DerivedData/Vendor before rebuilding. If candidate A is app-only, retain the current verified WebRTC artifacts.

- [ ] **Step 2: Run full repository verification**

Run `make verify` in the downstream worktree and the full builder test suite if affected. Expected: all tests, lint, and builds pass.

- [ ] **Step 3: Run at most two short E2E cases**

Use the fixed local Kubernetes Chrome document and current content-aware MaxQP 24/32. Run one static H.264 A0 and one static HEVC A1, keeping three samples after STATIC is active. Do not scroll, repeat three times, run B0/B1, or enter feature stage.

- [ ] **Step 4: Inspect images personally**

Open every sender capture, Android decoded image, and actual `receiver-playing.png` with `view_image(detail=original)`. Check near-white background, pale-gray borders, 12/16 px text, low-saturation blue, and black surround. Record the visual judgment together with numeric slope/intercept, clipping, SSIM-Y, and PSNR-Y.

- [ ] **Step 5: Publish the result and commit**

Strip paths, usernames, device identifiers, network addresses, credentials, and extended metadata from versioned evidence. State explicitly whether all acceptance gates passed and whether the color/brightness issue is resolved. Commit:

```bash
git commit -m "docs(experiment): report HEVC color range result"
```

### Task 8: Independent review, merge, and cleanup

**Files:**
- Modify only files needed for accepted Critical/High review findings.

- [ ] **Step 1: Dispatch clean-context Code Review**

Provide the user requirement, design, this plan, execution findings, branch/worktree paths, commit list, diff, probe/E2E evidence, viewed-image notes, tests, and known limits. Restrict review to requirement alignment, Critical/High correctness/compatibility risks, and missing decisive validation.

- [ ] **Step 2: Address valuable findings**

Validate each finding against the real business path. Fix Critical/High issues and material validation gaps with focused tests; ignore style-only, speculative, or scope-expanding feedback. Re-run affected verification and return to the same reviewer, for at most three rounds.

- [ ] **Step 3: Merge safely to local main**

Confirm both worktrees are clean, merge conventional commits into each repository's local `main` serially, verify the merged state, then remove temporary worktrees and branches. Do not push unless separately requested.

## Execution Findings

- 2026-07-18: Downstream worktree created at `.worktrees/hevc-color-range` on `fix/hevc-color-range` from local main `24bfe11`. Initial `make verify` stopped only because ignored artifacts are not copied into a new worktree. After linking the already verified local artifacts, the full baseline passed: Go race tests, 128 macOS tests, Android unit/lint, script tests, macOS build, and both Android debug builds.
- 2026-07-18: Existing E2E evidence fits one limited-to-full expansion in HEVC but not H.264. Android reports FULL/BT.709/SDR for both outputs, so no production repair is authorized until Tasks 3–5 identify the first divergent boundary.
