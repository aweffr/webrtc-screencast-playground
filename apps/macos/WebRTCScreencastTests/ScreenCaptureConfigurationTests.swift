import CoreMedia
import CoreVideo
import XCTest
@testable import WebRTCScreencast

final class ScreenCaptureConfigurationTests: XCTestCase {
    func testCaptureUsesFixedLowLatency1080pNV12Values() throws {
        let values = try ScreenCaptureConfigurationValues.make(
            source: .virtualExtendedDisplay,
            sourcePixelSize: CGSize(width: 1_920, height: 1_080),
            iceProfile: .productionRelay,
            excludedReceiverPID: nil
        )

        XCTAssertEqual(values.width, 1_920)
        XCTAssertEqual(values.height, 1_080)
        XCTAssertEqual(values.pixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        XCTAssertEqual(values.minimumFrameInterval, CMTime(value: 1, timescale: 30))
        XCTAssertEqual(values.queueDepth, 3)
        XCTAssertTrue(values.showsCursor)
        XCTAssertTrue(values.preservesAspectRatio)
        XCTAssertEqual(values.destinationRect, CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
    }

    func testMainDisplayUsesLetterboxGeometry() throws {
        let values = try ScreenCaptureConfigurationValues.make(
            source: .mainDisplayMirror,
            sourcePixelSize: CGSize(width: 3_440, height: 1_440),
            iceProfile: .directBaseline,
            excludedReceiverPID: 42
        )

        XCTAssertEqual(values.destinationRect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(values.destinationRect.minY, 138.1395, accuracy: 0.001)
        XCTAssertEqual(values.destinationRect.width, 1_920, accuracy: 0.001)
        XCTAssertEqual(values.destinationRect.height, 803.7209, accuracy: 0.001)
        XCTAssertEqual(values.excludedReceiverPID, 42)
    }

    func testReceiverExclusionIsLimitedToDirectMainDisplayBaseline() {
        XCTAssertThrowsError(try ScreenCaptureConfigurationValues.make(
            source: .mainDisplayMirror,
            sourcePixelSize: CGSize(width: 1_920, height: 1_080),
            iceProfile: .productionRelay,
            excludedReceiverPID: 42
        ))
        XCTAssertThrowsError(try ScreenCaptureConfigurationValues.make(
            source: .virtualExtendedDisplay,
            sourcePixelSize: CGSize(width: 1_920, height: 1_080),
            iceProfile: .directBaseline,
            excludedReceiverPID: 42
        ))
    }

    func testInvalidSourceSizeFails() {
        XCTAssertThrowsError(try ScreenCaptureConfigurationValues.make(
            source: .mainDisplayMirror,
            sourcePixelSize: .zero,
            iceProfile: .directBaseline,
            excludedReceiverPID: nil
        ))
    }

    func testSourceResolutionErrorsHaveActionableDescriptions() {
        XCTAssertEqual(
            ScreenSourceProviderError.displayNotFound(7).errorDescription,
            "Display 7 is not available to ScreenCaptureKit"
        )
        XCTAssertEqual(
            ScreenSourceProviderError.excludedApplicationNotFound(42).errorDescription,
            "Receiver process 42 is not available to ScreenCaptureKit"
        )
    }
}
