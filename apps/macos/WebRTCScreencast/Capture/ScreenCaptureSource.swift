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
    let contentActivityMode: ContentActivityMode
    let clarityTransition: ContentActivityTransition
}

struct CaptureTelemetrySnapshot: Equatable, Sendable {
    let callbackFrames: UInt64
    let submittedFrames: UInt64
    let droppedFrames: UInt64
    let lastTimestampNs: Int64?
    let lastDirtyRectCount: Int?
    let lastDirtyRatio: Double?
    let gateState: FrameGateState
    let contentActivityMode: ContentActivityMode
    let lastDamageMonotonicNs: UInt64?
    let quietDeadlineMonotonicNs: UInt64?
    let lastActiveTransitionMonotonicNs: UInt64?
    let lastStaticTransitionMonotonicNs: UInt64?
    let activeTransitionCount: UInt64
    let staticTransitionCount: UInt64
    let syntheticClarityRefreshes: UInt64
}

protocol ScreenCaptureFrameSink: AnyObject {
    /// Called synchronously on the serial capture queue. Implementations must not block.
    /// Returns whether an attached clarity transition reached the WebRTC tuning boundary.
    func screenCaptureSource(_ source: ScreenCaptureSource, didCapture frame: CapturedScreenFrame) -> Bool
    func screenCaptureSource(_ source: ScreenCaptureSource, didStopWithError error: Error)
}

struct ClarityTransitionLatch: Sendable {
    private(set) var pending: ContentActivityTransition = .none

