import XCTest
import ScreenCaptureKit
@testable import WebRTCScreencast

final class DamageIdleDetectorTests: XCTestCase {
    func testQuietDeadlineEntersStaticWithoutAnotherDamageObservation() {
        var detector = DamageIdleDetector(quietDurationNs: 600_000_000)
        let generation = detector.start()

        let activity = detector.observeDamage(at: 1_000_000_000)
        XCTAssertEqual(activity.mode, .active)
        XCTAssertEqual(activity.transition, .none)
        XCTAssertEqual(activity.quietDeadlineMonotonicNs, 1_600_000_000)

        let early = detector.settleIfDue(
            at: 1_599_999_999,
            generation: generation
        )
        XCTAssertEqual(early.mode, .active)
        XCTAssertEqual(early.transition, .none)
        XCTAssertEqual(early.nextQuietDeadlineMonotonicNs, 1_600_000_000)

        let settled = detector.settleIfDue(
            at: 1_600_000_000,
            generation: generation
        )
        XCTAssertEqual(settled.mode, .staticClarity)
        XCTAssertEqual(settled.transition, .enterStaticClarity)
        XCTAssertNil(settled.nextQuietDeadlineMonotonicNs)
    }

    func testLaterDamageMovesTheSingleQuietDeadline() {
        var detector = DamageIdleDetector(quietDurationNs: 600_000_000)
        let generation = detector.start()
        _ = detector.observeDamage(at: 1_000_000_000)

        let laterDamage = detector.observeDamage(at: 1_400_000_000)
        XCTAssertEqual(laterDamage.quietDeadlineMonotonicNs, 2_000_000_000)

        let oldDeadline = detector.settleIfDue(
            at: 1_600_000_000,
            generation: generation
        )
        XCTAssertEqual(oldDeadline.mode, .active)
        XCTAssertEqual(oldDeadline.nextQuietDeadlineMonotonicNs, 2_000_000_000)

        let newDeadline = detector.settleIfDue(
            at: 2_000_000_000,
            generation: generation
        )
        XCTAssertEqual(newDeadline.transition, .enterStaticClarity)
    }

    func testDamageExitsStaticExactlyOnce() {
        var detector = DamageIdleDetector(quietDurationNs: 600_000_000)
        let generation = detector.start()
        _ = detector.observeDamage(at: 1_000_000_000)
        _ = detector.settleIfDue(at: 1_600_000_000, generation: generation)

        let wake = detector.observeDamage(at: 1_700_000_000)
        XCTAssertEqual(wake.mode, .active)
        XCTAssertEqual(wake.transition, .exitStaticClarity)

        let continuedActivity = detector.observeDamage(at: 1_800_000_000)
        XCTAssertEqual(continuedActivity.mode, .active)
        XCTAssertEqual(continuedActivity.transition, .none)
    }

    func testOutOfOrderDamageDoesNotChangeTheDeadline() {
        var detector = DamageIdleDetector(quietDurationNs: 600_000_000)
        _ = detector.start()
        _ = detector.observeDamage(at: 2_000_000_000)

        let stale = detector.observeDamage(at: 1_900_000_000)

        XCTAssertEqual(stale.lastDamageMonotonicNs, 2_000_000_000)
        XCTAssertEqual(stale.quietDeadlineMonotonicNs, 2_600_000_000)
        XCTAssertEqual(stale.transition, .none)
    }

    func testStopAndRestartInvalidateAnOldQuietCheck() {
        var detector = DamageIdleDetector(quietDurationNs: 600_000_000)
        let oldGeneration = detector.start()
        _ = detector.observeDamage(at: 1_000_000_000)
        detector.stop()

        let currentGeneration = detector.start()
        _ = detector.observeDamage(at: 2_000_000_000)

        let staleCheck = detector.settleIfDue(
            at: 3_000_000_000,
            generation: oldGeneration
        )
        XCTAssertEqual(staleCheck.mode, .active)
        XCTAssertEqual(staleCheck.transition, .none)
        XCTAssertEqual(staleCheck.quietDeadlineMonotonicNs, 2_600_000_000)

        let currentCheck = detector.settleIfDue(
            at: 3_000_000_000,
            generation: currentGeneration
        )
        XCTAssertEqual(currentCheck.transition, .enterStaticClarity)
    }

    func testStartedMissingAndNonEmptyDirtyMetadataCountAsDamage() {
        XCTAssertTrue(ScreenDamageClassifier.hasDamage(status: .started, dirtyRects: []))
        XCTAssertTrue(ScreenDamageClassifier.hasDamage(status: .complete, dirtyRects: nil))
        XCTAssertTrue(
            ScreenDamageClassifier.hasDamage(
                status: .complete,
                dirtyRects: [CGRect(x: 10, y: 20, width: 8, height: 8)]
            )
        )
    }

    func testCompleteFrameWithEmptyDirtyMetadataIsQuiet() {
        XCTAssertFalse(ScreenDamageClassifier.hasDamage(status: .complete, dirtyRects: []))
    }
}
