# Automated Media Baseline Implementation Plan

> **Execution:** Follow this plan task-by-task under the explicitly invoked `execute-long-horizon-task` workflow. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce and version a verified single-Mac Automated Media Baseline containing three fresh Direct UDP runs and three fresh forced TURN/UDP runs with marker-correlated latency, signaling timing and decoded-frame quality evidence.

**Architecture:** The existing native Sender creates one deterministic 1920×1080 virtual display and chart per run, while independent Sender and Receiver processes exchange H.264 through the existing local signaling server. The remaining execution work hardens `CGVirtualDisplay` removal, makes virtual-display cleanliness a runner invariant, then executes the already-implemented alternating six-run protocol and audits its raw and versioned artifacts.

**Tech Stack:** Swift 6, AppKit, ScreenCaptureKit, private `CGVirtualDisplay`, WebRTC M150, zsh, Python 3 standard library, FFmpeg/libvmaf, JSONL, jq.

**Design:** [`docs/superpowers/specs/2026-07-14-automated-media-baseline-design.md`](../specs/2026-07-14-automated-media-baseline-design.md)

---

## Current checkpoint

Commit `c3eadf6` implements the marker codec, chart, Sender/Receiver probes, three PNG boundaries, monotonic analysis, image metrics, alternating runner and aggregate report. `make verify` passes with 92 macOS tests and no failures. One earlier Direct run and one earlier forced TURN/UDP run proved real H.264 media and selected-path verification, but they predate the final callback-boundary and absolute-deadline corrections and therefore are reference evidence rather than the versioned main baseline.

The current host has three orphaned displays named `WebRTC Screencast Extended Display`. Chromium's current macOS virtual-display utility documents a first-removal workaround: create a companion display and release both display objects in the same removal operation. The baseline must implement that lifecycle and refuse to start or finish with an unexpected named display count before the six-run execution can be trusted.

### Task 1: Harden virtual-display removal

**Files:**
- Modify: `apps/macos/WebRTCScreencast/Capture/VirtualExtendedDisplayProvider.swift`
- Modify: `apps/macos/WebRTCScreencast/App/SessionCoordinator.swift`
- Modify: `apps/macos/WebRTCScreencastTests/VirtualDisplayConfigurationTests.swift`

- [ ] **Step 1: Add the removal-companion configuration contract test**

Extend `VirtualDisplayConfigurationTests` with a test that builds an owned-display descriptor and a removal-companion descriptor from `.extended1080p`. Assert the same 1920×1080 bounds, vendor/product identity and distinct serial numbers. Expose only an internal descriptor factory needed by the test; do not expose an owned `CGVirtualDisplay` outside the provider.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
(cd apps/macos && xcodegen generate)
xcodebuild test \
  -project apps/macos/WebRTCScreencast.xcodeproj \
  -scheme WebRTCScreencast \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData \
  -only-testing:WebRTCScreencastTests/VirtualDisplayConfigurationTests
```

Expected: the new test fails because the provider has no removal-companion descriptor factory.

- [ ] **Step 3: Implement paired first-removal**

Refactor display construction into a single private factory used by `start()` and `stop()`. In `stop()`, create and apply one temporary companion with a fresh serial number, retain the owned display and companion in one local collection, clear `self.display`, then clear the collection so both objects deallocate in the same operation. Wait until both display IDs are offline. If companion creation fails, release the owned display and still wait for its removal, returning `removalTimedOut` if it stays online.

The essential ownership sequence is:

```swift
var removalPair = [ownedDisplay]
if let companion = try? Self.makeDisplay(configuration: configuration, name: "WebRTC Screencast Removal Companion") {
    removalPair.append(companion)
}
self.display = nil
let removedIDs = removalPair.map(\.displayID)
removalPair.removeAll(keepingCapacity: false)
try await waitForDisplays(removedIDs, online: false, timeout: timeout)
```

- [ ] **Step 4: Record removal success only after it is proved**

In `SessionCoordinator`, replace the unconditional `try?` plus `virtual_display_removed` event with a `do/catch`. Record `virtual_display_removed` only after `stop()` succeeds; on failure set the coordinator to `.failed`, preserve that state through teardown, and record `virtual_display_removal_failed` with the stable error description rather than claiming cleanup.

- [ ] **Step 5: Run focused tests and build**

Run the focused test command from Step 2 and:

```bash
make build-macos
```

Expected: tests and arm64 build pass.

- [ ] **Step 6: Commit the lifecycle fix**

```bash
git add apps/macos/WebRTCScreencast/Capture/VirtualExtendedDisplayProvider.swift \
        apps/macos/WebRTCScreencast/App/SessionCoordinator.swift \
        apps/macos/WebRTCScreencastTests/VirtualDisplayConfigurationTests.swift \
        apps/macos/WebRTCScreencast.xcodeproj/project.pbxproj
