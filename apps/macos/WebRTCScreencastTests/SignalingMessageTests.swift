import Foundation
import XCTest
@testable import WebRTCScreencast

final class SignalingMessageTests: XCTestCase {
    func testSharedGoFixturesDecodeEveryProtocolMessage() throws {
        let fixtures = try fixtureURLs()
        XCTAssertEqual(fixtures.count, 10)

        let decoded = try fixtures.map { try SignalingCodec.decode(Data(contentsOf: $0)) }
        XCTAssertEqual(Set(decoded.map(\.type.rawValue)), Set([
            "receiver.register", "receiver.registered", "sender.join", "session.paired",
            "sdp.offer", "sdp.answer", "ice.candidate", "ice.complete", "session.hangup", "error",
        ]))
    }

    func testPairingCodeNormalizationMatchesGo() throws {
        XCTAssertEqual(try PairingCode.normalize(" 01ab-cd23 "), "01ABCD23")
        for invalid in ["0123456", "012345678", "01234O67", "01234I67", "01234L67", "01234U67", "01234!67"] {
            XCTAssertThrowsError(try PairingCode.normalize(invalid))
        }
    }

    func testSDPAndICEPayloadsRoundTripWithExactFieldNames() throws {
        let offer = SignalingEnvelope(messageID: "sender-2", payload: .sdpOffer("v=0\r\n"))
        let candidate = SignalingEnvelope(
            messageID: "sender-3",
            payload: .iceCandidate(candidate: "candidate:1", sdpMid: "0", sdpMLineIndex: 0)
        )

        let encodedOffer = try SignalingCodec.encode(offer)
        let encodedCandidate = try SignalingCodec.encode(candidate)
        XCTAssertEqual(try SignalingCodec.decode(encodedOffer), offer)
        XCTAssertEqual(try SignalingCodec.decode(encodedCandidate), candidate)

        let candidateObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedCandidate) as? [String: Any])
        let payload = try XCTUnwrap(candidateObject["payload"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), Set(["candidate", "sdp_mid", "sdp_mline_index"]))
        XCTAssertEqual(candidateObject["type"] as? String, "ice.candidate")
        XCTAssertEqual(candidateObject["message_id"] as? String, "sender-3")
        XCTAssertEqual(candidateObject["version"] as? Int, 1)
    }

    func testServerErrorDecodesStably() throws {
        let envelope = try decodeFixture("error.json")
        XCTAssertEqual(
            envelope.payload,
            .serverError(code: "invalid_message", message: "invalid message", relatedMessageID: "sender-2")
        )
    }

    func testUnknownMessageTypeFails() {
        let data = Data(#"{"version":1,"message_id":"m","type":"room.join","payload":{}}"#.utf8)
        XCTAssertThrowsError(try SignalingCodec.decode(data))
    }

    private func decodeFixture(_ name: String) throws -> SignalingEnvelope {
        let url = try XCTUnwrap(try fixtureURLs().first { $0.lastPathComponent == name })
        return try SignalingCodec.decode(Data(contentsOf: url))
    }

    private func fixtureURLs() throws -> [URL] {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repositoryRoot = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = repositoryRoot.appending(path: "server/testdata/protocol-v1", directoryHint: .isDirectory)
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
