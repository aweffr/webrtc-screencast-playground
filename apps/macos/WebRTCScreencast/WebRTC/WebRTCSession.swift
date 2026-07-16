import CoreVideo
import Foundation
@preconcurrency import WebRTC

enum WebRTCSessionError: Error {
    case factoryCreationFailed
    case peerConnectionCreationFailed
    case transceiverCreationFailed
    case missingSessionDescription
    case unexpectedRemoteVideoTrack
    case wrongRole
}

protocol WebRTCSessionDelegate: AnyObject {
    func webRTCSession(_ session: WebRTCSession, didGenerate candidate: RTCIceCandidate)
    func webRTCSessionDidCompleteICEGathering(_ session: WebRTCSession)
    func webRTCSession(_ session: WebRTCSession, didChange state: RTCPeerConnectionState)
    func webRTCSession(_ session: WebRTCSession, didReceiveRemoteVideoTrack track: RTCVideoTrack)
    func webRTCSession(_ session: WebRTCSession, didFail error: Error)
}

struct SenderMediaBoundarySnapshot: Equatable, Sendable {
    let sourceFramesForwarded: UInt64
    let sourcePixelFormat: UInt32?
    let castTuningSessionID: String?
    let castTuningConfigHash: String?
    let encoderSessionID: String?
    let videoToolboxEncoderID: String?
    let expectedH264Profile: String?
    let actualH264Profile: String?
    let profileMismatch: Bool?
    let requestedMaxQp: Int?
    let effectiveMaxQp: Int?
    let maxQpApplyState: String?
    let maxQpGeneration: UInt64?
    let maxQpOSStatus: Int?
    let maxQpAppliedEncoderSessionID: String?
    let lastEncodedQp: Int?
    let lastKeyFrameQp: Int?
    let lastKeyFrameBytes: Int?
    let lastQpSampleGeneration: UInt64?
    let lastQpSampleEncoderSessionID: String?
    let clarityMode: VisualStabilityMode
    let claritySuccessfulRefreshes: UInt64
    let clarityFailedRefreshes: UInt64
    let clarityMotionRestores: UInt64
}

final class SenderMediaBoundaryTelemetry: @unchecked Sendable {
    private let lock = NSLock()
    private var sourceFramesForwarded: UInt64 = 0
    private var sourcePixelFormat: UInt32?

    func recordSourceFrameForwarded(pixelFormat: UInt32) {
        lock.withLock {
            sourceFramesForwarded += 1
            sourcePixelFormat = pixelFormat
        }
    }

    func sourceSnapshot() -> (frames: UInt64, pixelFormat: UInt32?) {
        lock.withLock { (sourceFramesForwarded, sourcePixelFormat) }
    }
}

final class WebRTCSession: NSObject, RTCPeerConnectionDelegate, ScreenCaptureFrameSink, @unchecked Sendable {
    let role: CastingRole
    let iceEvidence: IceConfigurationEvidence
    let metricsRenderer: MetricsVideoRenderer

    private weak var sessionDelegate: WebRTCSessionDelegate?
    private let factory: RTCPeerConnectionFactory
    private let peerConnection: RTCPeerConnection
    private let senderBoundaryTelemetry = SenderMediaBoundaryTelemetry()
    private let tuningAccessLock: NSLock
    private var tuningController: RTCCastTuningController?
    private var staticClarityRefreshController: StaticClarityRefreshController?
    private let videoSource: RTCVideoSource?
    private let videoCapturer: RTCVideoCapturer?
    private let displayRenderer: (any RTCVideoRenderer)?
    private let baselineProbe: MediaBaselineFrameProbe?
    private var remoteVideoTrack: RTCVideoTrack?

