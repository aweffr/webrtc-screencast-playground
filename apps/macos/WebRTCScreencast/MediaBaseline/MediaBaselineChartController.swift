import AppKit
import CoreGraphics
import Darwin
import Foundation

enum MediaBaselineChartControllerError: Error, LocalizedError {
    case executableUnavailable
    case hostExited(Int32)
    case readinessTimedOut
    case screenNotFound(CGDirectDisplayID)

    var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            "The media baseline chart host executable is unavailable"
        case .hostExited(let status):
            "The media baseline chart host exited before becoming ready (status \(status))"
        case .readinessTimedOut:
            "The media baseline chart host did not become ready"
        case .screenNotFound(let displayID):
            "Virtual display \(displayID) is not available for the media baseline chart"
        }
    }
}

enum MediaBaselineChartHostOptionsError: Error, Equatable {
    case missingValue(String)
    case invalidValue(option: String, value: String)
}

struct MediaBaselineChartHostOptions: Equatable, Sendable {
    static let modeFlag = "--baseline-chart-host"

    let displayID: CGDirectDisplayID
    let directory: URL

    static func isRequested(_ arguments: [String]) -> Bool {
        arguments.contains(modeFlag)
    }

    static func parse(_ arguments: [String]) throws -> Self {
        var displayID: CGDirectDisplayID?
        var directory: URL?
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            if option == modeFlag {
                index += 1
                continue
            }
            guard option == "--display-id" || option == "--directory" else {
                index += 1
                continue
            }
            guard arguments.indices.contains(index + 1) else {
                throw MediaBaselineChartHostOptionsError.missingValue(option)
            }
            let value = arguments[index + 1]
            if option == "--display-id" {
                guard let parsed = CGDirectDisplayID(value), parsed != 0 else {
                    throw MediaBaselineChartHostOptionsError.invalidValue(option: option, value: value)
                }
                displayID = parsed
            } else {
                guard !value.isEmpty else {
                    throw MediaBaselineChartHostOptionsError.invalidValue(option: option, value: value)
                }
                directory = URL(filePath: value, directoryHint: .isDirectory)
            }
            index += 2
        }
        guard let displayID else {
            throw MediaBaselineChartHostOptionsError.missingValue("--display-id")
        }
        guard let directory else {
            throw MediaBaselineChartHostOptionsError.missingValue("--directory")
        }
        return Self(displayID: displayID, directory: directory)
    }
}

struct MediaBaselineChartEvent: Codable, Equatable, Sendable {
    let sequence: UInt32
    let committedMonotonicNs: UInt64
    let sourceReference: String?

    enum CodingKeys: String, CodingKey {
        case sequence
        case committedMonotonicNs = "committed_monotonic_ns"
        case sourceReference = "source_reference"
    }
}

@MainActor
final class MediaBaselineChartController {
    // Display capture did not composite a chart window owned by the capturing
    // process. The same app executable therefore hosts the chart in a child
    // process while keeping the public Sender/CLI contract unchanged.
    static let eventsName = "baseline-chart-events.jsonl"

    private let recorder: MetricsRecorder
    private let directory: URL
    private var process: Process?
    private var eventsImported = false
    private var eventsURL: URL { directory.appending(path: Self.eventsName) }

    init(recorder: MetricsRecorder, directory: URL) {
        self.recorder = recorder
        self.directory = directory
    }

