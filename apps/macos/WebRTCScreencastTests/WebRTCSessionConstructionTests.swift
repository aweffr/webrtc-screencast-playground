import Foundation
import XCTest
@preconcurrency import WebRTC
@testable import WebRTCScreencast

final class WebRTCSessionConstructionTests: XCTestCase {
    func testH264PolicyPreservesDefaultPacketizationModeOneCapabilities() {
        let expectedEncoderParameters = RTCDefaultVideoEncoderFactory().supportedCodecs()
            .filter {
                $0.name.caseInsensitiveCompare("H264") == .orderedSame
                    && $0.parameters["packetization-mode"] == "1"
            }
            .map(\.parameters)
        let expectedDecoderParameters = RTCDefaultVideoDecoderFactory().supportedCodecs()
            .filter {
                $0.name.caseInsensitiveCompare("H264") == .orderedSame
                    && $0.parameters["packetization-mode"] == "1"
            }
            .map(\.parameters)

        XCTAssertEqual(
            SelectedVideoEncoderFactory(policy: .h264Only).supportedCodecs().map(\.parameters),
            expectedEncoderParameters
        )
        XCTAssertEqual(
            SelectedVideoDecoderFactory(policy: .h264Only).supportedCodecs().map(\.parameters),
            expectedDecoderParameters
        )
    }

    func testExplicitH264ProfileOverrideAdvertisesSingleReferenceCapability() {
        for codecs in [
            SelectedVideoEncoderFactory(
                policy: .h264Only,
                h264ProfileLevelIDOverride: "42e029"
            ).supportedCodecs(),
            SelectedVideoDecoderFactory(
                policy: .h264Only,
                h264ProfileLevelIDOverride: "42e029"
            ).supportedCodecs(),
        ] {
            XCTAssertEqual(codecs.count, 1)
            XCTAssertEqual(codecs[0].parameters["packetization-mode"], "1")
            XCTAssertEqual(codecs[0].parameters["profile-level-id"], "42e029")
        }
    }

