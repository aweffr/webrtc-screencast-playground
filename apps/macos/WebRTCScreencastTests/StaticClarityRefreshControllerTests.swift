import XCTest
@testable import WebRTCScreencast

final class StaticClarityRefreshControllerTests: XCTestCase {
    private final class CallRecorder {
        var calls: [String] = []
    }

    func testEnteringStaticModeAppliesOneFPSBeforeForcingKeyFrame() {
        var calls: [String] = []
        let controller = StaticClarityRefreshController(
            activeFPS: 15,
            clarityFPS: 1,
            maxBitrateBps: 5_000_000,
            activeMaxQp: 32,
            staticMaxQp: 22,
            applyLivePolicy: { fps, bitrate, maxQp in
                let qp = maxQp.map(String.init) ?? "none"
                calls.append("apply:\(fps):\(bitrate):\(qp)")
                return true
            },
            forceKeyFrame: {
                calls.append("force-key-frame")
                return true
            }
        )

        XCTAssertTrue(controller.handle(.enterStaticClarity))
        XCTAssertEqual(calls, ["apply:1:5000000:22", "force-key-frame"])
        XCTAssertEqual(controller.snapshot().mode, .staticClarity)
        XCTAssertEqual(controller.snapshot().successfulRefreshes, 1)
    }

    func testExitingStaticModeRestoresActiveFPSWithoutKeyFrame() {
        let recorder = CallRecorder()
        let controller = makeController(recorder: recorder)
        XCTAssertTrue(controller.handle(.enterStaticClarity))
        recorder.calls.removeAll()

        XCTAssertTrue(controller.handle(.exitStaticClarity))
        XCTAssertEqual(recorder.calls, ["apply:15:5000000:32"])
        XCTAssertEqual(controller.snapshot().mode, .active)
    }

    func testFailedKeyFrameRestoresActivePolicy() {
        var calls: [String] = []
        let controller = StaticClarityRefreshController(
            activeFPS: 15,
            clarityFPS: 1,
            maxBitrateBps: 5_000_000,
            activeMaxQp: 32,
            staticMaxQp: 22,
            applyLivePolicy: { fps, bitrate, maxQp in
                let qp = maxQp.map(String.init) ?? "none"
                calls.append("apply:\(fps):\(bitrate):\(qp)")
                return true
            },
            forceKeyFrame: {
                calls.append("force-key-frame")
                return false
            }
        )

        XCTAssertFalse(controller.handle(.enterStaticClarity))
        XCTAssertEqual(
            calls,
            ["apply:1:5000000:22", "force-key-frame", "apply:15:5000000:32"]
        )
        let snapshot = controller.snapshot()
        XCTAssertEqual(snapshot.mode, .active)
        XCTAssertEqual(snapshot.failedRefreshes, 1)
        XCTAssertEqual(snapshot.successfulRefreshes, 0)
    }

    func testEnteringStaticModeCanRetryAfterLivePolicyFailure() {
        var applyAttempts = 0
        var keyFrameRequests = 0
        let controller = StaticClarityRefreshController(
            activeFPS: 15,
            clarityFPS: 1,
            maxBitrateBps: 5_000_000,
            activeMaxQp: 32,
            staticMaxQp: 22,
            applyLivePolicy: { _, _, _ in
                applyAttempts += 1
                return applyAttempts > 1
            },
            forceKeyFrame: {
                keyFrameRequests += 1
                return true
            }
        )

        XCTAssertFalse(controller.handle(.enterStaticClarity))
        XCTAssertTrue(controller.handle(.enterStaticClarity))
        XCTAssertEqual(applyAttempts, 2)
        XCTAssertEqual(keyFrameRequests, 1)
        XCTAssertEqual(controller.snapshot().mode, .staticClarity)
    }

    func testRestoringActiveCanRetryAfterLivePolicyFailure() {
        var failNextActiveRestore = true
        let controller = StaticClarityRefreshController(
            activeFPS: 15,
            clarityFPS: 1,
            maxBitrateBps: 5_000_000,
            activeMaxQp: 32,
            staticMaxQp: 22,
            applyLivePolicy: { fps, _, _ in
                if fps == 15, failNextActiveRestore {
                    failNextActiveRestore = false
                    return false
                }
                return true
            },
            forceKeyFrame: { true }
        )
        XCTAssertTrue(controller.handle(.enterStaticClarity))

        XCTAssertFalse(controller.handle(.exitStaticClarity))
        XCTAssertTrue(controller.handle(.exitStaticClarity))
        XCTAssertEqual(controller.snapshot().mode, .active)
        XCTAssertEqual(controller.snapshot().activeRestores, 1)
    }

    func testWithoutMaxQpPreservesCadenceBitrateAndKeyFrameBehavior() {
        var calls: [String] = []
        let controller = StaticClarityRefreshController(
            activeFPS: 15,
            clarityFPS: 1,
            maxBitrateBps: 5_000_000,
            activeMaxQp: nil,
            staticMaxQp: nil,
            applyLivePolicy: { fps, bitrate, maxQp in
                let qp = maxQp.map(String.init) ?? "none"
                calls.append("apply:\(fps):\(bitrate):\(qp)")
                return true
            },
            forceKeyFrame: {
                calls.append("force-key-frame")
                return true
            }
        )

        XCTAssertTrue(controller.handle(.enterStaticClarity))
        XCTAssertTrue(controller.handle(.exitStaticClarity))
        XCTAssertEqual(
            calls,
            ["apply:1:5000000:none", "force-key-frame", "apply:15:5000000:none"]
        )
        let snapshot = controller.snapshot()
        XCTAssertEqual(snapshot.mode, .active)
        XCTAssertEqual(snapshot.successfulRefreshes, 1)
        XCTAssertEqual(snapshot.activeRestores, 1)
    }

    func testTransitionLatchRetainsFailureUntilApplied() {
        var latch = ClarityTransitionLatch()

        XCTAssertEqual(latch.update(with: .enterStaticClarity), .enterStaticClarity)
        latch.recordApplied(false)
        XCTAssertEqual(latch.update(with: .none), .enterStaticClarity)
        latch.recordApplied(true)
        XCTAssertEqual(latch.update(with: .none), .none)
    }

    func testTransitionLatchUsesLatestDesiredTransition() {
        var latch = ClarityTransitionLatch()
        _ = latch.update(with: .enterStaticClarity)
        latch.recordApplied(false)

        XCTAssertEqual(latch.update(with: .exitStaticClarity), .exitStaticClarity)
    }

    private func makeController(recorder: CallRecorder) -> StaticClarityRefreshController {
        StaticClarityRefreshController(
            activeFPS: 15,
            clarityFPS: 1,
            maxBitrateBps: 5_000_000,
            activeMaxQp: 32,
            staticMaxQp: 22,
            applyLivePolicy: { fps, bitrate, maxQp in
                let qp = maxQp.map(String.init) ?? "none"
                recorder.calls.append("apply:\(fps):\(bitrate):\(qp)")
                return true
            },
            forceKeyFrame: {
                recorder.calls.append("force-key-frame")
                return true
            }
        )
    }
}