    func start(displayID: CGDirectDisplayID, timeout: Duration = .seconds(3)) async throws {
        guard let executable = Bundle.main.executableURL else {
            throw MediaBaselineChartControllerError.executableUnavailable
        }
        if FileManager.default.fileExists(atPath: eventsURL.path) {
            try FileManager.default.removeItem(at: eventsURL)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            MediaBaselineChartHostOptions.modeFlag,
            "--display-id", String(displayID),
            "--directory", directory.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        self.process = process

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if !process.isRunning {
                self.process = nil
                throw MediaBaselineChartControllerError.hostExited(process.terminationStatus)
            }
            if let events = try? Self.loadEvents(from: eventsURL), !events.isEmpty {
                try await Task.sleep(for: .milliseconds(100))
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        await terminate(process)
        self.process = nil
        throw MediaBaselineChartControllerError.readinessTimedOut
    }

    func stop() async {
        if let process { await terminate(process) }
        process = nil
        guard !eventsImported else { return }
        eventsImported = true
        guard let events = try? Self.loadEvents(from: eventsURL) else { return }
        for event in events {
            var fields: [String: JSONValue] = [
                "sequence": .integer(Int(event.sequence)),
                "committed_monotonic_ns": .integer(Int(event.committedMonotonicNs)),
            ]
            if let sourceReference = event.sourceReference {
                fields["source_reference"] = .string(sourceReference)
            }
            try? await recorder.record(event: "baseline_marker_committed", fields: fields)
        }
    }

    private func terminate(_ process: Process) async {
        if process.isRunning { process.terminate() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while process.isRunning, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = clock.now.advanced(by: .seconds(1))
            while process.isRunning, clock.now < killDeadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        // Give WindowServer one compositor turn to remove the child window
        // before the owning CGVirtualDisplay is released.
        try? await Task.sleep(for: .milliseconds(100))
    }

    private static func loadEvents(from url: URL) throws -> [MediaBaselineChartEvent] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try data.split(separator: 0x0A).map { line in
            try decoder.decode(MediaBaselineChartEvent.self, from: Data(line))
        }
    }
}

@MainActor
enum MediaBaselineChartHost {
    static func run(options: MediaBaselineChartHostOptions) throws -> Never {
        let host = try Host(options: options)
        NSApplication.shared.setActivationPolicy(.accessory)
        host.start()
        withExtendedLifetime(host) { NSApplication.shared.run() }
        exit(EXIT_SUCCESS)
    }

    @MainActor
    private final class Host: NSObject {
        private let directory: URL
        private let eventsHandle: FileHandle
        private let window: NSWindow
        private let view: MediaBaselineChartView
        private var timer: Timer?
        private var sequence: UInt32 = 0

        init(options: MediaBaselineChartHostOptions) throws {
            guard let screen = NSScreen.screens.first(where: { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                    == options.displayID
            }) else {
                throw MediaBaselineChartControllerError.screenNotFound(options.displayID)
            }
            directory = options.directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let eventsURL = directory.appending(path: MediaBaselineChartController.eventsName)
            FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
            eventsHandle = try FileHandle(forWritingTo: eventsURL)
            view = MediaBaselineChartView(frame: CGRect(origin: .zero, size: screen.frame.size))
            window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            super.init()
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.level = .normal
            window.sharingType = .readOnly
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.contentView = view
            window.setFrame(screen.frame, display: true)
        }

        deinit { try? eventsHandle.close() }

        func start() {
            window.orderFrontRegardless()
            advance()
            timer = Timer.scheduledTimer(
                timeInterval: 0.5,
                target: self,
                selector: #selector(tick),
                userInfo: nil,
                repeats: true
            )
        }

        @objc private func tick() { advance() }

        private func advance() {
            sequence &+= 1
            let image = MediaBaselineChart.render(sequence: sequence)
            let committedNs = MediaBaselineClock.nowNs
            view.image = image.makeCGImage()
            view.needsDisplay = true
            view.displayIfNeeded()

            var sourceReference: String?
            if MediaBaselineLayout.qualitySampleSequences.contains(sequence), let png = image.pngData() {
                let name = String(format: "source-reference-%06u.png", sequence)
                try? png.write(to: directory.appending(path: name), options: .atomic)
                sourceReference = name
            }
            let event = MediaBaselineChartEvent(
                sequence: sequence,
                committedMonotonicNs: committedNs,
                sourceReference: sourceReference
            )
            guard var data = try? JSONEncoder().encode(event) else { return }
            data.append(0x0A)
            try? eventsHandle.write(contentsOf: data)
            try? eventsHandle.synchronize()
        }
    }
}

private final class MediaBaselineChartView: NSView {
    var image: CGImage? {
        didSet { layer?.contents = image }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .nearest
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