    func testContentAwarePolicyOmitsMaxQpOnlyForRTVC() {
        let ordinary = SenderContentAwarePolicy(
            jsonData: Data(#"{"sender":{"max_fps":15,"max_bitrate_bps":5000000},"encoder":{"max_qp":39,"video_toolbox_low_latency_rate_control":false}}"#.utf8),
            staticMaxQp: 30
        )
        XCTAssertEqual(ordinary.motionMaxQp, 39)
        XCTAssertEqual(ordinary.staticMaxQp, 30)

        let rtvc = SenderContentAwarePolicy(
            jsonData: Data(#"{"sender":{"max_fps":15,"max_bitrate_bps":5000000},"encoder":{"video_toolbox_low_latency_rate_control":true}}"#.utf8),
            staticMaxQp: 30
        )
        XCTAssertNil(rtvc.motionMaxQp)
        XCTAssertNil(rtvc.staticMaxQp)
        XCTAssertEqual(rtvc.maxFPS, 15)
        XCTAssertEqual(rtvc.maxBitrateBps, 5_000_000)
    }

    func testSenderAndReceiverFactoriesAcceptCastTuningAndH265Policy() throws {
        let tuningData = try Data(contentsOf: repositoryRoot().appending(path: "config/cast-tuning.default.json"))
        let ice = try IceServerProvider.make(profile: .directBaseline, turn: nil)

        let sender = try WebRTCSession(
            role: .sender,
            ice: ice,
            castTuningJSON: tuningData,
            videoCodecPolicy: .h265Only
        )
        let receiver = try WebRTCSession(role: .receiver, ice: ice, castTuningJSON: tuningData)

        XCTAssertEqual(sender.role, .sender)
        XCTAssertEqual(receiver.role, .receiver)
        sender.close()
        receiver.close()
    }

    func testDeinitPerformsSafeTeardownWithoutExplicitClose() throws {
        let tuningData = try Data(contentsOf: repositoryRoot().appending(path: "config/cast-tuning.default.json"))
        let ice = try IceServerProvider.make(profile: .directBaseline, turn: nil)

        _ = try WebRTCSession(role: .sender, ice: ice, castTuningJSON: tuningData)
    }

    func testSenderOfferAdvertisesOnlyH265Video() async throws {
        let tuningData = try Data(contentsOf: repositoryRoot().appending(path: "config/cast-tuning.default.json"))
        let ice = try IceServerProvider.make(profile: .directBaseline, turn: nil)
        let sender = try WebRTCSession(
            role: .sender,
            ice: ice,
            castTuningJSON: tuningData,
            videoCodecPolicy: .h265Only
        )
        defer { sender.close() }

        let offer = try await sender.createOffer()
        XCTAssertTrue(offer.localizedCaseInsensitiveContains(" H265/90000"), "offer: \(offer)")
        XCTAssertFalse(offer.contains(" H264/90000"))
        XCTAssertFalse(offer.contains(" VP8/90000"))
        XCTAssertFalse(offer.contains(" VP9/90000"))
        XCTAssertFalse(offer.contains(" AV1/90000"))
    }

    func testH264ReferenceOfferUsesConstrainedBaselineLevel41() async throws {
        let tuningData = Data(#"{"schema_version":3,"profile":"DETAIL_ACTIVE","encoder":{"h264_profile":"CONSTRAINED_BASELINE","h264_level":"4.1"}}"#.utf8)
        let ice = try IceServerProvider.make(profile: .directBaseline, turn: nil)
        let sender = try WebRTCSession(
            role: .sender,
            ice: ice,
            castTuningJSON: tuningData,
            videoCodecPolicy: .h264Only
        )
        defer { sender.close() }

        let offer = try await sender.createOffer()

        XCTAssertTrue(offer.localizedCaseInsensitiveContains(" H264/90000"))
        XCTAssertTrue(
            offer.localizedCaseInsensitiveContains("profile-level-id=42e029"),
            "offer profile-level-id values: \(offer.components(separatedBy: "profile-level-id=").dropFirst().map { String($0.prefix(6)) })"
        )
        XCTAssertFalse(offer.localizedCaseInsensitiveContains(" H265/90000"))
    }

    func testSenderCodecPreferencePoliciesAffectOfferOrder() async throws {
        let tuningData = try Data(contentsOf: repositoryRoot().appending(path: "config/cast-tuning.default.json"))
        let ice = try IceServerProvider.make(profile: .directBaseline, turn: nil)

        for (policy, first, second) in [
            (VideoCodecPolicy.preferH265, "H265/90000", "H264/90000"),
            (VideoCodecPolicy.default, "H264/90000", "H265/90000"),
        ] {
            let sender = try WebRTCSession(
                role: .sender,
                ice: ice,
                castTuningJSON: tuningData,
                videoCodecPolicy: policy
            )
            let offer = try await sender.createOffer()
            sender.close()

            let firstRange = try XCTUnwrap(offer.range(of: first, options: .caseInsensitive))
            let secondRange = try XCTUnwrap(offer.range(of: second, options: .caseInsensitive))
            XCTAssertLessThan(firstRange.lowerBound, secondRange.lowerBound)
        }
    }

    func testDiagnosticsDoNotCreateRawLibWebRTCLogs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tuningData = try Data(contentsOf: repositoryRoot().appending(path: "config/cast-tuning.default.json"))
        let ice = try IceServerProvider.make(profile: .directBaseline, turn: nil)
        let session = try WebRTCSession(role: .sender, ice: ice, castTuningJSON: tuningData)
        defer { session.close() }

        try session.startDiagnostics(in: directory)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains("rtc-event.log"))
        XCTAssertFalse(names.contains { $0.hasPrefix("webrtc_log") })
    }

    func testSenderBoundaryMetricsPreserveEncoderBindingAndDistributions() {
        let snapshot = senderBoundarySnapshot(
            videoToolboxSubmittedFrames: 120,
            videoToolboxEncodedFrames: 118,
            videoToolboxDroppedFrames: 2,
            keyFrameQpHistogram: (0..<52).map(UInt64.init),
            deltaFrameQpHistogram: (0..<52).map { UInt64(51 - $0) }
        )

        let fields = SessionMetricsSampler.fields(from: snapshot)

        XCTAssertEqual(fields["encoder_session_id"], .string("vt-1"))
        XCTAssertEqual(fields["requested_max_qp"], .integer(24))
        XCTAssertEqual(fields["last_key_frame_qp"], .integer(24))
        XCTAssertEqual(fields["max_qp_applied_encoder_session_id"], .string("vt-2"))
        XCTAssertEqual(fields["last_qp_sample_generation"], .integer(2))
        XCTAssertEqual(fields["last_qp_sample_encoder_session_id"], .string("vt-2"))
        XCTAssertEqual(fields["video_toolbox_submitted_frames"], .integer(120))
        XCTAssertEqual(fields["video_toolbox_encoded_frames"], .integer(118))
        XCTAssertEqual(fields["video_toolbox_dropped_frames"], .integer(2))
        XCTAssertEqual(
            fields["key_frame_qp_histogram"],
            .array((0..<52).map { .integer($0) })
        )
        XCTAssertEqual(
            fields["delta_frame_qp_histogram"],
            .array((0..<52).map { .integer(51 - $0) })
        )

        let unavailable = SessionMetricsSampler.fields(from: senderBoundarySnapshot())
        XCTAssertEqual(unavailable["video_toolbox_submitted_frames"], .null)
        XCTAssertEqual(unavailable["key_frame_qp_histogram"], .null)
    }

    private func senderBoundarySnapshot(
        videoToolboxSubmittedFrames: UInt64? = nil,
        videoToolboxEncodedFrames: UInt64? = nil,
        videoToolboxDroppedFrames: UInt64? = nil,
        keyFrameQpHistogram: [UInt64]? = nil,
        deltaFrameQpHistogram: [UInt64]? = nil
    ) -> SenderMediaBoundarySnapshot {
        SenderMediaBoundarySnapshot(
            sourceFramesForwarded: 1,
            sourcePixelFormat: nil,
            castTuningSessionID: "cast-1",
            castTuningConfigHash: "hash-1",
            encoderSessionID: "vt-1",
            videoToolboxEncoderID: "encoder-1",
            expectedH264Profile: "BASELINE",
            actualH264Profile: "BASELINE",
            profileMismatch: false,
            requestedMaxQp: 24,
            effectiveMaxQp: 24,
            maxQpApplyState: "applied",
            maxQpGeneration: 2,
            maxQpOSStatus: 0,
            maxQpAppliedEncoderSessionID: "vt-2",
            lastEncodedQp: 24,
            lastKeyFrameQp: 24,
            lastKeyFrameBytes: 12_345,
            lastQpSampleGeneration: 2,
            lastQpSampleEncoderSessionID: "vt-2",
            videoToolboxSubmittedFrames: videoToolboxSubmittedFrames,
            videoToolboxEncodedFrames: videoToolboxEncodedFrames,
            videoToolboxDroppedFrames: videoToolboxDroppedFrames,
            keyFrameQpHistogram: keyFrameQpHistogram,
            deltaFrameQpHistogram: deltaFrameQpHistogram,
            clarityMode: .staticClarity,
            claritySuccessfulRefreshes: 1,
            clarityFailedRefreshes: 0,
            clarityMotionRestores: 0
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
