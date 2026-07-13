import AppKit
import CoreGraphics
import Foundation

enum VirtualExtendedDisplayError: Error, Equatable {
    case unsupported
    case creationFailed
    case settingsRejected
    case appearanceTimedOut
    case removalTimedOut
}

@MainActor
final class VirtualExtendedDisplayProvider {
    private let configuration: VirtualDisplayConfiguration
    private var display: CGVirtualDisplay?
    private(set) var displayID: CGDirectDisplayID?

    init(configuration: VirtualDisplayConfiguration = .extended1080p) {
        self.configuration = configuration
    }

    func start(timeout: Duration = .seconds(3)) async throws -> CGDirectDisplayID {
        if let displayID { return displayID }
        guard Self.privateAPIIsAvailable else { throw VirtualExtendedDisplayError.unsupported }

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = .main
        descriptor.name = "WebRTC Screencast Extended Display"
        descriptor.maxPixelsWide = UInt32(configuration.width)
        descriptor.maxPixelsHigh = UInt32(configuration.height)
        descriptor.sizeInMillimeters = CGSize(width: 508, height: 285.75)
        descriptor.vendorID = 0x0AFF
        descriptor.productID = 0x150
        descriptor.serialNum = UInt32.random(in: 1...UInt32.max)
        descriptor.terminationHandler = { _, _ in }

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            throw VirtualExtendedDisplayError.creationFailed
        }
        let mode = CGVirtualDisplayMode(
            width: UInt(configuration.width),
            height: UInt(configuration.height),
            refreshRate: configuration.refreshRate
        )
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = configuration.hiDPI ? 1 : 0
        settings.modes = [mode]
        guard display.apply(settings) else {
            throw VirtualExtendedDisplayError.settingsRejected
        }

        self.display = display
        let identifier = display.displayID
        do {
            try await waitForDisplay(identifier, online: true, timeout: timeout)
        } catch {
            self.display = nil
            throw VirtualExtendedDisplayError.appearanceTimedOut
        }
        displayID = identifier
        return identifier
    }

    func stop(timeout: Duration = .seconds(3)) async throws {
        guard let identifier = displayID ?? display?.displayID else { return }
        displayID = nil
        display = nil
        do {
            try await waitForDisplay(identifier, online: false, timeout: timeout)
        } catch {
            throw VirtualExtendedDisplayError.removalTimedOut
        }
    }

    private func waitForDisplay(
        _ identifier: CGDirectDisplayID,
        online expectedOnline: Bool,
        timeout: Duration
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let isOnline = CGDisplayIsOnline(identifier) != 0
            if isOnline == expectedOnline { return }
            // WindowServer updates the online display list when AppKit posts
            // didChangeScreenParametersNotification. Polling that authoritative list
            // also covers a notification delivered between apply() and this waiter.
            try await Task.sleep(for: .milliseconds(100))
        }
        throw expectedOnline ? VirtualExtendedDisplayError.appearanceTimedOut : VirtualExtendedDisplayError.removalTimedOut
    }

    private static var privateAPIIsAvailable: Bool {
        [
            "CGVirtualDisplayDescriptor",
            "CGVirtualDisplay",
            "CGVirtualDisplaySettings",
            "CGVirtualDisplayMode",
        ].allSatisfy { NSClassFromString($0) != nil }
    }
}
