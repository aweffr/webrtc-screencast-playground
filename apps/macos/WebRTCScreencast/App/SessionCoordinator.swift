import AppKit
import CoreGraphics
import Foundation
import SwiftUI
@preconcurrency import WebRTC

struct SessionMetricsSummary: Equatable, Sendable {
    var bitrateBps: Double?
    var framesPerSecond: Double?
    var averageQP: Double?
    var roundTripTimeMs: Double?
    var renderedFrames: UInt64 = 0
    var selectedPath = SelectedPathEvidence(
        status: .unknown,
        selectedPairID: nil,
        localCandidateType: nil,
        remoteCandidateType: nil,
        protocolValue: nil
    )
}

@MainActor
final class SessionCoordinator: NSObject, ObservableObject {
    @Published private(set) var state: SessionState = .idle
    @Published private(set) var pairingCode: String?
    @Published private(set) var metrics = SessionMetricsSummary()
    @Published private(set) var sessionDirectory: URL?
    @Published private(set) var exportMessage: String?

    @Published var selectedRole: CastingRole = .receiver
    @Published var selectedProfile: ICEProfile = .productionRelay
    @Published var selectedSource: CaptureSourceKind = .mainDisplayMirror
    @Published var signalingURLText = "ws://127.0.0.1:8080/ws"
    @Published var senderPairingCode = ""

    let videoViewStore = RemoteVideoViewStore()

    private var baseConfiguration: RuntimeConfiguration?
    private var launchOptions: LaunchOptions?
    private var flow: SessionFlow?
    private var signaling: SignalingClient?
    private var peer: WebRTCSession?
    private var captureSource: ScreenCaptureSource?
    private var virtualDisplay: VirtualExtendedDisplayProvider?
    private var recorder: MetricsRecorder?
    private var sampler: SessionMetricsSampler?
    private var signalingTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?
    private var effectiveConfiguration: EffectiveConfiguration?
    private var runtimeConfiguration: RuntimeConfiguration?
    private var currentSessionID: String?
    private var failureDuringTeardown = false

    init(configuration: RuntimeConfiguration? = nil, launchOptions: LaunchOptions? = nil) {
        baseConfiguration = configuration
        self.launchOptions = launchOptions
        if let configuration {
            selectedProfile = configuration.iceProfile
            signalingURLText = configuration.signalingURL.absoluteString
        }
        if let launchOptions {
            if let role = launchOptions.role { selectedRole = role }
            if let profile = launchOptions.profile { selectedProfile = profile }
            if let source = launchOptions.source { selectedSource = source }
        }
        super.init()
    }

    var isActive: Bool {
        switch state {
        case .idle, .failed: false
        default: true
        }
    }

    func runLaunchOptionsIfNeeded() async {
        guard let options = launchOptions, let role = options.role, state == .idle else { return }
        do {
            if role == .sender, let path = options.pairingCodeFile {
                senderPairingCode = try await PairingCodeFile.waitForCode(at: URL(filePath: path))
            }
            try await start()
        } catch {
            await fail(code: "launch_failed", error: error)
        }
    }

