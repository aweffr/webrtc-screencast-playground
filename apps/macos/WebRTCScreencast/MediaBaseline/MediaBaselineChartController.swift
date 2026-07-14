import AppKit
import CoreGraphics
import Foundation

enum MediaBaselineChartControllerError: Error, LocalizedError {
    case screenNotFound(CGDirectDisplayID)

    var errorDescription: String? {
        switch self {
        case .screenNotFound(let displayID):
            "Virtual display \(displayID) is not available for the media baseline chart"
        }
    }
}

@MainActor
final class MediaBaselineChartController {
    private let recorder: MetricsRecorder
    private let directory: URL
    private var window: NSWindow?
    private var task: Task<Void, Never>?
    private var sequence: UInt32 = 0

    init(recorder: MetricsRecorder, directory: URL) {
        self.recorder = recorder
        self.directory = directory
    }

    func start(displayID: CGDirectDisplayID) throws {
        guard let screen = NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { throw MediaBaselineChartControllerError.screenNotFound(displayID) }

        let view = MediaBaselineChartView(frame: CGRect(origin: .zero, size: screen.frame.size))
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = view
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        self.window = window

        advance(view: view)
        task = Task { [weak self, weak view] in
            let clock = ContinuousClock()
            var deadline = clock.now.advanced(by: .milliseconds(500))
            while !Task.isCancelled {
                do { try await clock.sleep(until: deadline) }
                catch { return }
                guard let self, let view, !Task.isCancelled else { return }
                self.advance(view: view)
                deadline = deadline.advanced(by: .milliseconds(500))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        window?.orderOut(nil)
        window = nil
    }

    private func advance(view: MediaBaselineChartView) {
        sequence &+= 1
        let image = MediaBaselineChart.render(sequence: sequence)
        let committedNs = MediaBaselineClock.nowNs
        view.image = image.makeCGImage()
        view.needsDisplay = true
        view.displayIfNeeded()

        var fields: [String: JSONValue] = [
            "sequence": .integer(Int(sequence)),
            "committed_monotonic_ns": .integer(Int(committedNs)),
        ]
        if MediaBaselineLayout.qualitySampleSequences.contains(sequence),
           let png = image.pngData() {
            let name = String(format: "source-reference-%06u.png", sequence)
            let url = directory.appending(path: name)
            try? png.write(to: url, options: .atomic)
            fields["source_reference"] = .string(name)
        }
        Task { try? await recorder.record(event: "baseline_marker_committed", fields: fields) }
    }
}

private final class MediaBaselineChartView: NSView {
    var image: CGImage?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .none
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: bounds)
        context.restoreGState()
    }
}
