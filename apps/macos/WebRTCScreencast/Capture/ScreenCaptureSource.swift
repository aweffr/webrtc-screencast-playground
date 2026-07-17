import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

struct CapturedScreenFrame {
    let pixelBuffer: CVPixelBuffer
    let callbackMonotonicNs: UInt64
    let timestampNs: Int64
    let status: SCFrameStatus
    let contentRect: CGRect
    let scaleFactor: Double
    let dirtyRectCount: Int
    let dirtyRatio: Double
    let gateState: FrameGateState
    let visualStabilityMode: VisualStabilityMode
    let visualChangedSampleRatio: Double?
    let clarityTransition: VisualStabilityTransition
}

struct CaptureTelemetrySnapshot: Equatable, Sendable {
    let callbackFrames: UInt64
    let submittedFrames: UInt64
    let droppedFrames: UInt64
    let lastTimestampNs: Int64?
    let lastDirtyRectCount: Int?
    let lastDirtyRatio: Double?
    let gateState: FrameGateState
    let visualStabilityMode: VisualStabilityMode
    let lastVisualChangedSampleRatio: Double?
    let clarityRefreshRequests: UInt64
}

protocol ScreenCaptureFrameSink: AnyObject {
    /// Called synchronously on the serial capture queue. Implementations must not block.
    /// Returns whether an attached clarity transition reached the WebRTC tuning boundary.
    func screenCaptureSource(_ source: ScreenCaptureSource, didCapture frame: CapturedScreenFrame) -> Bool
    func screenCaptureSource(_ source: ScreenCaptureSource, didStopWithError error: Error)
}

struct ClarityTransitionLatch: Sendable {
    private(set) var pending: VisualStabilityTransition = .none

    mutating func update(with detected: VisualStabilityTransition) -> VisualStabilityTransition {
        if detected != .none { pending = detected }
        return pending
    }

    mutating func recordApplied(_ applied: Bool) {
        if applied { pending = .none }
    }
}

enum ScreenCaptureSourceError: Error {
    case alreadyRunning
    case invalidFrameTimestamp
}

