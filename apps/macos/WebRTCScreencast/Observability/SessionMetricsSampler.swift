import Foundation

actor SessionMetricsSampler {
    private let session: WebRTCSession
    private let captureSource: ScreenCaptureSource?
    private let recorder: MetricsRecorder
    private var normalizer: RTCStatsNormalizer
    private var task: Task<Void, Never>?

    init(
        session: WebRTCSession,
        captureSource: ScreenCaptureSource?,
        recorder: MetricsRecorder,
        profile: ICEProfile
    ) {
        self.session = session
        self.captureSource = captureSource
        self.recorder = recorder
        normalizer = RTCStatsNormalizer(profile: profile)
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() async {
        task?.cancel()
        await task?.value
        task = nil
        try? await recorder.synchronize()
    }

    private func run() async {
        while !Task.isCancelled {
            let batch = await session.collectStatistics()
            let sample = normalizer.normalize(
                timestampUs: batch.timestampUs,
                statistics: batch.statistics
            )
            var fields = Self.fields(from: sample)
            if let captureSource {
                fields["capture"] = .object(Self.fields(from: captureSource.telemetrySnapshot()))
            }
            fields["render"] = .object(Self.fields(from: session.metricsRenderer.snapshot()))
            try? await recorder.record(event: "rtc_stats", fields: fields)
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }

    private static func fields(from sample: NormalizedRTCStatsSample) -> [String: JSONValue] {
        var result: [String: JSONValue] = [
            "timestamp_us": .integer(Int(sample.timestampUs)),
            "selected_path": .object([
                "status": .string(sample.selectedPath.status.rawValue),
                "pair_id": sample.selectedPath.selectedPairID.map(JSONValue.string) ?? .null,
                "local_candidate_type": sample.selectedPath.localCandidateType.map(JSONValue.string) ?? .null,
                "remote_candidate_type": sample.selectedPath.remoteCandidateType.map(JSONValue.string) ?? .null,
                "protocol": sample.selectedPath.protocolValue.map(JSONValue.string) ?? .null,
            ]),
        ]
        if let outbound = sample.outbound { result["outbound_video"] = .object(fields(from: outbound)) }
        if let remote = sample.remoteInbound {
            result["remote_inbound_video"] = .object([
                "rtt_ms": remote.roundTripTimeMs.map(JSONValue.number) ?? .null,
                "packets_lost": remote.packetsLost.map { .integer(Int($0)) } ?? .null,
            ])
        }
        if let inbound = sample.inbound { result["inbound_video"] = .object(fields(from: inbound)) }
        return result
    }

    private static func fields(from stats: NormalizedVideoRTPStats) -> [String: JSONValue] {
        [
            "id": .string(stats.id),
            "bytes": stats.bytes.map { .integer(Int($0)) } ?? .null,
            "frames": stats.frames.map { .integer(Int($0)) } ?? .null,
            "frames_dropped": stats.framesDropped.map { .integer(Int($0)) } ?? .null,
            "bitrate_bps": stats.bitrateBps.map(JSONValue.number) ?? .null,
            "fps": stats.framesPerSecond.map(JSONValue.number) ?? .null,
            "average_qp": stats.averageQP.map(JSONValue.number) ?? .null,
            "codec": stats.codecMimeType.map(JSONValue.string) ?? .null,
            "encoder": stats.implementation.map(JSONValue.string) ?? .null,
            "decoder": stats.decoderImplementation.map(JSONValue.string) ?? .null,
        ]
    }

    private static func fields(from stats: CaptureTelemetrySnapshot) -> [String: JSONValue] {
        [
            "callback_frames": .integer(Int(stats.callbackFrames)),
            "submitted_frames": .integer(Int(stats.submittedFrames)),
            "dropped_frames": .integer(Int(stats.droppedFrames)),
            "last_timestamp_ns": stats.lastTimestampNs.map { .integer(Int($0)) } ?? .null,
            "dirty_rect_count": stats.lastDirtyRectCount.map(JSONValue.integer) ?? .null,
            "dirty_ratio": stats.lastDirtyRatio.map(JSONValue.number) ?? .null,
            "frame_gate_state": .string(stats.gateState.rawValue),
        ]
    }

    private static func fields(from stats: VideoRenderSnapshot) -> [String: JSONValue] {
        [
            "frames_rendered": .integer(Int(stats.framesRendered)),
            "last_timestamp_ns": stats.lastFrameTimestampNs.map { .integer(Int($0)) } ?? .null,
            "width": stats.width.map { .integer(Int($0)) } ?? .null,
            "height": stats.height.map { .integer(Int($0)) } ?? .null,
        ]
    }
}
