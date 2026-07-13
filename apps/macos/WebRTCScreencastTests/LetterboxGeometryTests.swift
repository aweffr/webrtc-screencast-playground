import CoreGraphics
import XCTest
@testable import WebRTCScreencast

final class LetterboxGeometryTests: XCTestCase {
    func testMatchingAspectRatioFillsCanvas() throws {
        let rect = try LetterboxGeometry.destinationRect(source: CGSize(width: 1920, height: 1080), canvas: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    func testUltrawideSourceIsLetterboxedVertically() throws {
        let rect = try LetterboxGeometry.destinationRect(source: CGSize(width: 3440, height: 1440), canvas: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(rect.width, 1920, accuracy: 0.001)
        XCTAssertEqual(rect.height, 803.7209, accuracy: 0.001)
        XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 138.1395, accuracy: 0.001)
    }

    func testPortraitSourceIsLetterboxedHorizontally() throws {
        let rect = try LetterboxGeometry.destinationRect(source: CGSize(width: 1080, height: 1920), canvas: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(rect.width, 607.5, accuracy: 0.001)
        XCTAssertEqual(rect.height, 1080, accuracy: 0.001)
        XCTAssertEqual(rect.minX, 656.25, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.001)
    }

    func testInvalidDimensionsAreRejected() {
        XCTAssertThrowsError(try LetterboxGeometry.destinationRect(source: .zero, canvas: CGSize(width: 1920, height: 1080)))
        XCTAssertThrowsError(try LetterboxGeometry.destinationRect(source: CGSize(width: 1920, height: 1080), canvas: .zero))
    }
}
