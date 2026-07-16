import Foundation
import XCTest
@testable import WebRTCScreencast

final class WebRTCSessionConstructionTests: XCTestCase {
    func testSenderAndReceiverFactoriesAcceptCastTuningAndH264Policy() throws {
        let tuningData = try Data(contentsOf: repositoryRoot().appending(path: "config/cast-tuning.default.json"))
        let ice = try IceServerProvider.make(profile: .directBaseline, turn: nil)

        let sender = try WebRTCSession(role: .sender, ice: ice, castTuningJSON: tuningData)
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

    func testSenderOfferAdvertisesH264AndNoAlternativeVideoCodec() async throws {
        let tuningData = try Data(contentsOf: repositoryRoot().appending(path: "config/cast-tuning.default.json"))
        let ice = try IceServerProvider.make(profile: .directBaseline, turn: nil)
        let sender = try WebRTCSession(role: .sender, ice: ice, castTuningJSON: tuningData)
        defer { sender.close() }

        let offer = try await sender.createOffer()
        let levelIDs = try NSRegularExpression(pattern: "profile-level-id=([0-9a-fA-F]{6})")
            .matches(in: offer, range: NSRange(offer.startIndex..., in: offer))
            .compactMap { Range($0.range(at: 1), in: offer).map { String(offer[$0]).lowercased() } }

        XCTAssertTrue(offer.contains(" H264/90000"))
        XCTAssertTrue(levelIDs.contains("42e029"), "advertised H.264 level IDs: \(levelIDs)")
        XCTAssertFalse(offer.contains(" VP8/90000"))
        XCTAssertFalse(offer.contains(" VP9/90000"))
        XCTAssertFalse(offer.contains(" AV1/90000"))
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

    func testSenderBoundaryMetricsUseTheExistingEncoderSessionField() {
        let snapshot = SenderMediaBoundarySnapshot(
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
            clarityMode: .staticClarity,
            claritySuccessfulRefreshes: 1,
            clarityFailedRefreshes: 0,
            clarityMotionRestores: 0
        )

        let fields = SessionMetricsSampler.fields(from: snapshot)

        XCTAssertEqual(fields["encoder_session_id"], .string("vt-1"))
        XCTAssertEqual(fields["requested_max_qp"], .integer(24))
        XCTAssertEqual(fields["last_key_frame_qp"], .integer(24))
        XCTAssertEqual(fields["max_qp_applied_encoder_session_id"], .string("vt-2"))
        XCTAssertEqual(fields["last_qp_sample_generation"], .integer(2))
        XCTAssertEqual(fields["last_qp_sample_encoder_session_id"], .string("vt-2"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
