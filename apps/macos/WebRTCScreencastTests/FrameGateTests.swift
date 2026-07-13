import XCTest
@testable import WebRTCScreencast

final class FrameGateTests: XCTestCase {
    func testLargeChangeImmediatelyEntersThirtyFPS() {
        var gate = FrameGate()
        let decision = gate.evaluate(dirtyRatio: 0.005, timestamp: .zero)
        XCTAssertEqual(decision.state, .motion30)
        XCTAssertTrue(decision.shouldSubmit)
    }

    func testSmallChangeImmediatelyEntersAtLeastFifteenFPS() {
        var gate = FrameGate()
        let decision = gate.evaluate(dirtyRatio: 0.0001, timestamp: .zero)
        XCTAssertEqual(decision.state, .detail15)
        XCTAssertTrue(decision.shouldSubmit)
    }

    func testDownshiftUsesConfiguredDwellTimes() {
        var gate = FrameGate()
        _ = gate.evaluate(dirtyRatio: 0.01, timestamp: .zero)

        XCTAssertEqual(gate.evaluate(dirtyRatio: 0, timestamp: .milliseconds(499)).state, .motion30)
        XCTAssertEqual(gate.evaluate(dirtyRatio: 0, timestamp: .milliseconds(500)).state, .detail15)
        XCTAssertEqual(gate.evaluate(dirtyRatio: 0, timestamp: .milliseconds(1_299)).state, .detail15)
        XCTAssertEqual(gate.evaluate(dirtyRatio: 0, timestamp: .milliseconds(1_300)).state, .quiet5)
        XCTAssertEqual(gate.evaluate(dirtyRatio: 0, timestamp: .milliseconds(1_599)).state, .quiet5)
        XCTAssertEqual(gate.evaluate(dirtyRatio: 0, timestamp: .milliseconds(1_600)).state, .idle)
    }

    func testIdleWakesImmediatelyOnAnyChange() {
        var gate = FrameGate()
        _ = gate.evaluate(dirtyRatio: 0.01, timestamp: .zero)
        _ = gate.evaluate(dirtyRatio: 0, timestamp: .milliseconds(500))
        _ = gate.evaluate(dirtyRatio: 0, timestamp: .milliseconds(1_300))
        _ = gate.evaluate(dirtyRatio: 0, timestamp: .milliseconds(1_600))

        let small = gate.evaluate(dirtyRatio: 0.0001, timestamp: .milliseconds(1_601))
        XCTAssertEqual(small.state, .detail15)
        XCTAssertTrue(small.shouldSubmit)
        let large = gate.evaluate(dirtyRatio: 0.02, timestamp: .milliseconds(1_602))
        XCTAssertEqual(large.state, .motion30)
        XCTAssertTrue(large.shouldSubmit)
    }

    func testSubmitIntervalsDropIntermediateFrames() {
        var gate = FrameGate()
        XCTAssertTrue(gate.evaluate(dirtyRatio: 0.01, timestamp: .zero).shouldSubmit)
        XCTAssertFalse(gate.evaluate(dirtyRatio: 0.01, timestamp: .milliseconds(10)).shouldSubmit)
        XCTAssertTrue(gate.evaluate(dirtyRatio: 0.01, timestamp: .milliseconds(34)).shouldSubmit)

        var detailGate = FrameGate()
        XCTAssertTrue(detailGate.evaluate(dirtyRatio: 0.0001, timestamp: .zero).shouldSubmit)
        XCTAssertFalse(detailGate.evaluate(dirtyRatio: 0.0001, timestamp: .milliseconds(60)).shouldSubmit)
        XCTAssertTrue(detailGate.evaluate(dirtyRatio: 0.0001, timestamp: .milliseconds(67)).shouldSubmit)
    }

    func testZeroDirtyFramesAreNotSubmitted() {
        var gate = FrameGate()
        _ = gate.evaluate(dirtyRatio: 0.01, timestamp: .zero)
        XCTAssertFalse(gate.evaluate(dirtyRatio: 0, timestamp: .milliseconds(40)).shouldSubmit)
    }

    func testOutOfOrderTimestampDoesNotSubmit() {
        var gate = FrameGate()
        _ = gate.evaluate(dirtyRatio: 0.01, timestamp: .milliseconds(100))
        let decision = gate.evaluate(dirtyRatio: 0.01, timestamp: .milliseconds(90))
        XCTAssertFalse(decision.shouldSubmit)
        XCTAssertEqual(decision.state, .motion30)
    }
}
