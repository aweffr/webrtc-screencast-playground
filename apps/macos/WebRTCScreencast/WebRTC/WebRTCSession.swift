import CoreVideo
import Foundation
@preconcurrency import WebRTC

enum WebRTCSessionError: Error {
    case factoryCreationFailed
    case peerConnectionCreationFailed
    case transceiverCreationFailed
    case codecPreferenceFailed(String)
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

final class WebRTCSession: NSObject, RTCPeerConnectionDelegate, ScreenCaptureFrameSink, @unchecked Sendable {
    let role: CastingRole
    let iceEvidence: IceConfigurationEvidence
    let metricsRenderer: MetricsVideoRenderer

    private weak var sessionDelegate: WebRTCSessionDelegate?
    private let factory: RTCPeerConnectionFactory
    private let peerConnection: RTCPeerConnection
    private var tuningController: RTCCastTuningController?
    private let videoSource: RTCVideoSource?
    private let videoCapturer: RTCVideoCapturer?
    private let displayRenderer: (any RTCVideoRenderer)?
    private var remoteVideoTrack: RTCVideoTrack?

    init(
        role: CastingRole,
        ice: IceConfigurationResult,
        castTuningJSON: Data,
        displayRenderer: (any RTCVideoRenderer)? = nil,
        delegate: WebRTCSessionDelegate? = nil
    ) throws {
        self.role = role
        iceEvidence = ice.evidence
        sessionDelegate = delegate
        self.displayRenderer = displayRenderer
        metricsRenderer = MetricsVideoRenderer()

        let tuningConfiguration = try RTCCastTuningConfiguration(jsonData: castTuningJSON)
        tuningConfiguration.apply(to: ice.configuration)
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
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

        let transceiver: RTCRtpTransceiver
        if role == .sender {
            let source = factory.videoSource(forScreenCast: true)
            let track = factory.videoTrack(with: source, trackId: "screen-video")
            guard let created = peerConnection.addTransceiver(with: track, init: transceiverInit) else {
                throw WebRTCSessionError.transceiverCreationFailed
            }
            videoSource = source
            videoCapturer = RTCVideoCapturer(delegate: source)
            transceiver = created
            tuningController.attach(created.sender, track: track, source: source)
        } else {
            guard let created = peerConnection.addTransceiver(of: RTCRtpMediaType.video, init: transceiverInit) else {
                throw WebRTCSessionError.transceiverCreationFailed
            }
            videoSource = nil
            videoCapturer = nil
            transceiver = created
            tuningController.attach(created.receiver)
        }

        let capabilities = role == .sender
            ? factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs
            : factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs
        let selectedCodecs = try H264CodecPolicy.selectCapabilities(capabilities)
        do {
            try transceiver.setCodecPreferences(selectedCodecs, error: ())
        } catch {
            throw WebRTCSessionError.codecPreferenceFailed(error.localizedDescription)
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
        peerConnection.delegate = nil
        remoteVideoTrack?.remove(metricsRenderer)
        if let displayRenderer { remoteVideoTrack?.remove(displayRenderer) }
        remoteVideoTrack = nil
        tuningController = nil
        peerConnection.close()
    }

    func screenCaptureSource(_ source: ScreenCaptureSource, didCapture frame: CapturedScreenFrame) {
        guard role == .sender, let videoCapturer, let delegate = videoCapturer.delegate else { return }
        let buffer = RTCCVPixelBuffer(pixelBuffer: frame.pixelBuffer)
        let videoFrame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: frame.timestampNs)
        delegate.capturer(videoCapturer, didCapture: videoFrame)
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
