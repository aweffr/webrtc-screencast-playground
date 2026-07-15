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

    func testChartHostOptionsRequireDisplayAndEvidenceDirectory() throws {
        let options = try MediaBaselineChartHostOptions.parse([
            "WebRTCScreencast",
            "--baseline-chart-host",
            "--display-id", "32",
            "--directory", "/tmp/baseline",
        ])

        XCTAssertEqual(options.displayID, 32)
        XCTAssertEqual(
            options.directory,
            URL(filePath: "/tmp/baseline", directoryHint: .isDirectory)
        )
        XCTAssertTrue(MediaBaselineChartHostOptions.isRequested([
            "WebRTCScreencast", "--baseline-chart-host",
        ]))
    }

    func testChartHostOptionsRejectMissingOrInvalidDisplay() {
        XCTAssertThrowsError(try MediaBaselineChartHostOptions.parse([
            "WebRTCScreencast", "--baseline-chart-host", "--directory", "/tmp/baseline",
        ]))
        XCTAssertThrowsError(try MediaBaselineChartHostOptions.parse([
            "WebRTCScreencast", "--baseline-chart-host",
            "--display-id", "invalid", "--directory", "/tmp/baseline",
        ]))
    }

    func testChartEventUsesStableJSONContract() throws {
        let event = MediaBaselineChartEvent(
            sequence: 30,
            committedMonotonicNs: 123_456,
            sourceReference: "source-reference-000030.png"
        )

        let decoded = try JSONDecoder().decode(
            MediaBaselineChartEvent.self,
            from: JSONEncoder().encode(event)
        )

        XCTAssertEqual(decoded, event)
    }
}
