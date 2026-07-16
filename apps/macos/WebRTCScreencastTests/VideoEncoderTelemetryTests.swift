import XCTest
@testable import WebRTCScreencast

final class VideoEncoderTelemetryTests: XCTestCase {
    func testCountsFramesForwardedIntoWebRTCSource() {
        let telemetry = SenderMediaBoundaryTelemetry()

        telemetry.recordSourceFrameForwarded(pixelFormat: 875_704_438)
        telemetry.recordSourceFrameForwarded(pixelFormat: 875_704_422)

        let snapshot = telemetry.sourceSnapshot()
        XCTAssertEqual(snapshot.frames, 2)
        XCTAssertEqual(snapshot.pixelFormat, 875_704_422)
    }
}
