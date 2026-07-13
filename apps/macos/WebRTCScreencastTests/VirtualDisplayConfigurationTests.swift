import XCTest
@testable import WebRTCScreencast

final class VirtualDisplayConfigurationTests: XCTestCase {
    func testExtendedDisplayIsExactly1080pOneXAtSixtyHertz() {
        let configuration = VirtualDisplayConfiguration.extended1080p

        XCTAssertEqual(configuration.width, 1_920)
        XCTAssertEqual(configuration.height, 1_080)
        XCTAssertEqual(configuration.refreshRate, 60)
        XCTAssertEqual(configuration.scale, 1)
        XCTAssertFalse(configuration.hiDPI)
    }
}