git commit -m "fix(macos): remove virtual displays reliably"
```

### Task 2: Enforce clean display state in automation

**Files:**
- Create: `scripts/check-virtual-display-state.py`
- Create: `scripts/test_virtual_display_state.py`
- Modify: `scripts/run-media-baseline.sh`
- Modify: `Makefile`
- Modify: `docs/runbooks/local-development.md`

- [ ] **Step 1: Write fixture-driven checker tests**

Create tests that feed representative `system_profiler -json SPDisplaysDataType` objects into:

```python
count_named_displays(payload, "WebRTC Screencast Extended Display")
```

Cover zero, one and three matching `_name` values nested under `SPDisplaysDataType`. Assert that `main(["--expect", "0", "--input", fixture])` returns zero only for the zero-display fixture and reports the observed count otherwise.

- [ ] **Step 2: Verify RED**

Run:

```bash
python3 -m unittest scripts/test_virtual_display_state.py
```

Expected: import failure because `check-virtual-display-state.py` does not exist.

- [ ] **Step 3: Implement the checker**

The checker must use only the Python standard library. Without `--input`, execute:

```text
system_profiler -json SPDisplaysDataType
```

Recursively count objects whose `_name` exactly equals `WebRTC Screencast Extended Display`. Exit non-zero with an actionable message when the count differs from `--expect`; never create, remove, wake or reconfigure a display.

- [ ] **Step 4: Gate each run before and after execution**

In `run-media-baseline.sh`, require zero named displays before the first run and after every `run-dual-client.sh` invocation. A mismatch must stop the workflow before the next profile and retain the failed run's diagnostics. This preserves the design rule that every run owns a fresh virtual display and prevents a single lifecycle failure from contaminating later rounds.

- [ ] **Step 5: Add tests and runbook guidance**

Add `python3 -m unittest scripts/test_virtual_display_state.py` to `make test-scripts`. Document that a pre-existing orphan requires one user-session reset (log out/in or reboot) because a new process cannot release an orphaned `CGVirtualDisplay` object it does not own. The runner itself must continue to record rather than modify host power/display state.

- [ ] **Step 6: Verify and commit**

Run:

```bash
python3 -m unittest scripts/test_virtual_display_state.py
zsh -n scripts/run-media-baseline.sh
make test-scripts
git diff --check
```

Then commit:

```bash
git add scripts/check-virtual-display-state.py scripts/test_virtual_display_state.py \
        scripts/run-media-baseline.sh Makefile docs/runbooks/local-development.md
git commit -m "test(macos): guard media baseline display lifecycle"
```

### Task 3: Prove one corrected Direct/TURN pair

**Files:**
- Update generated evidence under ignored `artifacts/media-baseline/`
- Append execution findings to `docs/superpowers/specs/2026-07-14-automated-media-baseline-design.md` only if runtime evidence changes an existing design assumption

- [ ] **Step 1: Establish a clean external state**

Run:

```bash
./scripts/check-virtual-display-state.py --expect 0
system_profiler SPDisplaysDataType | grep -A12 'Color LCD'
```

Expected: zero named virtual displays and `Display Asleep: No`. If either condition is false, stop without modifying host state and request the minimum external action: log out/in or reboot to clear orphaned displays, then wake/unlock the Mac.

- [ ] **Step 2: Build the normal Debug app after tests**

Run:

```bash
make build-macos
```

Expected: `BUILD SUCCEEDED`. Do not launch the XCTest host bundle for E2E.

- [ ] **Step 3: Run one corrected Direct session**

Run:

```bash
./scripts/run-dual-client.sh \
  --profile direct-baseline \
  --source virtual \
  --run-seconds 90 \
  --output-root artifacts/media-baseline/corrected-direct \
  --media-baseline \
  --skip-build
