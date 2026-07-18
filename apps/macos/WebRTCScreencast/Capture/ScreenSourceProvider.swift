import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

struct VirtualDisplayConfiguration: Equatable, Sendable {
    let width: Int
    let height: Int
    let refreshRate: Double
    let scale: Int
    let hiDPI: Bool

    static let extended1080p = VirtualDisplayConfiguration(
        width: 1_920,
        height: 1_080,
        refreshRate: 60,
        scale: 1,
        hiDPI: false
    )
}

enum ScreenCaptureConfigurationError: Error, Equatable {
    case invalidSourceSize
    case receiverExclusionRequiresDirectMainDisplayBaseline
}

struct ScreenCaptureConfigurationValues: Equatable, Sendable {
    static let outputSize = CGSize(width: 1_920, height: 1_080)

    let width: Int
    let height: Int
    let pixelFormat: OSType
    let minimumFrameInterval: CMTime
    let queueDepth: Int
    let showsCursor: Bool
    let preservesAspectRatio: Bool
    let destinationRect: CGRect
    let excludedReceiverPID: pid_t?

    static func make(
        source: CaptureSourceKind,
        sourcePixelSize: CGSize,
        iceProfile: ICEProfile,
        excludedReceiverPID: pid_t?
    ) throws -> Self {
        guard sourcePixelSize.width > 0, sourcePixelSize.height > 0 else {
            throw ScreenCaptureConfigurationError.invalidSourceSize
        }
        if excludedReceiverPID != nil,
           (source != .mainDisplayMirror || iceProfile != .directBaseline) {
            throw ScreenCaptureConfigurationError.receiverExclusionRequiresDirectMainDisplayBaseline
        }

        let destinationRect: CGRect
        switch source {
        case .mainDisplayMirror:
            destinationRect = try LetterboxGeometry.destinationRect(
                source: sourcePixelSize,
                canvas: outputSize
            )
        case .virtualExtendedDisplay:
            destinationRect = CGRect(origin: .zero, size: outputSize)
        }

        return ScreenCaptureConfigurationValues(
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            minimumFrameInterval: CMTime(value: 1, timescale: 15),
            queueDepth: 3,
            showsCursor: true,
            preservesAspectRatio: true,
            destinationRect: destinationRect,
            excludedReceiverPID: excludedReceiverPID
        )
    }
}

enum ScreenSourceProviderError: Error, Equatable, LocalizedError {
    case displayNotFound(CGDirectDisplayID)
    case excludedApplicationNotFound(pid_t)

    var errorDescription: String? {
        switch self {
        case .displayNotFound(let displayID):
            "Display \(displayID) is not available to ScreenCaptureKit"
        case .excludedApplicationNotFound(let processID):
            "Receiver process \(processID) is not available to ScreenCaptureKit"
        }
    }
}

struct ResolvedScreenSource {
    let filter: SCContentFilter
    let configuration: ScreenCaptureConfigurationValues
}

enum ScreenSourceProvider {
    static func resolve(
        displayID: CGDirectDisplayID,
        source: CaptureSourceKind,
        iceProfile: ICEProfile,
        excludedReceiverPID: pid_t?
    ) async throws -> ResolvedScreenSource {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenSourceProviderError.displayNotFound(displayID)
        }
        let configuration = try ScreenCaptureConfigurationValues.make(
            source: source,
            sourcePixelSize: CGSize(width: display.width, height: display.height),
            iceProfile: iceProfile,
            excludedReceiverPID: excludedReceiverPID
        )
        let excludedApplications: [SCRunningApplication]
        if let excludedReceiverPID {
            guard let application = content.applications.first(where: { $0.processID == excludedReceiverPID }) else {
                throw ScreenSourceProviderError.excludedApplicationNotFound(excludedReceiverPID)
            }
            excludedApplications = [application]
        } else {
            excludedApplications = []
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
        return ResolvedScreenSource(filter: filter, configuration: configuration)
    }
}

extension ScreenCaptureConfigurationValues {
    func makeStreamConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = pixelFormat
        configuration.minimumFrameInterval = minimumFrameInterval
        configuration.queueDepth = queueDepth
        configuration.showsCursor = showsCursor
        configuration.preservesAspectRatio = preservesAspectRatio
        configuration.scalesToFit = true
        configuration.captureResolution = .nominal
        configuration.destinationRect = destinationRect
        configuration.backgroundColor = CGColor.black
        configuration.capturesAudio = false
        return configuration
    }
}
