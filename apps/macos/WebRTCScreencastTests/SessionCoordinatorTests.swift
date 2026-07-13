import XCTest
@testable import WebRTCScreencast

final class SessionCoordinatorTests: XCTestCase {
    func testReceiverRegistersPublishesCodeAndAnswersOffer() throws {
        var flow = SessionFlow(role: .receiver, senderCode: nil)

        XCTAssertEqual(try flow.handle(.start), [.connectSignaling])
        XCTAssertEqual(try flow.handle(.signalingConnected), [.registerReceiver])
        XCTAssertEqual(
            try flow.handle(.receiverRegistered(code: "ABCD1234")),
            [.publishPairingCode("ABCD1234")]
        )
        XCTAssertEqual(try flow.handle(.peerPaired), [])
        XCTAssertEqual(
            try flow.handle(.remoteOffer("offer")),
            [.setRemoteOffer("offer"), .createAndSendAnswer]
        )
    }

    func testSenderJoinsOnceOffersAndStartsCaptureOnlyAfterConnected() throws {
        var flow = SessionFlow(role: .sender, senderCode: "ABCD1234")

        XCTAssertEqual(try flow.handle(.start), [.connectSignaling])
        XCTAssertEqual(try flow.handle(.signalingConnected), [.join("ABCD1234")])
        XCTAssertEqual(try flow.handle(.peerPaired), [.createAndSendOffer])
        XCTAssertEqual(try flow.handle(.remoteAnswer("answer")), [.setRemoteAnswer("answer")])
        XCTAssertEqual(try flow.handle(.peerConnected), [.startCapture])
        XCTAssertEqual(try flow.handle(.signalingConnected), [])
    }

    func testTrickleICEFlowsBothDirections() throws {
        var flow = SessionFlow(role: .sender, senderCode: "ABCD1234")

        XCTAssertEqual(
            try flow.handle(.remoteCandidate(candidate: "remote", mid: "0", line: 0)),
            [.addRemoteCandidate(candidate: "remote", mid: "0", line: 0)]
        )
        XCTAssertEqual(
            try flow.handle(.localCandidate(candidate: "local", mid: "0", line: 0)),
            [.sendCandidate(candidate: "local", mid: "0", line: 0)]
        )
        XCTAssertEqual(try flow.handle(.localICEComplete), [.sendICEComplete])
    }

    func testHangupUsesFixedIdempotentTeardownOrder() throws {
        var flow = SessionFlow(role: .receiver, senderCode: nil)
        let expected: [SessionFlowCommand] = [
            .stopSampler,
            .stopCapture,
            .closeSignaling,
            .closePeer,
            .stopVirtualDisplay,
            .closeMetrics,
        ]

        XCTAssertEqual(try flow.handle(.remoteHangup), expected)
        XCTAssertEqual(try flow.handle(.stopRequested), [])
    }

    func testCaptureAndProfileFailuresTeardownWithoutRetryingConsumedCode() throws {
        var captureFailure = SessionFlow(role: .sender, senderCode: "ABCD1234")
        _ = try captureFailure.handle(.start)
        _ = try captureFailure.handle(.signalingConnected)
        let captureCommands = try captureFailure.handle(.captureFailed("permission denied"))
        XCTAssertEqual(captureCommands.first, .reportFailure(code: "capture_failed", message: "permission denied"))
        XCTAssertFalse(captureCommands.contains(.join("ABCD1234")))

        var pathFailure = SessionFlow(role: .sender, senderCode: "ABCD1234")
        let pathCommands = try pathFailure.handle(.profileViolated("relay/udp required"))
        XCTAssertEqual(pathCommands.first, .reportFailure(code: "profile_violation", message: "relay/udp required"))
        XCTAssertFalse(pathCommands.contains(.join("ABCD1234")))
    }
}