    mutating func update(with detected: ContentActivityTransition) -> ContentActivityTransition {
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

private struct CachedScreenFrame {
    let pixelBuffer: CVPixelBuffer
    let contentRect: CGRect
    let scaleFactor: Double
}

final class ScreenCaptureSource: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let captureQueue = DispatchQueue(
        label: "cn.aweffr.WebRTCScreencast.capture",
        qos: .userInteractive
    )
    private weak var sink: ScreenCaptureFrameSink?
    private var stream: SCStream?
    private var frameGate = FrameGate()
    private var damageIdleDetector = DamageIdleDetector()
    private var damageIdleGeneration: UInt64 = 0
    private var scheduledQuietGeneration: UInt64?
    private var cachedScreenFrame: CachedScreenFrame?
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
    private var lastContentActivityMode: ContentActivityMode = .active
    private var lastDamageMonotonicNs: UInt64?
    private var quietDeadlineMonotonicNs: UInt64?
    private var lastActiveTransitionMonotonicNs: UInt64?
    private var lastStaticTransitionMonotonicNs: UInt64?
    private var activeTransitionCount: UInt64 = 0
    private var staticTransitionCount: UInt64 = 0
    private var syntheticClarityRefreshes: UInt64 = 0

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
        if staticClarityEnabled {
            damageIdleGeneration = damageIdleDetector.start()
        }
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
            if staticClarityEnabled {
                damageIdleDetector.stop()
                staticClarityEnabled = false
            }
            throw error
        }
    }

    func stop() async throws {
        guard let stream else { return }
        self.stream = nil
        defer { try? stream.removeStreamOutput(self, type: .screen) }
        try await stream.stopCapture()
        captureQueue.sync {
            frameGate = FrameGate()
            damageIdleDetector.stop()
            scheduledQuietGeneration = nil
            cachedScreenFrame = nil
            clarityTransitionLatch = ClarityTransitionLatch()
            staticClarityEnabled = false
        }
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
        cachedScreenFrame = CachedScreenFrame(
            pixelBuffer: pixelBuffer,
            contentRect: metadata.contentRect,
            scaleFactor: metadata.scaleFactor
        )
        var activityDecision: DamageIdleDecision?
        if staticClarityEnabled,
           ScreenDamageClassifier.hasDamage(
               status: metadata.status,
               dirtyRects: metadata.dirtyRects
           ) {
            let detected = damageIdleDetector.observeDamage(at: callbackMonotonicNs)
            activityDecision = detected
            recordActivityDecision(detected, at: callbackMonotonicNs)
            if let deadline = detected.nextQuietDeadlineMonotonicNs {
                scheduleQuietCheckIfNeeded(
                    at: deadline,
                    generation: damageIdleGeneration
                )
            }
        }
        let clarityTransition = clarityTransitionLatch.update(
            with: activityDecision?.transition ?? .none
        )
        let shouldSubmit = decision.shouldSubmit || clarityTransition != .none
        telemetryLock.withLock {
            callbackFrames += 1
            lastTimestampNs = scaledTime.value
            lastDirtyRectCount = dirtyRectCount
            lastDirtyRatio = dirtyRatio
            lastGateState = decision.state
            if !shouldSubmit { droppedFrames += 1 }
        }
        guard shouldSubmit else { return }

        let frameAccepted = sink?.screenCaptureSource(
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
                contentActivityMode: activityDecision?.mode ?? damageIdleDetector.mode,
                clarityTransition: clarityTransition
            )
        ) ?? false
        if clarityTransition != .none {
            clarityTransitionLatch.recordApplied(frameAccepted)
        }
        telemetryLock.withLock {
            if frameAccepted { submittedFrames += 1 }
            else { droppedFrames += 1 }
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
                contentActivityMode: lastContentActivityMode,
                lastDamageMonotonicNs: lastDamageMonotonicNs,
                quietDeadlineMonotonicNs: quietDeadlineMonotonicNs,
                lastActiveTransitionMonotonicNs: lastActiveTransitionMonotonicNs,
                lastStaticTransitionMonotonicNs: lastStaticTransitionMonotonicNs,
                activeTransitionCount: activeTransitionCount,
                staticTransitionCount: staticTransitionCount,
                syntheticClarityRefreshes: syntheticClarityRefreshes
            )
        }
    }

    private func scheduleQuietCheckIfNeeded(at deadline: UInt64, generation: UInt64) {
        guard scheduledQuietGeneration == nil else { return }
        scheduledQuietGeneration = generation
        let now = MediaBaselineClock.nowNs
        let delayNs = deadline > now ? deadline - now : 0
        captureQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(delayNs))) { [weak self] in
            self?.handleQuietCheck(generation: generation)
        }
    }

    private func handleQuietCheck(generation: UInt64) {
        guard scheduledQuietGeneration == generation else { return }
        scheduledQuietGeneration = nil
        guard staticClarityEnabled else { return }

        let now = MediaBaselineClock.nowNs
        let decision = damageIdleDetector.settleIfDue(
            at: now,
            generation: generation
        )
        recordActivityDecision(decision, at: now)
        if let nextDeadline = decision.nextQuietDeadlineMonotonicNs {
            scheduleQuietCheckIfNeeded(at: nextDeadline, generation: generation)
            return
        }
        guard decision.transition == .enterStaticClarity,
              let cachedScreenFrame
        else { return }

        let transition = clarityTransitionLatch.update(with: decision.transition)
        let accepted = sink?.screenCaptureSource(
            self,
            didCapture: CapturedScreenFrame(
                pixelBuffer: cachedScreenFrame.pixelBuffer,
                callbackMonotonicNs: now,
                timestampNs: Int64(now),
                status: .complete,
                contentRect: cachedScreenFrame.contentRect,
                scaleFactor: cachedScreenFrame.scaleFactor,
                dirtyRectCount: 0,
                dirtyRatio: 0,
                gateState: lastGateState,
                contentActivityMode: decision.mode,
                clarityTransition: transition
            )
        ) ?? false
        clarityTransitionLatch.recordApplied(accepted)
        telemetryLock.withLock {
            lastTimestampNs = Int64(now)
            if accepted {
                submittedFrames += 1
                syntheticClarityRefreshes += 1
            } else {
                droppedFrames += 1
            }
        }
    }

    private func recordActivityDecision(_ decision: DamageIdleDecision, at monotonicNs: UInt64) {
        telemetryLock.withLock {
            lastContentActivityMode = decision.mode
            lastDamageMonotonicNs = decision.lastDamageMonotonicNs
            quietDeadlineMonotonicNs = decision.quietDeadlineMonotonicNs
            switch decision.transition {
            case .none:
                break
            case .enterStaticClarity:
                lastStaticTransitionMonotonicNs = monotonicNs
                staticTransitionCount += 1
            case .exitStaticClarity:
                lastActiveTransitionMonotonicNs = monotonicNs
                activeTransitionCount += 1
            }
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
