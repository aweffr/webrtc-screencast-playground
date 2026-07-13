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

        XCTAssertTrue(offer.contains(" H264/90000"))
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

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
