import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

struct CapturedScreenFrame {
    let pixelBuffer: CVPixelBuffer
    let timestampNs: Int64
    let status: SCFrameStatus
    let contentRect: CGRect
    let scaleFactor: Double
    let dirtyRectCount: Int
    let dirtyRatio: Double
    let gateState: FrameGateState
}

struct CaptureTelemetrySnapshot: Equatable, Sendable {
    let callbackFrames: UInt64
    let submittedFrames: UInt64
    let droppedFrames: UInt64
    let lastTimestampNs: Int64?
    let lastDirtyRectCount: Int?
    let lastDirtyRatio: Double?
    let gateState: FrameGateState
}

protocol ScreenCaptureFrameSink: AnyObject {
    /// Called synchronously on the serial capture queue. Implementations must not block.
    func screenCaptureSource(_ source: ScreenCaptureSource, didCapture frame: CapturedScreenFrame)
    func screenCaptureSource(_ source: ScreenCaptureSource, didStopWithError error: Error)
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
    private let telemetryLock = NSLock()
    private var callbackFrames: UInt64 = 0
    private var submittedFrames: UInt64 = 0
    private var droppedFrames: UInt64 = 0
    private var lastTimestampNs: Int64?
    private var lastDirtyRectCount: Int?
    private var lastDirtyRatio: Double?
    private var lastGateState: FrameGateState = .idle

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
        let resolved = try await ScreenSourceProvider.resolve(
            displayID: displayID,
            source: source,
            iceProfile: iceProfile,
            excludedReceiverPID: excludedReceiverPID
        )
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
        try await stream.stopCapture()
        frameGate = FrameGate()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
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
        if metadata.status == .started {
            dirtyRatio = 1
        } else {
            dirtyRatio = DirtyRegionAnalyzer.dirtyRatio(
                of: metadata.dirtyRects,
                frameSize: CGSize(
                    width: CVPixelBufferGetWidth(pixelBuffer),
                    height: CVPixelBufferGetHeight(pixelBuffer)
                )
            )
        }
        let decision = frameGate.evaluate(
            dirtyRatio: dirtyRatio,
            timestamp: .nanoseconds(scaledTime.value)
        )
        telemetryLock.withLock {
            callbackFrames += 1
            lastTimestampNs = scaledTime.value
            lastDirtyRectCount = metadata.dirtyRects.count
            lastDirtyRatio = dirtyRatio
            lastGateState = decision.state
            if decision.shouldSubmit { submittedFrames += 1 }
            else { droppedFrames += 1 }
        }
        guard decision.shouldSubmit else { return }

        sink?.screenCaptureSource(
            self,
            didCapture: CapturedScreenFrame(
                pixelBuffer: pixelBuffer,
                timestampNs: scaledTime.value,
                status: metadata.status,
                contentRect: metadata.contentRect,
                scaleFactor: metadata.scaleFactor,
                dirtyRectCount: metadata.dirtyRects.count,
                dirtyRatio: dirtyRatio,
                gateState: decision.state
            )
        )
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
                gateState: lastGateState
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

        let dirtyValues = attachment[.dirtyRects] as? [NSValue] ?? []
        let contentRect = (attachment[.contentRect] as? NSValue)?.rectValue ?? .zero
        let scaleFactor = (attachment[.scaleFactor] as? NSNumber)?.doubleValue ?? 1
        return FrameMetadata(
            status: status,
            dirtyRects: dirtyValues.map(\.rectValue),
            contentRect: contentRect,
            scaleFactor: scaleFactor
        )
    }
}

private struct FrameMetadata {
    let status: SCFrameStatus
    let dirtyRects: [CGRect]
    let contentRect: CGRect
    let scaleFactor: Double
}