final class ScreenCaptureSource: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let captureQueue = DispatchQueue(
        label: "cn.aweffr.WebRTCScreencast.capture",
        qos: .userInteractive
    )
    private weak var sink: ScreenCaptureFrameSink?
    private var stream: SCStream?
    private var frameGate = FrameGate()
    private var visualStabilityDetector = VisualStabilityDetector()
    private var clarityTransitionLatch = ClarityTransitionLatch()
    private var staticClarityEnabled = false
    private let telemetryLock = NSLock()
    private var callbackFrames: UInt64 = 0
    private var submittedFrames: UInt64 = 0
    private var droppedFrames: UInt64 = 0
    private var lastTimestampNs: Int64?
    private var lastDirtyRectCount: Int?
    private var lastDirtyRatio: Double?
    private var lastGateState: FrameGateState = .idle
    private var lastVisualStabilityMode: VisualStabilityMode = .motion
    private var lastVisualChangedSampleRatio: Double?
    private var clarityRefreshRequests: UInt64 = 0

    init(sink: ScreenCaptureFrameSink) {
        self.sink = sink
    }

    func start(
        displayID: CGDirectDisplayID,
        source: CaptureSourceKind,
        iceProfile: ICEProfile,
        excludedReceiverPID: pid_t?
    ) async throws {
        guard stream == nil else { throw ScreenCaptureSourceError.alreadyRunning }
        try ScreenCaptureAuthorization.ensureAuthorized()
        let resolved = try await ScreenSourceProvider.resolve(
            displayID: displayID,
            source: source,
            iceProfile: iceProfile,
            excludedReceiverPID: excludedReceiverPID
        )
        staticClarityEnabled = source.enablesStaticClarity
        let stream = SCStream(
            filter: resolved.filter,
            configuration: resolved.configuration.makeStreamConfiguration(),
            delegate: self
        )
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            self.stream = nil
            throw error
        }
    }

    func stop() async throws {
        guard let stream else { return }
        self.stream = nil
        defer { try? stream.removeStreamOutput(self, type: .screen) }
        try await stream.stopCapture()
        frameGate = FrameGate()
        visualStabilityDetector = VisualStabilityDetector()
        clarityTransitionLatch = ClarityTransitionLatch()
        staticClarityEnabled = false
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        let callbackMonotonicNs = MediaBaselineClock.nowNs
        guard outputType == .screen,
              let metadata = frameMetadata(from: sampleBuffer),
              metadata.status == .complete || metadata.status == .started,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isNumeric else { return }
        let scaledTime = CMTimeConvertScale(
            presentationTime,
            timescale: 1_000_000_000,
            method: .default
        )
        let dirtyRatio: Double
        if metadata.status == .started || metadata.dirtyRects == nil {
            dirtyRatio = 1
        } else {
            dirtyRatio = DirtyRegionAnalyzer.dirtyRatio(
                of: metadata.dirtyRects ?? [],
                frameSize: CGSize(
                    width: CVPixelBufferGetWidth(pixelBuffer),
                    height: CVPixelBufferGetHeight(pixelBuffer)
                )
            )
        }
        let dirtyRectCount = metadata.dirtyRects?.count ?? 0
        let decision = frameGate.evaluate(
            dirtyRatio: dirtyRatio,
            timestamp: .nanoseconds(scaledTime.value)
        )
        let visualDecision: VisualStabilityDecision?
        if staticClarityEnabled,
           let samples = LumaFrameSampler.sample(pixelBuffer: pixelBuffer) {
            visualDecision = visualStabilityDetector.evaluate(
                samples: samples,
                timestamp: .nanoseconds(scaledTime.value)
            )
        } else {
            visualDecision = nil
        }
        let clarityTransition = clarityTransitionLatch.update(
            with: visualDecision?.transition ?? .none
        )
        let shouldSubmit = decision.shouldSubmit || clarityTransition != .none
        telemetryLock.withLock {
            callbackFrames += 1
            lastTimestampNs = scaledTime.value
            lastDirtyRectCount = dirtyRectCount
            lastDirtyRatio = dirtyRatio
            lastGateState = decision.state
            if let visualDecision {
                lastVisualStabilityMode = visualDecision.mode
                lastVisualChangedSampleRatio = visualDecision.changedSampleRatio
                if visualDecision.transition == .enterStaticClarity {
                    clarityRefreshRequests += 1
                }
            }
            if shouldSubmit { submittedFrames += 1 }
            else { droppedFrames += 1 }
        }
        guard shouldSubmit else { return }

        let transitionApplied = sink?.screenCaptureSource(
            self,
            didCapture: CapturedScreenFrame(
                pixelBuffer: pixelBuffer,
                callbackMonotonicNs: callbackMonotonicNs,
                timestampNs: scaledTime.value,
                status: metadata.status,
                contentRect: metadata.contentRect,
                scaleFactor: metadata.scaleFactor,
                dirtyRectCount: dirtyRectCount,
                dirtyRatio: dirtyRatio,
                gateState: decision.state,
                visualStabilityMode: visualDecision?.mode ?? .motion,
                visualChangedSampleRatio: visualDecision?.changedSampleRatio,
                clarityTransition: clarityTransition
            )
        ) ?? false
        if clarityTransition != .none {
            clarityTransitionLatch.recordApplied(transitionApplied)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        sink?.screenCaptureSource(self, didStopWithError: error)
    }

    func telemetrySnapshot() -> CaptureTelemetrySnapshot {
        telemetryLock.withLock {
            CaptureTelemetrySnapshot(
                callbackFrames: callbackFrames,
                submittedFrames: submittedFrames,
                droppedFrames: droppedFrames,
                lastTimestampNs: lastTimestampNs,
                lastDirtyRectCount: lastDirtyRectCount,
                lastDirtyRatio: lastDirtyRatio,
                gateState: lastGateState,
                visualStabilityMode: lastVisualStabilityMode,
                lastVisualChangedSampleRatio: lastVisualChangedSampleRatio,
                clarityRefreshRequests: clarityRefreshRequests
            )
        }
    }

    private func frameMetadata(from sampleBuffer: CMSampleBuffer) -> FrameMetadata? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let attachment = attachments.first,
        let statusNumber = attachment[.status] as? NSNumber,
        let status = SCFrameStatus(rawValue: statusNumber.intValue)
        else {
            return nil
        }

        let contentRect = (attachment[.contentRect] as? NSValue)?.rectValue ?? .zero
        let scaleFactor = (attachment[.scaleFactor] as? NSNumber)?.doubleValue ?? 1
        return FrameMetadata(
            status: status,
            dirtyRects: DirtyRectMetadataParser.parse(attachment[.dirtyRects]),
            contentRect: contentRect,
            scaleFactor: scaleFactor
        )
    }
}

private struct FrameMetadata {
    let status: SCFrameStatus
    let dirtyRects: [CGRect]?
    let contentRect: CGRect
    let scaleFactor: Double
}

enum DirtyRectMetadataParser {
    static func parse(_ rawValue: Any?) -> [CGRect]? {
        guard let values = rawValue as? NSArray else { return nil }
        var rects: [CGRect] = []
        rects.reserveCapacity(values.count)
        for value in values {
            guard let rect = parseElement(value) else { return nil }
            rects.append(rect)
        }
        return rects
    }

    private static func parseElement(_ value: Any) -> CGRect? {
        if let value = value as? NSValue {
            return value.rectValue
        }
        guard let dictionary = value as? NSDictionary,
              let x = number(in: dictionary, key: "X"),
              let y = number(in: dictionary, key: "Y"),
              let width = number(in: dictionary, key: "Width"),
              let height = number(in: dictionary, key: "Height"),
              x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width >= 0, height >= 0
        else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func number(in dictionary: NSDictionary, key: String) -> CGFloat? {
        (dictionary.object(forKey: key) as? NSNumber).map { CGFloat(truncating: $0) }
    }
}
