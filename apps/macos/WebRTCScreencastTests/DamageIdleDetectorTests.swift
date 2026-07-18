import CoreVideo
import Darwin
import ScreenCaptureKit
import XCTest
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
        let contentRect = CGRect(x: 100, y: 0, width: 1_700, height: 1_080)
        XCTAssertTrue(
            ScreenDamageClassifier.hasDamage(
                status: .started,
                dirtyRects: [],
                contentRect: contentRect
            )
        )
        XCTAssertTrue(
            ScreenDamageClassifier.hasDamage(
                status: .complete,
                dirtyRects: nil,
                contentRect: contentRect
            )
        )
        XCTAssertTrue(
            ScreenDamageClassifier.hasDamage(
                status: .complete,
                dirtyRects: [CGRect(x: 10, y: 20, width: 8, height: 8)],
                contentRect: contentRect
            )
        )
    }

    func testCompleteFrameWithEmptyDirtyMetadataIsQuiet() {
        XCTAssertFalse(
            ScreenDamageClassifier.hasDamage(
                status: .complete,
                dirtyRects: [],
                contentRect: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
            )
        )
    }

    func testPixelIdenticalSystemStatusStripRedrawIsQuiet() {
        let contentRect = CGRect(x: 124.5, y: 0, width: 1_671, height: 1_080)

        XCTAssertFalse(
            ScreenDamageClassifier.hasDamage(
                status: .complete,
                dirtyRects: [CGRect(x: 124.5, y: 0, width: 1_671, height: 33)],
                contentRect: contentRect,
                statusStripPixelsChanged: { _ in false }
            )
        )
    }

    func testRealFullWidthTopContentChangeRemainsActive() {
        let contentRect = CGRect(x: 124.5, y: 0, width: 1_671, height: 1_080)

        XCTAssertTrue(
            ScreenDamageClassifier.hasDamage(
                status: .complete,
                dirtyRects: [CGRect(x: 124.5, y: 0, width: 1_671, height: 33)],
                contentRect: contentRect,
                statusStripPixelsChanged: { _ in true }
            )
        )
    }

    func testTopBandCursorOrMenuDamageRemainsActive() {
        let contentRect = CGRect(x: 124.5, y: 0, width: 1_671, height: 1_080)

        XCTAssertTrue(
            ScreenDamageClassifier.hasDamage(
                status: .complete,
                dirtyRects: [CGRect(x: 1_700, y: 4, width: 24, height: 24)],
                contentRect: contentRect
            )
        )
    }

    func testStatusStripAlongsideContentDamageRemainsActive() {
        let contentRect = CGRect(x: 124.5, y: 0, width: 1_671, height: 1_080)

        XCTAssertTrue(
            ScreenDamageClassifier.hasDamage(
                status: .complete,
                dirtyRects: [
                    CGRect(x: 124.5, y: 0, width: 1_671, height: 33),
                    CGRect(x: 500, y: 300, width: 200, height: 100),
                ],
                contentRect: contentRect
            )
        )
    }

    func testNV12ComparatorIgnoresIdenticalFrames() throws {
        let previous = try makeNV12Buffer(fill: 16)
        let current = try makeNV12Buffer(fill: 16)

        XCTAssertFalse(NV12PixelBufferComparator.hasChanges(
            between: previous,
            and: current
        ))
    }

    func testNV12ComparatorDetectsLumaAndChromaChanges() throws {
        let previous = try makeNV12Buffer(fill: 16)
        let lumaChanged = try makeNV12Buffer(fill: 16)
        setByte(17, in: lumaChanged, plane: 0)
        XCTAssertTrue(NV12PixelBufferComparator.hasChanges(
            between: previous,
            and: lumaChanged
        ))

        let chromaChanged = try makeNV12Buffer(fill: 16)
        setByte(17, in: chromaChanged, plane: 1)
        XCTAssertTrue(NV12PixelBufferComparator.hasChanges(
            between: previous,
            and: chromaChanged
        ))
    }

    private func makeNV12Buffer(fill: UInt8) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            nil,
            16,
            8,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &created
        ), kCVReturnSuccess)
        let buffer = try XCTUnwrap(created)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            memset(
                base,
                Int32(fill),
                CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                    * CVPixelBufferGetHeightOfPlane(buffer, plane)
            )
        }
        return buffer
    }

    private func setByte(_ value: UInt8, in buffer: CVPixelBuffer, plane: Int) {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        CVPixelBufferGetBaseAddressOfPlane(buffer, plane)?
            .assumingMemoryBound(to: UInt8.self).pointee = value
    }
}
