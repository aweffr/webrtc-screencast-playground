import XCTest
@testable import WebRTCScreencast

final class ScreenCaptureAuthorizationTests: XCTestCase {
    func testAlreadyGrantedDoesNotRequestAgain() throws {
        var requestCalls = 0

        try ScreenCaptureAuthorization.ensureAuthorized(
            preflight: { true },
            request: { requestCalls += 1; return false }
        )

        XCTAssertEqual(requestCalls, 0)
    }

    func testFirstRequestCanGrantAccess() throws {
        XCTAssertNoThrow(try ScreenCaptureAuthorization.ensureAuthorized(
            preflight: { false },
            request: { true }
        ))
    }

    func testDeniedRequestProducesStableError() {
        XCTAssertThrowsError(try ScreenCaptureAuthorization.ensureAuthorized(
            preflight: { false },
            request: { false }
        )) { error in
            XCTAssertEqual(error as? ScreenCaptureAuthorizationError, .denied)
        }
    }
}
