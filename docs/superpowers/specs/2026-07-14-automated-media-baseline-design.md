# Automated Media Baseline Design

## Goal and naming

The next milestone establishes a repeatable automated media baseline on one Mac. It does not prioritize frame cadence tuning and does not claim optical glass-to-glass latency.

The baseline records three correlated measurements for the same visual marker:

1. **Marker Commit-to-Capture Latency**: marker commit until the Sender first detects it in a ScreenCaptureKit frame.
2. **Capture-to-Decode Latency**: Sender detection until the Receiver detects the same marker in a decoded frame.
3. **Software End-to-End Latency**: marker commit until Receiver decoded-frame detection. This is the primary automated latency metric.

None of these measurements includes Receiver Metal compositing or physical display scan-out.

## Deterministic source boundary

The automated latency and image-quality baseline uses only the app-created 1920×1080 virtual extended display. A deterministic measurement surface occupies that display so input pixels and marker transitions can be reproduced across runs.

Production-relay TURN/UDP is the primary result. Direct-baseline UDP is a comparison result. Main-display mirror remains covered by functional end-to-end verification but is excluded from numerical latency and image-quality comparisons because desktop contents, display scaling, notifications and window layout are not deterministic.

## Marker contract

The deterministic surface contains a high-contrast binary grid marker at a fixed region of interest. The marker encodes only a format version, sequence number and CRC. It does not encode wall-clock or monotonic timestamps.

The generator records each sequence and its monotonic commit time. The Sender and Receiver run the same pixel-buffer detector and record the first capture and decoded-frame observations of that sequence. Offline analysis joins those three records by sequence. A failed CRC is an invalid observation rather than a latency sample; QR, OCR and Vision-based detection are excluded so their variable asynchronous processing cost cannot be mistaken for media latency.

## Image evidence model

Each quality sample preserves three lossless 1920×1080 PNG images for the same marker sequence:

1. `source-reference.png`: the deterministic surface bitmap before presentation;
2. `sender-capture.png`: the corresponding ScreenCaptureKit pixel buffer;
3. `receiver-decoded.png`: the corresponding decoded Receiver frame.

Analysis reports Source-to-Capture, Capture-to-Decode and Source-to-Decode comparisons. This decomposition distinguishes capture/compositing and color-conversion changes from H.264 media degradation. The Receiver screenshot alone is not treated as sufficient evidence.

`receiver-decoded.png` is the canonical Receiver image evidence: it is extracted from the decoded 1920×1080 video frame at the same boundary as Decode Detect. The baseline does not capture the `RTCMTLNSVideoView`, Metal-composited application window or physical display output; those surfaces are size-, occlusion- and permission-dependent and belong to a different measurement boundary.

## Deterministic quality chart

The first baseline uses one static 1920×1080 SDR chart rather than a motion or video corpus. It contains the marker ROI; 12, 16, 24 and 32 px Chinese and Latin text; 1, 2 and 4 px horizontal and vertical lines; checkerboards; a grayscale ramp; fixed Rec.709 color patches; flat regions; and a smooth gradient. Only the marker sequence changes during sampling.

Image-quality analysis excludes the marker ROI. Fast scrolling, window dragging, video playback and other cadence-oriented content remain outside this milestone.

The capture contract remains identical to normal casting with `showsCursor=true`. Baseline mode does not hide, move or lock the pointer and does not request input-control permissions. The report records the cursor setting; no baseline-only capture behavior is introduced.

## Image-quality outputs

For Source-to-Capture, Capture-to-Decode and Source-to-Decode, analysis reports global and chart-region results for PSNR-Y, SSIM-Y and PSNR-Cb/Cr. It also preserves an amplified difference heatmap next to the three PNG inputs.

VMAF is included as a reference column for all three comparisons. The report records the FFmpeg/libvmaf versions and model identifier. A single static frame is outside VMAF's strongest use case, so VMAF is not a pass/fail gate and does not replace the luma, chroma or region-specific results. The implementation environment currently provides FFmpeg 7.1.4 with the `libvmaf` filter and Homebrew libvmaf 3.1.0.

## Standard run protocol

After the selected path is verified, each run warms up for 10 seconds and then samples for 60 seconds. The marker advances every 500 ms, yielding 120 target sequences. A latency sample is valid only when commit, capture detection and decode detection exist for the same CRC-valid sequence; missing or invalid observations remain explicit counters.