```

Analyze its emitted run directory with `scripts/analyze-media-baseline.py`. Expected: H.264 and direct selected-path verification pass; the actual post-path measurement window contains correlatable markers; three complete image triplets exist; the display-state checker returns zero afterward.

- [ ] **Step 4: Run one corrected forced TURN/UDP session**

Run the same command with `--profile production-relay --runtime-config secrets/runtime.json` and output root `artifacts/media-baseline/corrected-turn`. Expected: relay/UDP selected path, decoded H.264, marker correlation, three image triplets and zero remaining named displays.

- [ ] **Step 5: Audit measurement boundaries**

For both reports, verify:

```bash
jq '{measurement_window,marker_counters,latency_summary,connection_timing}' media-baseline-report.json
```

The commit times included by the analyzer must lie in `[selected_path_verified + 10s, selected_path_verified + 70s)`. Confirm Sender callback timestamps originate at `ScreenCaptureSource.stream(_:didOutputSampleBuffer:)` entry and the Sender submits the frame to libwebrtc before marker detection or PNG copying.

### Task 4: Execute and version the six-run main baseline

**Files:**
- Generate ignored raw evidence under `artifacts/media-baseline/`
- Generate one commit-identified JSON file under `baselines/`
- Generate one matching Markdown file under `baselines/`

- [ ] **Step 1: Confirm a clean commit and environment**

Run:

```bash
git status --porcelain
./scripts/check-virtual-display-state.py --expect 0
jq -e '.turn.url | startswith("turn:") and contains("transport=udp")' secrets/runtime.json
```

Expected: clean worktree, zero named virtual displays and a valid ignored TURN/UDP runtime config.

- [ ] **Step 2: Run the complete alternating protocol**

Run:

```bash
RUNTIME_CONFIG="$PWD/secrets/runtime.json" make media-baseline
```

Expected order: Direct 1, TURN 1, Direct 2, TURN 2, Direct 3, TURN 3. Each run creates fresh processes, PeerConnections and virtual display, then proves display cleanup before the next run.

- [ ] **Step 3: Audit raw evidence and aggregate structure**

Verify six reports, 720 target marker commits, 18 source/capture/decode triplets and both profiles:

```bash
artifact_root="$(find artifacts/media-baseline -mindepth 1 -maxdepth 1 -type d -print | sort | tail -1)"
find "$artifact_root" -name media-baseline-report.json | wc -l
find "$artifact_root" -name 'source-reference-*.png' | wc -l
find "$artifact_root" -name 'sender-capture-*.png' | wc -l
find "$artifact_root" -name 'receiver-decoded-*.png' | wc -l
jq '.profiles | keys' "$artifact_root/baseline.json"
jq '.paired_round_deltas | length' "$artifact_root/baseline.json"
```

Expected: `6`, `18`, `18`, `18`, both `direct-baseline` and `production-relay`, and `3` paired deltas. Confirm `artifact_root` equals the exact output directory printed by the runner before accepting the counts.

- [ ] **Step 4: Audit security and checksums**

Confirm no retained runtime config or configured TURN credential appears in the artifact or versioned reports. Recompute every `artifact_checksums` entry and require an exact SHA-256 match. Confirm the checksum keys include all six reports, all twelve metrics JSONL files, all 54 triplet PNGs, heatmaps, VMAF JSON and host context.

- [ ] **Step 5: Inspect representative image evidence**

Open the beginning, middle and end Receiver PNG for one Direct and one TURN run. Confirm the 1920×1080 marker, Chinese/Latin text, horizontal/vertical fine lines, colors and checkerboard are present and aligned with their source/capture images. Treat visual inspection as evidence alongside, not a replacement for, PSNR/SSIM/VMAF.

- [ ] **Step 6: Run final verification**

Run:

```bash
make verify
git diff --check
```

Expected: Go race tests, all macOS tests, Python/script tests and arm64 build pass.

### Task 5: Final review, commit and completion audit

**Files:**
- Commit: the generated commit-identified JSON file under `baselines/`
- Commit: the generated matching Markdown file under `baselines/`
- Update: design or plan execution findings only when required by observed facts

- [ ] **Step 1: Request a clean-context code and evidence review**

Provide the reviewer the original requirements, design, this plan, lifecycle commits, six-run command output, aggregate reports, security audit and known private-API risk. Limit findings to Critical/High requirement, correctness, security, lifecycle or evidence gaps.

- [ ] **Step 2: Fix mandatory findings and rerun affected verification**

Use at most three review/fix rounds. Do not expand into cadence tuning, input control, TURN/TCP or `EnableLowLatencyRateControl`.

- [ ] **Step 3: Commit the versioned baseline**

After confirming it contains no secrets or absolute sensitive paths:

```bash
baseline_json="$(find baselines -maxdepth 1 -type f -name '*.json' -print | sort | tail -1)"
baseline_md="${baseline_json%.json}.md"
git add "$baseline_json" "$baseline_md"
git commit -m "docs: record automated media baseline"
```

- [ ] **Step 4: Prove completion**

Completion requires all of the following evidence at once: clean worktree; lifecycle checker zero before and after runs; six real selected-path-verified H.264 sessions; 360 target sequences and nine triplets per profile; complete Direct/TURN aggregates and three paired deltas; exact checksums; no credential retention; final `make verify` pass; no unresolved Critical/High review finding.
