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

    @MainActor
    func testRemovalCompanionUsesMatchingBoundsAndDistinctIdentity() {
        let configuration = VirtualDisplayConfiguration.extended1080p
        let owned = VirtualExtendedDisplayProvider.makeDescriptor(
            configuration: configuration,
            name: "WebRTC Screencast Extended Display",
            serialNumber: 101
        )
        let companion = VirtualExtendedDisplayProvider.makeDescriptor(
            configuration: configuration,
            name: "WebRTC Screencast Removal Companion",
            serialNumber: 202
        )

        XCTAssertEqual(owned.maxPixelsWide, 1_920)
        XCTAssertEqual(owned.maxPixelsHigh, 1_080)
        XCTAssertEqual(companion.maxPixelsWide, owned.maxPixelsWide)
        XCTAssertEqual(companion.maxPixelsHigh, owned.maxPixelsHigh)
        XCTAssertEqual(companion.vendorID, owned.vendorID)
        XCTAssertEqual(companion.productID, owned.productID)
        XCTAssertNotEqual(companion.serialNum, owned.serialNum)
        XCTAssertNotEqual(companion.name, owned.name)
    }

    @MainActor
    func testRemovalTreatsIDsAbsentFromOnlineListAsOffline() {
        XCTAssertTrue(VirtualExtendedDisplayProvider.displays(
            [8, 9],
            matchExpectedOnlineState: false,
            onlineDisplayIDs: [1]
        ))
        XCTAssertFalse(VirtualExtendedDisplayProvider.displays(
            [8, 9],
            matchExpectedOnlineState: false,
            onlineDisplayIDs: [1, 8]
        ))
    }
}
