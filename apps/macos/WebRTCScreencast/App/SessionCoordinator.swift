import AppKit
import CoreGraphics
import Foundation
import SwiftUI
@preconcurrency import WebRTC

private func h264ProfileLevelIDs(in sdp: String) -> [String] {
    var result: [String] = []
    for line in sdp.split(whereSeparator: { $0.isNewline }) {
        let normalized = line.lowercased()
        guard let range = normalized.range(of: "profile-level-id=") else { continue }
        let value = normalized[range.upperBound...].prefix(6)
        guard value.count == 6, value.allSatisfy(\.isHexDigit) else { continue }
        let profile = String(value)
        if !result.contains(profile) { result.append(profile) }
    }
    return result
}

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
    private let startupFailure: String?
    private var launchOptions: LaunchOptions?
    private var flow: SessionFlow?
    private var signaling: SignalingClient?
    private var peer: WebRTCSession?
    private var captureSource: ScreenCaptureSource?
    private var displaySleepActivity: DisplaySleepActivity?
    private var baselineChart: MediaBaselineChartController?
    private var virtualDisplay: VirtualExtendedDisplayProvider?
    private var recorder: MetricsRecorder?
    private var sampler: SessionMetricsSampler?
    private var signalingTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?
    private var effectiveConfiguration: EffectiveConfiguration?
    private var runtimeConfiguration: RuntimeConfiguration?
    private var clockCalibration: ClockCalibration?
    private var currentSessionID: String?
    private var failureDuringTeardown = false
    private var remoteDescriptionReady = false
    private var pendingRemoteCandidates: [(candidate: String, mid: String, line: Int32)] = []

    init(
        configuration: RuntimeConfiguration? = nil,
        launchOptions: LaunchOptions? = nil,
        startupFailure: String? = nil
    ) {
        baseConfiguration = configuration
        self.launchOptions = launchOptions
        self.startupFailure = startupFailure
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
        guard state == .idle else { return }
        if startupFailure != nil, launchOptions == nil {
            await start()
            return
        }
        guard let options = launchOptions, let role = options.role else { return }
        do {
            if startupFailure == nil, role == .sender {
                if let code = options.pairingCode {
                    senderPairingCode = code
                } else if let path = options.pairingCodeFile {
                    senderPairingCode = try await PairingCodeFile.waitForCode(at: URL(filePath: path))
                }
            }
            await start()
            if let seconds = options.runSeconds {
                if isActive { try await Task.sleep(for: .seconds(seconds)) }
                await stop()
                NSApplication.shared.terminate(nil)
            }
        } catch {
            await fail(code: "launch_failed", error: error)
        }
    }

    func start() async {
        do {
            try await beginSession()
        } catch {
            await fail(code: "session_start_failed", error: error)
        }
    }

    private func beginSession() async throws {
        guard state == .idle || isFailed else { return }
        resetPresentation()
        if let startupFailure {
            throw SessionCoordinatorStartupError.configuration(startupFailure)
        }

        guard let signalingURL = URL(string: signalingURLText),
              ["ws", "wss"].contains(signalingURL.scheme?.lowercased() ?? "") else {
            throw RuntimeConfigurationError.invalidSignalingURL
        }
        let role = selectedRole
        let source = role == .sender ? selectedSource : nil
        if launchOptions?.mediaBaseline == true,
           role == .sender,
           source != .virtualExtendedDisplay {
            throw SessionCoordinatorStartupError.configuration("Media baseline requires the virtual display source")
        }
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
            let calibration = try await ClockCalibrationClient().calibrate(signalingURL: signalingURL)
            clockCalibration = calibration
            try await recorder.record(event: "clock_calibrated", fields: [
                "sample_count": .integer(calibration.sampleCount),
                "offset_ns": .integer(Int(calibration.offsetNs)),
                "round_trip_ns": .integer(Int(calibration.roundTripNs)),
                "uncertainty_ns": .integer(Int(calibration.uncertaintyNs)),
            ])
        } catch {
            clockCalibration = nil
            try await recorder.record(event: "clock_calibration_unavailable", fields: [
                "error": .string(String(describing: error)),
            ])
            if launchOptions?.usesMarkerProbe == true {
                throw SessionCoordinatorStartupError.configuration(
                    "Marker evidence requires server clock calibration"
                )
            }
        }

        flow = SessionFlow(role: role, senderCode: senderCode)
        state = .connectingSignaling(role: role)
        do {
            let ice = try IceServerProvider.make(profile: selectedProfile, turn: configuration.turn)
            let tuningData = try loadCastTuning()
            let baselineProbe = launchOptions?.usesMarkerProbe == true
                ? MediaBaselineFrameProbe(
                    stage: role == .sender ? .capture : .decode,
                    recorder: recorder,
                    directory: directory
                )
                : nil
            let peer = try WebRTCSession(
                role: role,
                ice: ice,
                castTuningJSON: tuningData,
                videoCodecPolicy: configuration.videoCodecPolicy,
                staticMaxQp: configuration.staticMaxQp,
                displayRenderer: role == .receiver ? videoViewStore.renderer : nil,
                baselineProbe: baselineProbe,
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

            await apply(try requireFlow(.start))
        } catch {
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
            excludedReceiverPID: nil,
            staticMaxQp: 24
        )
    }

    private func loadCastTuning() throws -> Data {
        if let path = launchOptions?.castTuningConfigPath {
            return try Data(contentsOf: URL(filePath: path))
        }
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
                    try await recorder?.record(event: "signaling_connect_started")
                    try await signaling.connect(url: effectiveConfiguration.signalingURL, role: selectedRole)
                    try await recorder?.record(event: "signaling_connected")
                    state = .waitingForPeer(role: selectedRole)
                    await apply(try requireFlow(.signalingConnected))

                case .registerReceiver:
                    try await recorder?.record(event: "receiver_register_started")
                    try await signaling?.registerReceiver()

                case .join(let code):
                    try await recorder?.record(event: "sender_join_started")
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
                    try await recorder?.record(event: "local_offer", fields: [
                        "sdp": .string(offer),
                        "offers_h264": .bool(offer.localizedCaseInsensitiveContains("H264/90000")),
                        "offers_h265": .bool(offer.localizedCaseInsensitiveContains("H265/90000")),
                        "h264_profile_level_ids": .array(h264ProfileLevelIDs(in: offer).map(JSONValue.string)),
                    ])

                case .setRemoteOffer(let sdp):
                    try await peer?.setRemoteDescription(type: .offer, sdp: sdp)
                    remoteDescriptionReady = true
                    try await recorder?.record(event: "remote_offer", fields: ["sdp": .string(sdp)])
                    try await flushPendingRemoteCandidates()

                case .createAndSendAnswer:
                    guard let peer else { continue }
                    let answer = try await peer.createAnswer()
                    try await signaling?.send(.sdpAnswer(answer))
                    try await recorder?.record(event: "local_answer", fields: ["sdp": .string(answer)])

                case .setRemoteAnswer(let sdp):
                    try await peer?.setRemoteDescription(type: .answer, sdp: sdp)
                    remoteDescriptionReady = true
                    try await recorder?.record(event: "remote_answer", fields: ["sdp": .string(sdp)])
                    try await flushPendingRemoteCandidates()

                case let .addRemoteCandidate(candidate, mid, line):
                    if remoteDescriptionReady {
                        try await addRemoteCandidate(candidate: candidate, mid: mid, line: line)
                    } else {
                        pendingRemoteCandidates.append((candidate, mid, line))
                        try await recorder?.record(event: "ice_candidate_remote_queued")
                    }

                case let .sendCandidate(candidate, mid, line):
                    try await signaling?.send(.iceCandidate(candidate: candidate, sdpMid: mid, sdpMLineIndex: line))
                    try await recorder?.record(event: "ice_candidate_local", fields: ["candidate": .string(candidate)])

                case .sendICEComplete:
                    try await signaling?.send(.iceComplete)
                    try await recorder?.record(event: "ice_gathering_complete")

                case .startCapture:
                    do {
                        try await startCapture()
                    } catch {
                        await apply(try requireFlow(.captureFailed(error.localizedDescription)))
                        return
                    }

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
                    await baselineChart?.stop()
                    baselineChart = nil
                    displaySleepActivity?.stop()
                    displaySleepActivity = nil

                case .closeSignaling:
                    signalingTask?.cancel()
                    signalingTask = nil
                    await signaling?.close()
                    signaling = nil

                case .closePeer:
                    peer?.close()
                    peer = nil

                case .stopVirtualDisplay:
                    if let virtualDisplay {
                        do {
                            try await virtualDisplay.stop()
                            try? await recorder?.record(event: "virtual_display_removed")
                        } catch {
                            failureDuringTeardown = true
                            let message = "Virtual display cleanup failed: \(String(describing: error))"
                            state = .failed(SessionFailure(
                                code: "virtual_display_removal_failed",
                                message: message
                            ))
                            try? await recorder?.record(event: "virtual_display_removal_failed", fields: [
                                "error_code": .string("virtual_display_removal_failed"),
                                "message": .string(message),
                            ])
                        }
                    }
                    virtualDisplay = nil

                case .closeMetrics:
                    try? await recorder?.record(event: "session_stopped")
                    try? await recorder?.close()
                    recorder = nil
                    flow = nil
                    effectiveConfiguration = nil
                    runtimeConfiguration = nil
                    clockCalibration = nil
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
        let displaySleepActivity = DisplaySleepActivity()
        displaySleepActivity.start()
        self.displaySleepActivity = displaySleepActivity
        let displayID: CGDirectDisplayID
        switch source {
        case .mainDisplayMirror:
            displayID = CGMainDisplayID()
        case .virtualExtendedDisplay:
            let provider = VirtualExtendedDisplayProvider()
            virtualDisplay = provider
            displayID = try await provider.start()
            try await recorder?.record(event: "virtual_display_created", fields: ["display_id": .integer(Int(displayID))])
            if launchOptions?.mediaBaseline == true, let recorder, let sessionDirectory {
                let chart = MediaBaselineChartController(recorder: recorder, directory: sessionDirectory)
                try await chart.start(displayID: displayID)
                baselineChart = chart
            }
        }
        try await captureSource.start(
            displayID: displayID,
            source: source,
            iceProfile: effectiveConfiguration.iceProfile,
            excludedReceiverPID: effectiveConfiguration.excludedReceiverPID
        )
        try await recorder?.record(event: "capture_started", fields: ["display_id": .integer(Int(displayID))])
    }

    private func addRemoteCandidate(candidate: String, mid: String, line: Int32) async throws {
        try await peer?.addRemoteICECandidate(candidate: candidate, sdpMid: mid, sdpMLineIndex: line)
        try await recorder?.record(event: "ice_candidate_remote", fields: ["candidate": .string(candidate)])
    }

    private func flushPendingRemoteCandidates() async throws {
        let candidates = pendingRemoteCandidates
        pendingRemoteCandidates.removeAll(keepingCapacity: true)
        for value in candidates {
            try await addRemoteCandidate(candidate: value.candidate, mid: value.mid, line: value.line)
        }
    }

    private func recordImmediateSelectedPath(for session: WebRTCSession) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        var evidence = SelectedPathEvidence(
            status: .unknown,
            selectedPairID: nil,
            localCandidateType: nil,
            remoteCandidateType: nil,
            protocolValue: nil
        )
        repeat {
            let batch = await session.collectStatistics()
            evidence = SelectedPathVerifier.verify(profile: selectedProfile, statistics: batch.statistics)
            if evidence.status != .unknown || clock.now >= deadline { break }
            try? await Task.sleep(for: .milliseconds(25))
        } while !Task.isCancelled
        metrics.selectedPath = evidence
        try? await recorder?.record(event: "selected_path", fields: [
            "status": .string(evidence.status.rawValue),
            "pair_id": evidence.selectedPairID.map(JSONValue.string) ?? .null,
            "local_candidate_type": evidence.localCandidateType.map(JSONValue.string) ?? .null,
            "remote_candidate_type": evidence.remoteCandidateType.map(JSONValue.string) ?? .null,
            "protocol": evidence.protocolValue.map(JSONValue.string) ?? .null,
        ])
        if evidence.status == .violation {
            await profileViolation(evidence)
        }
    }

    private func handleSignaling(_ event: SignalingEvent) async {
        guard case let .message(envelope) = event else { return }
        do {
            switch envelope.payload {
            case let .receiverRegistered(sessionID, code, _):
                try await bindCanonicalSessionID(sessionID)
                await apply(try requireFlow(.receiverRegistered(code: code)))
            case let .sessionPaired(sessionID, _):
                try await bindCanonicalSessionID(sessionID)
                state = .negotiating(role: selectedRole)
                try await recorder?.record(event: "peer_paired")
                await apply(try requireFlow(.peerPaired))
            case .sdpOffer(let sdp):
                await apply(try requireFlow(.remoteOffer(sdp)))
            case .sdpAnswer(let sdp):
                await apply(try requireFlow(.remoteAnswer(sdp)))
            case let .iceCandidate(candidate, mid, line):
                await apply(try requireFlow(.remoteCandidate(candidate: candidate, mid: mid, line: line)))
            case .iceComplete:
                try await recorder?.record(event: "remote_ice_complete")
            case .sessionHangup:
                state = .ending
                await apply(try requireFlow(.remoteHangup))
            case let .serverError(code, message, _):
                await fail(code: code, message: message)
            default:
                break
            }
        } catch {
            await fail(code: "signaling_message_failed", error: error)
        }
    }

    private func bindCanonicalSessionID(_ sessionID: String) async throws {
        try await recorder?.bindSessionID(sessionID)
        currentSessionID = sessionID
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
            await apply(try requireFlow(.profileViolated(description)))
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
        remoteDescriptionReady = false
        pendingRemoteCandidates.removeAll(keepingCapacity: true)
    }
}

