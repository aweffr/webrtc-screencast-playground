import CoreGraphics
import XCTest
@testable import WebRTCScreencast

final class DirtyRegionAnalyzerTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)

    func testUnionAreaForDisjointRectangles() {
        let area = DirtyRegionAnalyzer.unionArea(
            of: [CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 20, y: 20, width: 10, height: 10)],
            clippedTo: bounds
        )
        XCTAssertEqual(area, 200, accuracy: 0.0001)
    }

    func testUnionAreaDoesNotDoubleCountOverlap() {
        let area = DirtyRegionAnalyzer.unionArea(
            of: [CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 5, y: 0, width: 10, height: 10)],
            clippedTo: bounds
        )
        XCTAssertEqual(area, 150, accuracy: 0.0001)
    }

    func testUnionAreaHandlesNestedAndClippedRectangles() {
        let area = DirtyRegionAnalyzer.unionArea(
            of: [
                CGRect(x: -10, y: -10, width: 20, height: 20),
                CGRect(x: 2, y: 2, width: 3, height: 3),
                CGRect(x: 90, y: 90, width: 20, height: 20),
            ],
            clippedTo: bounds
        )
        XCTAssertEqual(area, 200, accuracy: 0.0001)
    }

    func testUnionAreaHandlesPartialVerticalOverlap() {
        let area = DirtyRegionAnalyzer.unionArea(
            of: [
                CGRect(x: 0, y: 0, width: 10, height: 20),
                CGRect(x: 5, y: 10, width: 10, height: 20),
            ],
            clippedTo: bounds
        )
        XCTAssertEqual(area, 350, accuracy: 0.0001)
    }

    func testDirtyRatioUsesFrameArea() {
        XCTAssertEqual(
            DirtyRegionAnalyzer.dirtyRatio(of: [CGRect(x: 0, y: 0, width: 50, height: 20)], frameSize: CGSize(width: 100, height: 100)),
            0.1,
            accuracy: 0.0001
        )
        XCTAssertEqual(DirtyRegionAnalyzer.dirtyRatio(of: [], frameSize: .zero), 0)
    }
}
