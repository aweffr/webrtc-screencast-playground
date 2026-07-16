import XCTest
@testable import WebRTCScreencast

final class VisualStabilityDetectorTests: XCTestCase {
    private let configuration = VisualStabilityConfiguration(
        stableDuration: .milliseconds(600),
        sampleDeltaThreshold: 8,
        maximumChangedSampleRatio: 0.02,
        minimumMotionSampleRatio: 0.08
    )

    func testLowVisualChangeTriggersOneStaticRefreshAfterDwell() {
        var detector = VisualStabilityDetector(configuration: configuration)
        let frame = Array(repeating: UInt8(40), count: 100)

        XCTAssertEqual(detector.evaluate(samples: frame, timestamp: .zero).mode, .motion)
        XCTAssertEqual(detector.evaluate(samples: frame, timestamp: .milliseconds(100)).mode, .settling)
        XCTAssertEqual(detector.evaluate(samples: frame, timestamp: .milliseconds(699)).transition, .none)

        let refresh = detector.evaluate(samples: frame, timestamp: .milliseconds(700))
        XCTAssertEqual(refresh.mode, .staticClarity)
        XCTAssertEqual(refresh.transition, .enterStaticClarity)
        XCTAssertEqual(refresh.changedSampleRatio, 0)

        XCTAssertEqual(
            detector.evaluate(samples: frame, timestamp: .milliseconds(900)).transition,
            .none
        )
    }

    func testMaterialChangeExitsStaticModeAndAllowsAnotherRefresh() {
        var detector = VisualStabilityDetector(configuration: configuration)
        let still = Array(repeating: UInt8(40), count: 100)
        var changed = still
        for index in 0..<9 { changed[index] = 80 }

        _ = detector.evaluate(samples: still, timestamp: .zero)
        _ = detector.evaluate(samples: still, timestamp: .milliseconds(100))
        _ = detector.evaluate(samples: still, timestamp: .milliseconds(700))

        let motion = detector.evaluate(samples: changed, timestamp: .milliseconds(800))
        XCTAssertEqual(motion.mode, .motion)
        XCTAssertEqual(motion.transition, .exitStaticClarity)
        XCTAssertEqual(motion.changedSampleRatio, 0.09, accuracy: 0.000_1)

        XCTAssertEqual(
            detector.evaluate(samples: changed, timestamp: .milliseconds(900)).mode,
            .settling
        )
        XCTAssertEqual(
            detector.evaluate(samples: changed, timestamp: .milliseconds(1_500)).transition,
            .enterStaticClarity
        )
    }

    func testMinorChangeDoesNotExitStaticClarityMode() {
        var detector = VisualStabilityDetector(configuration: configuration)
        let still = Array(repeating: UInt8(40), count: 100)
        var minorChange = still
        for index in 0..<5 { minorChange[index] = 80 }

        _ = detector.evaluate(samples: still, timestamp: .zero)
        _ = detector.evaluate(samples: still, timestamp: .milliseconds(100))
        _ = detector.evaluate(samples: still, timestamp: .milliseconds(700))

        let decision = detector.evaluate(samples: minorChange, timestamp: .milliseconds(800))
        XCTAssertEqual(decision.mode, .staticClarity)
        XCTAssertEqual(decision.transition, .none)
        XCTAssertEqual(decision.changedSampleRatio, 0.05, accuracy: 0.000_1)
    }

    func testSmallAnimatedRegionStillCountsAsStable() {
        var detector = VisualStabilityDetector(configuration: configuration)
        let baseline = Array(repeating: UInt8(40), count: 100)
        var cursorOnly = baseline
        cursorOnly[0] = 80

        _ = detector.evaluate(samples: baseline, timestamp: .zero)
        let decision = detector.evaluate(samples: cursorOnly, timestamp: .milliseconds(100))

        XCTAssertEqual(decision.mode, .settling)
        XCTAssertEqual(decision.changedSampleRatio, 0.01, accuracy: 0.000_1)
    }

    func testLumaSamplerAveragesEachGridCell() {
        let luma: [UInt8] = [
            0, 2, 10, 12,
            4, 6, 14, 16,
            20, 22, 30, 32,
            24, 26, 34, 36,
        ]

        let samples = LumaFrameSampler.sample(
            width: 4,
            height: 4,
            gridWidth: 2,
            gridHeight: 2,
            pixelAt: { x, y in luma[(y * 4) + x] }
        )

        XCTAssertEqual(samples, [3, 13, 23, 33])
    }
}
