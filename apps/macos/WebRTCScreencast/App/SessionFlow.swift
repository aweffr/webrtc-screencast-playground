import Foundation

enum SessionFlowEvent: Equatable, Sendable {
    case start
    case signalingConnected
    case receiverRegistered(code: String)
    case peerPaired
    case remoteOffer(String)
    case remoteAnswer(String)
    case remoteCandidate(candidate: String, mid: String, line: Int32)
    case localCandidate(candidate: String, mid: String, line: Int32)
    case localICEComplete
    case peerConnected
    case remoteHangup
    case stopRequested
    case captureFailed(String)
    case profileViolated(String)
    case fatalFailure(code: String, message: String)
}

enum SessionFlowCommand: Equatable, Sendable {
    case connectSignaling
    case registerReceiver
    case join(String)
    case publishPairingCode(String)
    case createAndSendOffer
    case setRemoteOffer(String)
    case createAndSendAnswer
    case setRemoteAnswer(String)
    case addRemoteCandidate(candidate: String, mid: String, line: Int32)
    case sendCandidate(candidate: String, mid: String, line: Int32)
    case sendICEComplete
    case startCapture
    case reportFailure(code: String, message: String)
    case stopSampler
    case stopCapture
    case closeSignaling
    case closePeer
    case stopVirtualDisplay
    case closeMetrics
}

struct SessionFlow: Sendable {
    let role: CastingRole
    let senderCode: String?

    private(set) var pairingCode: String?
    private(set) var connected = false
    private var signalingStarted = false
    private var joined = false
    private var tornDown = false

    init(role: CastingRole, senderCode: String?) {
        self.role = role
        self.senderCode = senderCode
    }

    mutating func handle(_ event: SessionFlowEvent) throws -> [SessionFlowCommand] {
        if tornDown { return [] }

        switch event {
        case .start:
            guard !signalingStarted else { return [] }
            signalingStarted = true
            return [.connectSignaling]

        case .signalingConnected:
            guard signalingStarted else { return [] }
            if role == .receiver { return [.registerReceiver] }
            guard !joined, let senderCode else { return [] }
            joined = true
            return [.join(try PairingCode.normalize(senderCode))]

        case .receiverRegistered(let code):
            guard role == .receiver else { return [] }
            let normalized = try PairingCode.normalize(code)
            pairingCode = normalized
            return [.publishPairingCode(normalized)]

        case .peerPaired:
            return role == .sender ? [.createAndSendOffer] : []

        case .remoteOffer(let sdp):
            guard role == .receiver else { return [] }
            return [.setRemoteOffer(sdp), .createAndSendAnswer]

        case .remoteAnswer(let sdp):
            guard role == .sender else { return [] }
            return [.setRemoteAnswer(sdp)]

        case let .remoteCandidate(candidate, mid, line):
            return [.addRemoteCandidate(candidate: candidate, mid: mid, line: line)]

        case let .localCandidate(candidate, mid, line):
            return [.sendCandidate(candidate: candidate, mid: mid, line: line)]

        case .localICEComplete:
            return [.sendICEComplete]

        case .peerConnected:
            guard !connected else { return [] }
            connected = true
            return role == .sender ? [.startCapture] : []

        case .remoteHangup, .stopRequested:
            return teardown()

        case .captureFailed(let message):
            return [.reportFailure(code: "capture_failed", message: message)] + teardown()

        case .profileViolated(let message):
            return [.reportFailure(code: "profile_violation", message: message)] + teardown()

        case let .fatalFailure(code, message):
            return [.reportFailure(code: code, message: message)] + teardown()
        }
    }

    private mutating func teardown() -> [SessionFlowCommand] {
        guard !tornDown else { return [] }
        tornDown = true
        connected = false
        return [
            .stopSampler,
            .stopCapture,
            .closeSignaling,
            .closePeer,
            .stopVirtualDisplay,
            .closeMetrics,
        ]
    }
}
