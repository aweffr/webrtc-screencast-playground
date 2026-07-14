import XCTest
@testable import WebRTCScreencast

final class MediaBaselineChartTests: XCTestCase {
    func testChartIs1080pAndContainsMarkerAtStableROI() throws {
        let image = MediaBaselineChart.render(sequence: 123)

        XCTAssertEqual(image.width, 1_920)
        XCTAssertEqual(image.height, 1_080)
        let marker = try MediaBaselineMarker.decode(
            luma: image.lumaBytes(),
            width: image.width,
            height: image.height,
            bytesPerRow: image.width,
            roi: MediaBaselineLayout.markerROI
        )
        XCTAssertEqual(marker.sequence, 123)
    }
}