private enum SessionCoordinatorStartupError: Error, LocalizedError {
    case configuration(String)

    var errorDescription: String? {
        switch self {
        case .configuration(let message): message
        }
    }
}

extension SessionCoordinator: WebRTCSessionDelegate {
    nonisolated func webRTCSession(_ session: WebRTCSession, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                await self.apply(try self.requireFlow(.localCandidate(
                    candidate: candidate.sdp,
                    mid: candidate.sdpMid ?? "0",
                    line: candidate.sdpMLineIndex
                )))
            } catch {
                await self.fail(code: "local_ice_failed", error: error)
            }
        }
    }

    nonisolated func webRTCSessionDidCompleteICEGathering(_ session: WebRTCSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { await self.apply(try self.requireFlow(.localICEComplete)) }
            catch { await self.fail(code: "local_ice_failed", error: error) }
        }
    }

    nonisolated func webRTCSession(_ session: WebRTCSession, didChange state: RTCPeerConnectionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.recorder?.record(event: "peer_connection_state", fields: ["state": .string(String(describing: state))])
            switch state {
            case .connected:
                try? await self.recorder?.record(event: "peer_connection_connected")
                self.state = .connected(role: self.selectedRole)
                await self.recordImmediateSelectedPath(for: session)
                do { await self.apply(try self.requireFlow(.peerConnected)) }
                catch { await self.fail(code: "peer_connection_failed", error: error) }
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
                do { await self.apply(try self.requireFlow(.captureFailed(error.localizedDescription))) }
                catch { await self.fail(code: "capture_failed", error: error) }
            } else {
                await self.fail(code: "peer_session_failed", error: error)
            }
        }
    }
}
