import Foundation
import XCTest
@testable import WebRTCScreencast

final class DisplaySleepActivityTests: XCTestCase {
    @MainActor
    func testActivityPreventsIdleDisplaySleepAndHasIdempotentLifecycle() {
        var beginCalls: [(ProcessInfo.ActivityOptions, String)] = []
        var endedTokens: [NSObjectProtocol] = []
        let expectedToken = NSObject()
        let activity = DisplaySleepActivity(
            beginActivity: { options, reason in
                beginCalls.append((options, reason))
                return expectedToken
            },
            endActivity: { endedTokens.append($0) }
        )

        activity.start()
        activity.start()
        activity.stop()
        activity.stop()

        XCTAssertEqual(beginCalls.count, 1)
        XCTAssertTrue(beginCalls[0].0.contains(.idleDisplaySleepDisabled))
        XCTAssertTrue(beginCalls[0].0.contains(.idleSystemSleepDisabled))
        XCTAssertFalse(beginCalls[0].1.isEmpty)
        XCTAssertEqual(endedTokens.count, 1)
        XCTAssertTrue(endedTokens[0] === expectedToken)
    }
}
