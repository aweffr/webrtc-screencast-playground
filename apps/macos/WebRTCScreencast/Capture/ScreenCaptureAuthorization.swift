import CoreGraphics
import Foundation

enum ScreenCaptureAuthorizationError: Error, Equatable, LocalizedError {
    case denied

    var errorDescription: String? {
        switch self {
        case .denied:
            "Screen Recording permission is required"
        }
    }
}

enum ScreenCaptureAuthorization {
    static func ensureAuthorized(
        preflight: () -> Bool = { CGPreflightScreenCaptureAccess() },
        request: () -> Bool = { CGRequestScreenCaptureAccess() }
    ) throws {
        if preflight() { return }
        guard request() else { throw ScreenCaptureAuthorizationError.denied }
    }
}