Each of Marker Commit-to-Capture, Capture-to-Decode and Software End-to-End latency reports sample count, valid ratio, p50, p95 and maximum. The run preserves matched image triplets near the beginning, middle and end of the measurement interval. Image-quality summaries report the median and worst sample while retaining the corresponding PNG evidence.

Production-relay and direct-baseline each run three times. The resulting target is 360 marker sequences and nine matched image triplets per profile. Production-relay remains the primary result; direct-baseline remains a comparison.

Runs alternate as three fresh Direct/TURN pairs: Direct 1, TURN 1, Direct 2, TURN 2, Direct 3, TURN 3. Every run creates new Sender and Receiver processes, PeerConnections, virtual display and marker sequence. Reports include both profile aggregates and paired-round differences so time-varying host or network conditions do not become an unexamined profile bias.

## Diagnostic export

Baseline PNGs, difference heatmaps, latency samples and analysis reports may be included directly in the existing diagnostic bundle. They use the existing manifest, checksum and configured-secret scan rather than a separate artifact/export system. Because the automated baseline is virtual-display-only and renders the deterministic chart, these artifacts do not introduce a separate main-display screenshot policy.

## Initial baseline policy

The first milestone is data collection, not threshold definition. Marker validity, latency distributions, image counts, PSNR, SSIM, VMAF and all analysis failures are reported as observed values; none is a hard performance or quality gate. Thresholds and regression budgets remain undecided until real baseline data exists.

## Runtime shape

The existing native app binary gains an explicit CLI-only media-baseline mode; no helper app target is added. The Sender owns the deterministic chart window on its newly created virtual display and probes ScreenCaptureKit frames. The Receiver probes the same decoded frames that are also attached to the existing Metal renderer. Marker generation and both detectors share one codec contract and remain within the normal casting-session lifecycle.

The existing dual-process automation is extended with a baseline runner. Frame evidence and timing events are written through the current session diagnostics. Offline analysis uses the installed FFmpeg filters, including libvmaf, and records exact tool versions. Engineering-only baseline controls do not appear in the product UI.

## Evidence retention

Raw PNGs, heatmaps, JSONL and diagnostic archives remain under the ignored `artifacts/media-baseline/<run-id>/` tree and may be exported as a diagnostic bundle. A small versioned `baselines/<date>-<git-commit>.json` preserves aggregate values, tool versions, effective configuration identity and source artifact checksums; a matching Markdown report presents the Direct and TURN/UDP comparison. These files record facts without defining thresholds.

## Verification entry points

`make verify` covers the marker codec and detector, image extraction, sequence correlation, percentile/report logic, build and the existing test suites. It does not access the public TURN service.

`make media-baseline` is the explicit environment-dependent workflow. It preflights Screen Recording, FFmpeg/libvmaf and runtime TURN configuration; launches the real signaling service and two app processes; runs both profiles three times; and produces the artifact tree plus aggregate reports. The six real runs are not hidden inside normal verification.

The command returns non-zero only when it cannot form a measurement: preflight failure, selected-path violation, absence of decoded H.264 frames, no correlatable marker, artifact/report failure or secret-scan rejection. High latency, low quality scores, a low marker-valid ratio or a large Direct-versus-TURN difference remain reportable data and never cause a performance/quality failure in this milestone.

## Timestamp semantics

Both app processes use the host monotonic clock. Marker commit time is captured at the source update boundary. Sender and Receiver callback-entry times are captured before marker detection or image conversion; when the detector identifies a sequence, it associates that already-captured timestamp with the observation. Detector and PNG-analysis cost therefore do not inflate the reported media latency.

## Host context

The runner records, but does not modify, Mac model and resources, macOS build, app commit/build, power source, Low Power Mode, thermal state, active network interface, Screen Recording authorization, tool versions and run start/end times. Low Power Mode or thermal pressure is report context rather than a blocker. The existing capture-lifecycle display-sleep assertion remains the only active host-state behavior.

## Baseline topology

Each run starts the local Go WebSocket signaling service. Direct media uses host UDP; production-relay media is forced through the existing public coturn relay over UDP. Measurement begins only after pairing, negotiation and selected-path verification. Public K3s signaling, TLS and ingress behavior are therefore outside the media baseline and cannot become an untracked difference between profiles.

## Connection timing

The report separates Receiver WebSocket connect, pairing-code issue, Sender WebSocket connect, Sender join-to-paired and total Receiver-connect-start-to-both-paired timing. Paired-to-PeerConnection-connected is reported separately as WebRTC negotiation time because it includes SDP, ICE and DTLS rather than only signaling transport and registry work.
