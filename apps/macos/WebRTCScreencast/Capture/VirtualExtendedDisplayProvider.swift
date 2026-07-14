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
    static let displayName = "WebRTC Screencast Extended Display"
    static let removalCompanionName = "WebRTC Screencast Removal Companion"

    private let configuration: VirtualDisplayConfiguration
    private var display: CGVirtualDisplay?
    private var displaySerialNumber: UInt32?
    private(set) var displayID: CGDirectDisplayID?

    init(configuration: VirtualDisplayConfiguration = .extended1080p) {
        self.configuration = configuration
    }

    func start(timeout: Duration = .seconds(3)) async throws -> CGDirectDisplayID {
        if let displayID { return displayID }
        guard Self.privateAPIIsAvailable else { throw VirtualExtendedDisplayError.unsupported }

        let serialNumber = Self.makeSerialNumber()
        let display = try Self.makeDisplay(
            configuration: configuration,
            name: Self.displayName,
            serialNumber: serialNumber
        )

        self.display = display
        displaySerialNumber = serialNumber
        let identifier = display.displayID
        displayID = identifier
        do {
            try await waitForDisplay(identifier, online: true, timeout: timeout)
        } catch {
            do {
                try await stop(timeout: timeout)
            } catch {
                throw VirtualExtendedDisplayError.removalTimedOut
            }
            throw VirtualExtendedDisplayError.appearanceTimedOut
        }
        return identifier
    }

    func stop(timeout: Duration = .seconds(3)) async throws {
        guard display != nil else {
            displayID = nil
            displaySerialNumber = nil
            return
        }

        var removalPair: [CGVirtualDisplay] = {
            guard let display else { return [] }
            return [display]
        }()
        if let companion = try? Self.makeDisplay(
            configuration: configuration,
            name: Self.removalCompanionName,
            serialNumber: Self.makeSerialNumber(excluding: displaySerialNumber)
        ) {
            removalPair.append(companion)
            try? await waitForDisplay(companion.displayID, online: true, timeout: timeout)
        }

        let removedIDs = removalPair.map(\.displayID)
        displayID = nil
        displaySerialNumber = nil
        display = nil
        // The first CGVirtualDisplay removal in a process is known to time out
        // when performed alone. Releasing an online companion in the same
        // ownership operation follows Chromium's macOS test utility workaround.
        removalPair.removeAll(keepingCapacity: false)
        do {
            try await waitForDisplays(removedIDs, online: false, timeout: timeout)
        } catch {
            throw VirtualExtendedDisplayError.removalTimedOut
        }
    }

    static func makeDescriptor(
        configuration: VirtualDisplayConfiguration,
        name: String,
        serialNumber: UInt32
    ) -> CGVirtualDisplayDescriptor {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = .main
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(configuration.width)
        descriptor.maxPixelsHigh = UInt32(configuration.height)
        descriptor.sizeInMillimeters = CGSize(width: 508, height: 285.75)
        descriptor.vendorID = 0x0AFF
        descriptor.productID = 0x150
        descriptor.serialNum = serialNumber
        descriptor.terminationHandler = { _, _ in }
        return descriptor
    }

    private static func makeDisplay(
        configuration: VirtualDisplayConfiguration,
        name: String,
        serialNumber: UInt32
    ) throws -> CGVirtualDisplay {
        let descriptor = makeDescriptor(
            configuration: configuration,
            name: name,
            serialNumber: serialNumber
        )
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
        return display
    }

    private static func makeSerialNumber(excluding excluded: UInt32? = nil) -> UInt32 {
        var serialNumber = UInt32.random(in: 1...UInt32.max)
        while serialNumber == excluded {
            serialNumber = UInt32.random(in: 1...UInt32.max)
        }
        return serialNumber
    }

    private func waitForDisplay(
        _ identifier: CGDirectDisplayID,
        online expectedOnline: Bool,
        timeout: Duration
    ) async throws {
        try await waitForDisplays([identifier], online: expectedOnline, timeout: timeout)
    }

    private func waitForDisplays(
        _ identifiers: [CGDirectDisplayID],
        online expectedOnline: Bool,
        timeout: Duration
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let onlineDisplayIDs = Self.onlineDisplayIDs(),
               Self.displays(
                   identifiers,
                   matchExpectedOnlineState: expectedOnline,
                   onlineDisplayIDs: onlineDisplayIDs
               ) {
                return
            }
            // CGDisplayIsOnline returns -1 for an invalid display ID, which is
            // truthy in Swift. Membership in CGGetOnlineDisplayList avoids
            // misclassifying a successfully removed display as still online.
            try await Task.sleep(for: .milliseconds(100))
        }
        throw expectedOnline ? VirtualExtendedDisplayError.appearanceTimedOut : VirtualExtendedDisplayError.removalTimedOut
    }

    static func displays(
        _ identifiers: [CGDirectDisplayID],
        matchExpectedOnlineState expectedOnline: Bool,
        onlineDisplayIDs: Set<CGDirectDisplayID>
    ) -> Bool {
        identifiers.allSatisfy { onlineDisplayIDs.contains($0) == expectedOnline }
    }

    private static func onlineDisplayIDs() -> Set<CGDirectDisplayID>? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        var identifiers = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &identifiers, &count) == .success else { return nil }
        return Set(identifiers.prefix(Int(count)))
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