    init(
        role: CastingRole,
        ice: IceConfigurationResult,
        castTuningJSON: Data,
        staticMaxQp: Int = 24,
        displayRenderer: (any RTCVideoRenderer)? = nil,
        baselineProbe: MediaBaselineFrameProbe? = nil,
        delegate: WebRTCSessionDelegate? = nil
    ) throws {
        self.role = role
        iceEvidence = ice.evidence
        sessionDelegate = delegate
        self.displayRenderer = displayRenderer
        self.baselineProbe = baselineProbe
        metricsRenderer = MetricsVideoRenderer(baselineProbe: role == .receiver ? baselineProbe : nil)
        let tuningAccessLock = NSLock()
        self.tuningAccessLock = tuningAccessLock

        let tuningConfiguration = try RTCCastTuningConfiguration(jsonData: castTuningJSON)
        tuningConfiguration.apply(to: ice.configuration)
        let encoderFactory = H264OnlyVideoEncoderFactory()
        let decoderFactory = H264OnlyVideoDecoderFactory()
        let factory = try RTCCastTuningFactoryBuilder.peerConnectionFactory(
            with: encoderFactory,
            decoderFactory: decoderFactory,
            configuration: tuningConfiguration
        )
        self.factory = factory

        guard let peerConnection = factory.peerConnection(
            with: ice.configuration,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: nil as (any RTCPeerConnectionDelegate)?
        ) else {
            throw WebRTCSessionError.peerConnectionCreationFailed
        }
        self.peerConnection = peerConnection
        let tuningController = RTCCastTuningController(configuration: tuningConfiguration)
        self.tuningController = tuningController

        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = role == .sender ? .sendOnly : .recvOnly
        transceiverInit.streamIds = ["screencast"]

        if role == .sender {
            let source = factory.videoSource(forScreenCast: true)
            let track = factory.videoTrack(with: source, trackId: "screen-video")
            guard let created = peerConnection.addTransceiver(with: track, init: transceiverInit) else {
                throw WebRTCSessionError.transceiverCreationFailed
            }
            videoSource = source
            videoCapturer = RTCVideoCapturer(delegate: source)
            tuningController.attach(created.sender, track: track, source: source)
            let senderPolicy = Self.senderPolicy(from: castTuningJSON)
            staticClarityRefreshController = StaticClarityRefreshController(
                motionFPS: senderPolicy.maxFPS,
                clarityFPS: 1,
                maxBitrateBps: senderPolicy.maxBitrateBps,
                motionMaxQp: senderPolicy.maxQp,
                staticMaxQp: staticMaxQp,
                applyLivePolicy: { maxFPS, maxBitrateBps, maxQp in
                    tuningAccessLock.withLock {
                        let patch = RTCCastTuningLivePatch()
                        patch.maxFps = NSNumber(value: maxFPS)
                        patch.maxBitrateBps = NSNumber(value: maxBitrateBps)
                        patch.maxQp = NSNumber(value: maxQp)
                        return tuningController.apply(patch).status == .applied
                    }
                },
                forceKeyFrame: {
                    tuningAccessLock.withLock {
                        do {
                            try tuningController.forceKeyFrame()
                            return true
                        } catch {
                            return false
                        }
                    }
                }
            )
        } else {
            guard let created = peerConnection.addTransceiver(of: RTCRtpMediaType.video, init: transceiverInit) else {
                throw WebRTCSessionError.transceiverCreationFailed
            }
            videoSource = nil
            videoCapturer = nil
            staticClarityRefreshController = nil
            tuningController.attach(created.receiver)
        }

        super.init()
        peerConnection.delegate = self
        tuningController.attach(peerConnection)
    }

    func createOffer() async throws -> String {
        guard role == .sender else { throw WebRTCSessionError.wrongRole }
        return try await createAndSetLocalDescription(offer: true)
    }

    func createAnswer() async throws -> String {
        guard role == .receiver else { throw WebRTCSessionError.wrongRole }
        return try await createAndSetLocalDescription(offer: false)
    }