    func start() async throws {
        guard state == .idle || isFailed else { return }
        resetPresentation()

        guard let signalingURL = URL(string: signalingURLText),
              ["ws", "wss"].contains(signalingURL.scheme?.lowercased() ?? "") else {
            throw RuntimeConfigurationError.invalidSignalingURL
        }
        let role = selectedRole
        let source = role == .sender ? selectedSource : nil
        let senderCode = role == .sender ? try PairingCode.normalize(senderPairingCode) : nil
        var configuration = baseConfiguration ?? fallbackConfiguration(signalingURL: signalingURL)
        configuration = configuration.overriding(
            signalingURL: signalingURL,
            iceProfile: selectedProfile,
            excludedReceiverPID: launchOptions?.excludedReceiverPID
        )
        try configuration.validate()
        runtimeConfiguration = configuration
        let effective = try configuration.effective(role: role, source: source)
        effectiveConfiguration = effective

        let sessionID = UUID().uuidString.lowercased()
        currentSessionID = sessionID
        let directory = effective.metricsDirectory
            .appending(path: "\(sessionID)-\(role.rawValue)", directoryHint: .isDirectory)
        sessionDirectory = directory
        let recorder = try MetricsRecorder(
            directory: directory,
            context: MetricsContext(
                schemaVersion: 1,
                sessionID: sessionID,
                role: role,
                profile: selectedProfile,
                effectiveConfigHash: effective.hash,
                tuningRevision: 1
            )
        )
        self.recorder = recorder
        try await recorder.record(event: "session_started", fields: [
            "source": source.map { .string($0.rawValue) } ?? .null,
            "process_id": .integer(Int(ProcessInfo.processInfo.processIdentifier)),
        ])

        do {
            let ice = try IceServerProvider.make(profile: selectedProfile, turn: configuration.turn)
            let tuningData = try loadCastTuning()
            let peer = try WebRTCSession(
                role: role,
                ice: ice,
                castTuningJSON: tuningData,
                displayRenderer: role == .receiver ? videoViewStore.renderer : nil,
                delegate: self
            )
            self.peer = peer
            try peer.startDiagnostics(in: directory)
            if role == .sender {
                captureSource = ScreenCaptureSource(sink: peer)
            }
            let sampler = SessionMetricsSampler(
                session: peer,
                captureSource: captureSource,
                recorder: recorder,
                profile: selectedProfile
            )
            self.sampler = sampler
            await sampler.start()
            startMetricsPresentation(peer: peer, profile: selectedProfile)

            let signaling = SignalingClient()
            self.signaling = signaling
            let eventStream = await signaling.events()
            signalingTask = Task { [weak self] in
                do {
                    for try await event in eventStream {
                        guard !Task.isCancelled else { return }
                        await self?.handleSignaling(event)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    await self?.fail(code: "signaling_disconnected", error: error)
                }
            }

            flow = SessionFlow(role: role, senderCode: senderCode)
            state = .connectingSignaling(role: role)
            try await apply(try requireFlow(.start))
        } catch {
            await fail(code: "session_start_failed", error: error)
            throw error
        }
    }

    func stop() async {
        guard var flow else { return }
        if signaling != nil {
            try? await signaling?.send(.sessionHangup(reason: "user_stop"))
        }
        let commands = (try? flow.handle(.stopRequested)) ?? []
        self.flow = flow
        state = .ending
        await apply(commands)
    }

    func exportDiagnostics() async {
        guard let sessionDirectory, let runtimeConfiguration else { return }
        do {
            try await recorder?.synchronize()
            let outputDirectory = runtimeConfiguration.metricsDirectory.appending(path: "exports", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let output = outputDirectory.appending(path: "\(sessionDirectory.lastPathComponent).zip")
            var secrets: [String] = []
            if let turn = runtimeConfiguration.turn { secrets = [turn.username, turn.password] }
            _ = try await DiagnosticExporter.export(
                sessionDirectory: sessionDirectory,
                outputURL: output,
                forbiddenSecrets: secrets
            )
            exportMessage = "已导出：\(output.path)"
        } catch {
            exportMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func fallbackConfiguration(signalingURL: URL) -> RuntimeConfiguration {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "WebRTCScreencast/metrics", directoryHint: .isDirectory)
        return RuntimeConfiguration(
            signalingURL: signalingURL,
            iceProfile: selectedProfile,
            turn: nil,
            metricsDirectory: base,
            excludedReceiverPID: nil
        )
    }

    private func loadCastTuning() throws -> Data {
        guard let url = Bundle.main.url(forResource: "cast-tuning.default", withExtension: "json") else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    private func requireFlow(_ event: SessionFlowEvent) throws -> [SessionFlowCommand] {
        guard var flow else { return [] }
        let commands = try flow.handle(event)
        self.flow = flow
        return commands
    }

    private func apply(_ commands: [SessionFlowCommand]) async {
        for command in commands {
            do {
                switch command {
                case .connectSignaling:
                    guard let effectiveConfiguration, let signaling else { continue }
                    try await signaling.connect(url: effectiveConfiguration.signalingURL, role: selectedRole)
                    try await recorder?.record(event: "signaling_connected")
                    state = .waitingForPeer(role: selectedRole)
                    try await apply(try requireFlow(.signalingConnected))

                case .registerReceiver:
                    try await signaling?.registerReceiver()

                case .join(let code):
                    try await signaling?.join(code: code)
                    try await recorder?.record(event: "sender_join_requested")

                case .publishPairingCode(let code):
                    pairingCode = code
                    if let path = launchOptions?.pairingCodeFile {
                        try PairingCodeFile.write(code, to: URL(filePath: path))
                    }
                    try await recorder?.record(event: "receiver_registered", fields: ["pairing_code": .string(code)])

                case .createAndSendOffer:
                    guard let peer else { continue }
                    let offer = try await peer.createOffer()
                    try await signaling?.send(.sdpOffer(offer))
                    try await recorder?.record(event: "local_offer", fields: ["sdp": .string(offer)])

                case .setRemoteOffer(let sdp):
                    try await peer?.setRemoteDescription(type: .offer, sdp: sdp)
                    try await recorder?.record(event: "remote_offer", fields: ["sdp": .string(sdp)])

                case .createAndSendAnswer:
                    guard let peer else { continue }
                    let answer = try await peer.createAnswer()
                    try await signaling?.send(.sdpAnswer(answer))
                    try await recorder?.record(event: "local_answer", fields: ["sdp": .string(answer)])

                case .setRemoteAnswer(let sdp):
                    try await peer?.setRemoteDescription(type: .answer, sdp: sdp)
                    try await recorder?.record(event: "remote_answer", fields: ["sdp": .string(sdp)])

                case let .addRemoteCandidate(candidate, mid, line):
                    try await peer?.addRemoteICECandidate(candidate: candidate, sdpMid: mid, sdpMLineIndex: line)
                    try await recorder?.record(event: "ice_candidate_remote", fields: ["candidate": .string(candidate)])

                case let .sendCandidate(candidate, mid, line):
                    try await signaling?.send(.iceCandidate(candidate: candidate, sdpMid: mid, sdpMLineIndex: line))
                    try await recorder?.record(event: "ice_candidate_local", fields: ["candidate": .string(candidate)])

                case .sendICEComplete:
                    try await signaling?.send(.iceComplete)
                    try await recorder?.record(event: "ice_gathering_complete")

                case .startCapture:
                    try await startCapture()

                case let .reportFailure(code, message):
                    failureDuringTeardown = true
                    state = .failed(SessionFailure(code: code, message: userMessage(code: code, fallback: message)))
                    try? await recorder?.record(event: "session_failed", fields: [
                        "error_code": .string(code),
                        "message": .string(message),
                    ])

                case .stopSampler:
                    metricsTask?.cancel()
                    metricsTask = nil
                    await sampler?.stop()
                    sampler = nil

                case .stopCapture:
                    try? await captureSource?.stop()
                    captureSource = nil

                case .closeSignaling:
                    signalingTask?.cancel()
                    signalingTask = nil
                    await signaling?.close()
                    signaling = nil

                case .closePeer:
                    peer?.close()
                    peer = nil

                case .stopVirtualDisplay:
                    try? await virtualDisplay?.stop()
                    virtualDisplay = nil

                case .closeMetrics:
                    try? await recorder?.record(event: "session_stopped")
                    try? await recorder?.close()
                    recorder = nil
                    flow = nil
                    effectiveConfiguration = nil
                    runtimeConfiguration = nil
                    if !failureDuringTeardown { state = .idle }
                    failureDuringTeardown = false
                }
            } catch {
                await fail(code: "session_command_failed", error: error)
                return
            }
        }
    }

    private func startCapture() async throws {
        guard let effectiveConfiguration, let source = effectiveConfiguration.source, let captureSource else { return }
        let displayID: CGDirectDisplayID
        switch source {
        case .mainDisplayMirror:
            displayID = CGMainDisplayID()
        case .virtualExtendedDisplay:
            let provider = VirtualExtendedDisplayProvider()
            virtualDisplay = provider
            displayID = try await provider.start()
            try await recorder?.record(event: "virtual_display_created", fields: ["display_id": .integer(Int(displayID))])
        }
        try await captureSource.start(
            displayID: displayID,
            source: source,
            iceProfile: effectiveConfiguration.iceProfile,
            excludedReceiverPID: effectiveConfiguration.excludedReceiverPID
        )
        try await recorder?.record(event: "capture_started", fields: ["display_id": .integer(Int(displayID))])
    }

    private func handleSignaling(_ event: SignalingEvent) async {
        guard case let .message(envelope) = event else { return }
        do {
            switch envelope.payload {
            case let .receiverRegistered(_, code, _):
                try await apply(try requireFlow(.receiverRegistered(code: code)))
            case .sessionPaired:
                state = .negotiating(role: selectedRole)
                try await recorder?.record(event: "peer_paired")
                try await apply(try requireFlow(.peerPaired))
            case .sdpOffer(let sdp):
                try await apply(try requireFlow(.remoteOffer(sdp)))
            case .sdpAnswer(let sdp):
                try await apply(try requireFlow(.remoteAnswer(sdp)))
            case let .iceCandidate(candidate, mid, line):
                try await apply(try requireFlow(.remoteCandidate(candidate: candidate, mid: mid, line: line)))
            case .iceComplete:
                try await recorder?.record(event: "remote_ice_complete")
            case .sessionHangup:
                state = .ending
                try await apply(try requireFlow(.remoteHangup))
            case let .serverError(code, message, _):
                await fail(code: code, message: message)
            default:
                break
            }
        } catch {
            await fail(code: "signaling_message_failed", error: error)
        }
    }

    private func startMetricsPresentation(peer: WebRTCSession, profile: ICEProfile) {
        metricsTask?.cancel()
        metricsTask = Task { [weak self] in
            var normalizer = RTCStatsNormalizer(profile: profile)
            while !Task.isCancelled {
                let batch = await peer.collectStatistics()
                let sample = normalizer.normalize(timestampUs: batch.timestampUs, statistics: batch.statistics)
                guard let self else { return }
                let video = self.selectedRole == .sender ? sample.outbound : sample.inbound
                let rendered = peer.metricsRenderer.snapshot().framesRendered
                self.metrics = SessionMetricsSummary(
                    bitrateBps: video?.bitrateBps,
                    framesPerSecond: video?.framesPerSecond,
                    averageQP: video?.averageQP,
                    roundTripTimeMs: sample.remoteInbound?.roundTripTimeMs,
                    renderedFrames: rendered,
                    selectedPath: sample.selectedPath
                )
                if sample.selectedPath.status == .violation {
                    await self.profileViolation(sample.selectedPath)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func profileViolation(_ evidence: SelectedPathEvidence) async {
        let description = "selected path \(evidence.localCandidateType ?? "unknown")/\(evidence.protocolValue ?? "unknown")"
        do {
            try await apply(try requireFlow(.profileViolated(description)))
        } catch {
            await fail(code: "profile_violation", error: error)
        }
    }

    private func fail(code: String, error: Error) async {
        await fail(code: code, message: error.localizedDescription)
    }

    private func fail(code: String, message: String) async {
        if var flow {
            let commands = (try? flow.handle(.fatalFailure(code: code, message: message))) ?? []
            self.flow = flow
            await apply(commands)
        } else {
            state = .failed(SessionFailure(code: code, message: userMessage(code: code, fallback: message)))
        }
    }

    private func userMessage(code: String, fallback: String) -> String {
        switch code {
        case "capture_failed": "无法采集屏幕，请在系统设置中允许屏幕录制后重试。"
        case "profile_violation": "网络路径不符合当前连接模式，投屏已停止。"
        case "code_not_found", "code_consumed", "pairing_expired": "配对码无效或已使用，请由接收端生成新的配对码。"
        default: fallback
        }
    }

    private func resetPresentation() {
        pairingCode = nil
        metrics = SessionMetricsSummary()
        exportMessage = nil
        sessionDirectory = nil
        failureDuringTeardown = false
    }
}

extension SessionCoordinator: WebRTCSessionDelegate {
    nonisolated func webRTCSession(_ session: WebRTCSession, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.apply(try self.requireFlow(.localCandidate(
                candidate: candidate.sdp,
                mid: candidate.sdpMid ?? "0",
                line: candidate.sdpMLineIndex
            )))
        }
    }

    nonisolated func webRTCSessionDidCompleteICEGathering(_ session: WebRTCSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.apply(try self.requireFlow(.localICEComplete))
        }
    }

    nonisolated func webRTCSession(_ session: WebRTCSession, didChange state: RTCPeerConnectionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.recorder?.record(event: "peer_connection_state", fields: ["state": .string(String(describing: state))])
            switch state {
            case .connected:
                self.state = .connected(role: self.selectedRole)
                try? await self.apply(try self.requireFlow(.peerConnected))
            case .failed:
                await self.fail(code: "peer_connection_failed", message: "WebRTC connection failed")
            default:
                break
            }
        }
    }

    nonisolated func webRTCSession(_ session: WebRTCSession, didReceiveRemoteVideoTrack track: RTCVideoTrack) {
        Task { @MainActor [weak self] in
            try? await self?.recorder?.record(event: "remote_video_track")
        }
    }

    nonisolated func webRTCSession(_ session: WebRTCSession, didFail error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if session.role == .sender {
                do { try await self.apply(try self.requireFlow(.captureFailed(error.localizedDescription))) }
                catch { await self.fail(code: "capture_failed", error: error) }
            } else {
                await self.fail(code: "peer_session_failed", error: error)
            }
        }
    }
}
