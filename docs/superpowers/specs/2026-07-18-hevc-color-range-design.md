# HEVC Color Range Consistency Design

## Context

The 2026-07-18 meeting-cast experiment showed a codec-specific brightness failure before HEVC could be considered for production preference. With aligned STATIC/ACTIVE MaxQP 24/32, H.264 reached worst-case SSIM-Y/PSNR-Y 0.9981/40.77 dB while HEVC reached 0.9758/35.54 dB. All three HEVC cases produced brighter whites and weaker pale-gray borders, independent of their MaxQP choices.

Pixel analysis makes the failure more specific: the HEVC Android result closely matches one numerical limited-to-full expansion, `clip((x - 16) * 255 / 219)`, while H.264 remains close to identity. The same mapping is visible in the actual `SurfaceViewRenderer` screenshot, so it is not only an evidence-export conversion bug. Android nevertheless reports FULL/BT.709/SDR for both codec outputs, and the H.264 and HEVC runs use different MediaCodec implementations. Existing end-to-end evidence therefore proves the symptom but not the first faulty boundary.

The business objective is low-latency, high-clarity meeting casting. This work restores an invariant required by that objective: the same SDR Rec.709 source must retain near-black, near-white, pale-gray, text, and low-saturation color relationships through either H.264 or HEVC. It does not expand the codec experiment matrix.

## Scope

This design covers the macOS Swift sender, Apple VideoToolbox encoding, the patched libwebrtc H.265 wrapper, Android MediaCodec decoding, and the production texture render path for 8-bit SDR Rec.709.

It excludes HDR, Display P3, P010/10-bit, television HDMI black-level settings, MaxQP tuning, Spatial AQ, frame reordering, low-latency rate control, content-state detection, and general renderer redesign. The content-aware MaxQP policy remains enabled during final A0/A1 validation, but it is not modified here.

## Media Contract

Range is a numeric pixel contract, not merely metadata:

- `420f` represents full-range NV12.
- `420v` represents video-range NV12.
- Primaries, transfer function, and YCbCr matrix describe color interpretation but do not compensate for incorrect range quantization.
- Pixel values, CoreVideo attachments, VideoToolbox format descriptions, HEVC/H.264 VUI, Android output format, and rendered output must agree.

For a fixed semantic fixture, decoded H.264 and HEVC grayscale mappings must differ by no more than 0.01 slope and two code values of intercept. Final Android renderer output relative to sender must have slope 0.98–1.02 and intercept within ±3 code values, without additional near-black or near-white clipping.

## Architecture

### 1. Native VideoToolbox boundary probe

Extend the existing builder-side macOS probe with a color-range mode that bypasses Chrome, WebRTC signaling, TURN, and Android. It generates semantically equivalent full-range and video-range NV12 charts, records the actual input plane values and propagated attachments, and encodes four fixed cells:

- H.264 + `420f`
- H.265 + `420f`
- H.264 + `420v`
- H.265 + `420v`

The probe writes short elementary streams, output format-description extensions, and parsed H.264/HEVC VUI. FFmpeg software decode provides the first codec-independent decoded-plane comparison. VideoToolbox local decode is a secondary hardware comparison. The base matrix is fixed at four cells; at most two explicit Rec.709 attachment cells may be added only if range is correct but a reproducible chroma residual remains.

### 2. libwebrtc wrapper boundary probe

The existing `RTCVideoEncoderH264`/`RTCVideoEncoderH265` probe uses the same fixture. It compares parameter sets and decoded values with raw VideoToolbox output. If raw VT output already contains the expansion, packetization is exonerated. Only if raw VT is correct and RTC output changes the contract may the H.265 wrapper be modified.

### 3. Android decode/render boundary probe

Android consumes the four hashed elementary streams directly, without WebRTC or network setup. The probe records decoder identity, input/output `MediaFormat`, Codec2 range/dataspace logs, and production-equivalent SurfaceTexture/GLES output. ByteBuffer/YUV output is collected only when the selected codec exposes it; its absence is not replaced by the existing `AndroidMarkerProbe.toArgb()` conversion.

This separates encoded values, decoder-core output, and GPU/dataspace rendering. Emulator results are sufficient to reproduce the existing experiment environment. If a target physical Android TV is available, it repeats the same four decodes rather than a full casting run.

### 4. Evidence-selected repair

Exactly one repair layer is selected:

1. **Capture-wide `420v` with explicit Rec.709 — preferred when proven.** ScreenCaptureKit directly emits video-range NV12, preserving the zero-copy native buffer path and giving both codecs the same compressed-video contract. H.264 must remain within its reference gate.
2. **HEVC encoder-boundary full-to-video normalization.** Used only if capture-wide `420v` regresses H.264 or cannot preserve the capture contract. It has a copy/latency cost that must be measured.
3. **VUI or Android render correction.** Used only when decoded code values are correct and the probe proves that metadata or SurfaceTexture dataspace handling is the first faulty boundary.

Codec-name-based inverse LUTs and double-negative metadata workarounds are rejected. They bind behavior to a decoder implementation and can create a second conversion on unaffected devices.

## Data and Evidence

The machine-readable report contains:

- codec, pixel format, dimensions, encoder identifier, OS version;
- input Y/UV patch values and propagated attachments;
- output `CMFormatDescription` range/primaries/transfer/matrix;
- parameter-set hashes and parsed VUI fields;
- decoded patch medians, clipping counts, slope, intercept, MAE, and maximum error;
- artifact hashes and exact probe command.

Generated raw streams, logs, device identifiers, and machine paths remain in ignored evidence directories. Versioned reports contain sanitized aggregate results and hashes only.

## Failure Handling and Stop Rules

Probe infrastructure errors are explicit and may be retried once per layer. A behavioral failure is not retried away. The first boundary where numeric values or metadata diverge becomes the only repair target; speculative downstream combinations stop.

Limits:

- four macOS base cells, with at most two conditional Rec.709 cells;
- four Android direct-decode samples;
- one repair approach;
- two final short E2E runs: aligned H.264 A0 and HEVC A1;
- no B0/B1 or feature-stage experiment in this task.

## Testing and Acceptance

Parser, fixture quantization, numeric comparison, capture configuration, and report contracts use behavior-focused TDD. Probe compilation, patch application, framework/AAR builds, and generated evidence use their domain validation rather than tests that assert file text.

After the repair, both repositories must pass their focused tests and normal build verification. Final E2E uses the existing fixed Kubernetes Chrome document at a fixed initial position. Each codec remains static long enough to enter the existing STATIC policy and saves three samples. The executor personally views original-resolution sender, decoded, and actual renderer images.

Acceptance requires:

- renderer-to-sender slope 0.98–1.02 and intercept within ±3;
- no additional near-black/near-white clipping versus H.264 reference;
- HEVC worst static SSIM-Y no more than 0.002 below H.264 and PSNR-Y no more than 0.5 dB below it;
- bitstream, decoder output, and renderer metadata consistent with the selected range contract;
- no per-frame CPU conversion; if an encoder-boundary conversion is unavoidable, no business-visible encode-latency, VideoToolbox-drop, or capture-queue regression.

Passing these gates resolves only the color/brightness follow-up. HEVC production preference remains blocked until the separately documented static-aware stability and content-bound latency follow-ups pass.

## Design Approval

The user reviewed the bounded diagnostic plan in the preceding conversation, explicitly requested micro-probes before end-to-end testing, and then invoked long-horizon execution of that plan in an isolated worktree. That execution request is the approval for this written design; no additional scope was introduced while converting it into this specification.