    func setRemoteDescription(type: RTCSdpType, sdp: String) async throws {
        let description = RTCSessionDescription(type: type, sdp: sdp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func addRemoteICECandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int32) async throws {
        let candidate = RTCIceCandidate(
            sdp: candidate,
            sdpMLineIndex: sdpMLineIndex,
            sdpMid: sdpMid
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.add(candidate) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func close() {
        stopDiagnostics()
        peerConnection.delegate = nil
        remoteVideoTrack?.remove(metricsRenderer)
        if let displayRenderer { remoteVideoTrack?.remove(displayRenderer) }
        remoteVideoTrack = nil
        tuningController = nil
        peerConnection.close()
    }

    func collectStatistics() async -> RTCStatisticsBatch {
        await withCheckedContinuation { continuation in
            peerConnection.statistics { report in
                continuation.resume(returning: RTCStatsSnapshotAdapter.makeBatch(from: report))
            }
        }
    }

    func senderMediaBoundarySnapshot() -> SenderMediaBoundarySnapshot {
        let tuning = tuningAccessLock.withLock { tuningController?.snapshot() }
        let clarity = staticClarityRefreshController?.snapshot()
        let source = senderBoundaryTelemetry.sourceSnapshot()
        return SenderMediaBoundarySnapshot(
            sourceFramesForwarded: source.frames,
            sourcePixelFormat: source.pixelFormat,
            castTuningSessionID: tuning?.sessionId,
            castTuningConfigHash: tuning?.effectiveConfigHash,
            encoderSessionID: tuning?.encoderSessionId,
            videoToolboxEncoderID: tuning?.videoToolboxEncoderId,
            expectedH264Profile: tuning?.expectedH264Profile,
            actualH264Profile: tuning?.actualH264Profile,
            profileMismatch: tuning?.profileMismatch,
            requestedMaxQp: tuning?.requestedMaxQp?.intValue,
            effectiveMaxQp: tuning?.effectiveMaxQp?.intValue,
            maxQpApplyState: tuning?.maxQpApplyState,
            maxQpGeneration: tuning?.maxQpGeneration,
            maxQpOSStatus: tuning?.maxQpOSStatus?.intValue,
            maxQpAppliedEncoderSessionID: tuning?.maxQpAppliedEncoderSessionId,
            lastEncodedQp: tuning?.lastEncodedQp?.intValue,
            lastKeyFrameQp: tuning?.lastKeyFrameQp?.intValue,
            lastKeyFrameBytes: tuning?.lastKeyFrameBytes?.intValue,
            lastQpSampleGeneration: tuning?.lastQpSampleGeneration,
            lastQpSampleEncoderSessionID: tuning?.lastQpSampleEncoderSessionId,
            clarityMode: clarity?.mode ?? .motion,
            claritySuccessfulRefreshes: clarity?.successfulRefreshes ?? 0,
            clarityFailedRefreshes: clarity?.failedRefreshes ?? 0,
            clarityMotionRestores: clarity?.motionRestores ?? 0
        )
    }

    func startDiagnostics(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func stopDiagnostics() {}

    func screenCaptureSource(_ source: ScreenCaptureSource, didCapture frame: CapturedScreenFrame) -> Bool {
        guard role == .sender, let videoCapturer, let delegate = videoCapturer.delegate else { return false }
        let transitionApplied = staticClarityRefreshController?.handle(frame.clarityTransition) ?? false
        let buffer = RTCCVPixelBuffer(pixelBuffer: frame.pixelBuffer)
        let videoFrame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: frame.timestampNs)
        delegate.capturer(videoCapturer, didCapture: videoFrame)
        senderBoundaryTelemetry.recordSourceFrameForwarded(
            pixelFormat: CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        )
        baselineProbe?.observe(
            pixelBuffer: frame.pixelBuffer,
            frameTimestampNs: frame.timestampNs,
            callbackNs: frame.callbackMonotonicNs
        )
        return transitionApplied
    }

    func screenCaptureSource(_ source: ScreenCaptureSource, didStopWithError error: Error) {
        sessionDelegate?.webRTCSession(self, didFail: error)
    }

    private func createAndSetLocalDescription(offer: Bool) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let completion: @Sendable (RTCSessionDescription?, Error?) -> Void = { [peerConnection] description, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let description {
                    peerConnection.setLocalDescription(description) { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: description.sdp) }
                    }
                } else {
                    continuation.resume(throwing: WebRTCSessionError.missingSessionDescription)
                }
            }
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            if offer {
                peerConnection.offer(for: constraints, completionHandler: completion)
            } else {
                peerConnection.answer(for: constraints, completionHandler: completion)
            }
        }
    }

    private static func senderPolicy(from jsonData: Data) -> (maxFPS: Int, maxBitrateBps: Int, maxQp: Int) {
        guard let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let sender = root["sender"] as? [String: Any]
        else {
            return (15, 5_000_000, 32)
        }
        let maxFPS = (sender["max_fps"] as? NSNumber)?.intValue ?? 15
        let maxBitrateBps = (sender["max_bitrate_bps"] as? NSNumber)?.intValue ?? 5_000_000
        let encoder = root["encoder"] as? [String: Any]
        let maxQp = (encoder?["max_qp"] as? NSNumber)?.intValue ?? 32
        return (maxFPS, maxBitrateBps, maxQp)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { sessionDelegate?.webRTCSessionDidCompleteICEGathering(self) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        sessionDelegate?.webRTCSession(self, didGenerate: candidate)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        sessionDelegate?.webRTCSession(self, didChange: newState)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        guard role == .receiver, let track = rtpReceiver.track as? RTCVideoTrack else { return }
        guard remoteVideoTrack == nil else {
            sessionDelegate?.webRTCSession(self, didFail: WebRTCSessionError.unexpectedRemoteVideoTrack)
            return
        }
        remoteVideoTrack = track
        track.add(metricsRenderer)
        if let displayRenderer { track.add(displayRenderer) }
        sessionDelegate?.webRTCSession(self, didReceiveRemoteVideoTrack: track)
    }
}
