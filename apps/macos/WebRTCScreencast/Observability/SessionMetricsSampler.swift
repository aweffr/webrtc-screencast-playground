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
            fields["sender_media_boundary"] = .object(Self.fields(from: session.senderMediaBoundarySnapshot()))
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
            "key_frames": stats.keyFrames.map { .integer(Int($0)) } ?? .null,
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
            "visual_stability_mode": .string(stats.visualStabilityMode.rawValue),
            "visual_changed_sample_ratio": stats.lastVisualChangedSampleRatio.map(JSONValue.number) ?? .null,
            "clarity_refresh_requests": .integer(Int(stats.clarityRefreshRequests)),
        ]
    }

    private static func fields(from stats: SenderMediaBoundarySnapshot) -> [String: JSONValue] {
        [
            "source_frames_forwarded": .integer(Int(stats.sourceFramesForwarded)),
            "source_pixel_format": stats.sourcePixelFormat.map { .integer(Int($0)) } ?? .null,
            "cast_tuning_session_id": stats.castTuningSessionID.map(JSONValue.string) ?? .null,
            "cast_tuning_config_hash": stats.castTuningConfigHash.map(JSONValue.string) ?? .null,
            "encoder_session_id": stats.encoderSessionID.map(JSONValue.string) ?? .null,
            "video_toolbox_encoder_id": stats.videoToolboxEncoderID.map(JSONValue.string) ?? .null,
            "expected_h264_profile": stats.expectedH264Profile.map(JSONValue.string) ?? .null,
            "actual_h264_profile": stats.actualH264Profile.map(JSONValue.string) ?? .null,
            "profile_mismatch": stats.profileMismatch.map(JSONValue.bool) ?? .null,
            "encoder_session_id": stats.encoderSessionId.map(JSONValue.string) ?? .null,
            "requested_max_qp": stats.requestedMaxQp.map(JSONValue.integer) ?? .null,
            "effective_max_qp": stats.effectiveMaxQp.map(JSONValue.integer) ?? .null,
            "max_qp_apply_state": stats.maxQpApplyState.map(JSONValue.string) ?? .null,
            "max_qp_generation": stats.maxQpGeneration.map { .integer(Int($0)) } ?? .null,
            "max_qp_os_status": stats.maxQpOSStatus.map(JSONValue.integer) ?? .null,
            "last_encoded_qp": stats.lastEncodedQp.map(JSONValue.integer) ?? .null,
            "last_key_frame_qp": stats.lastKeyFrameQp.map(JSONValue.integer) ?? .null,
            "last_key_frame_bytes": stats.lastKeyFrameBytes.map(JSONValue.integer) ?? .null,
            "clarity_mode": .string(stats.clarityMode.rawValue),
            "clarity_successful_refreshes": .integer(Int(stats.claritySuccessfulRefreshes)),
            "clarity_failed_refreshes": .integer(Int(stats.clarityFailedRefreshes)),
            "clarity_motion_restores": .integer(Int(stats.clarityMotionRestores)),
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
