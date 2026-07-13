import XCTest
@testable import WebRTCScreencast

final class SessionStateTests: XCTestCase {
    func testReceiverHappyPath() throws {
        var machine = SessionStateMachine()
        try machine.handle(.begin(role: .receiver))
        XCTAssertEqual(machine.state, .connectingSignaling(role: .receiver))
        try machine.handle(.signalingConnected)
        XCTAssertEqual(machine.state, .waitingForPeer(role: .receiver))
        try machine.handle(.peerPaired)
        try machine.handle(.negotiationCompleted)
        XCTAssertEqual(machine.state, .connected(role: .receiver))
        try machine.handle(.endRequested)
        XCTAssertEqual(machine.state, .ending)
        try machine.handle(.ended)
        XCTAssertEqual(machine.state, .idle)
    }

    func testSenderCanJoinOnlyAfterSignalingConnects() throws {
        var machine = SessionStateMachine()
        try machine.handle(.begin(role: .sender))
        XCTAssertThrowsError(try machine.handle(.senderJoinRequested(code: "01ABCD23")))
        try machine.handle(.signalingConnected)
        XCTAssertNoThrow(try machine.handle(.senderJoinRequested(code: "01ABCD23")))
        XCTAssertEqual(machine.state, .waitingForPeer(role: .sender))
    }

    func testOnlySenderCreatesOffer() throws {
        var receiver = SessionStateMachine()
        try receiver.handle(.begin(role: .receiver))
        try receiver.handle(.signalingConnected)
        try receiver.handle(.peerPaired)
        XCTAssertThrowsError(try receiver.handle(.localOfferCreated))

        var sender = SessionStateMachine()
        try sender.handle(.begin(role: .sender))
        try sender.handle(.signalingConnected)
        try sender.handle(.peerPaired)
        XCTAssertNoThrow(try sender.handle(.localOfferCreated))
    }

    func testFailureIsVisibleAndCleanupIsIdempotent() throws {
        var machine = SessionStateMachine()
        try machine.handle(.begin(role: .sender))
        try machine.handle(.failed(SessionFailure(code: "signaling_failed", message: "Could not connect")))
        XCTAssertEqual(machine.state, .failed(SessionFailure(code: "signaling_failed", message: "Could not connect")))
        try machine.handle(.endRequested)
        try machine.handle(.ended)
        try machine.handle(.ended)
        XCTAssertEqual(machine.state, .idle)
    }

    func testCannotChangeRoleDuringSession() throws {
        var machine = SessionStateMachine()
        try machine.handle(.begin(role: .sender))
        XCTAssertThrowsError(try machine.handle(.begin(role: .receiver)))
    }
}
