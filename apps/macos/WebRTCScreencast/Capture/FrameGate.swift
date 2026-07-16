import Foundation

enum FrameGateState: String, Codable, Sendable {
    case motion15
    case detail15
    case quiet5
    case idle

    var minimumSubmitInterval: Duration? {
        switch self {
        case .motion15: .nanoseconds(66_666_667)
        case .detail15: .nanoseconds(66_666_667)
        case .quiet5: .milliseconds(200)
        case .idle: nil
        }
    }
}

struct FrameGateDecision: Equatable, Sendable {
    let shouldSubmit: Bool
    let state: FrameGateState
    let dirtyRatio: Double
}

struct FrameGate: Sendable {
    private(set) var state: FrameGateState = .idle
    private var stateEnteredAt: Duration?
    private var lastTimestamp: Duration?
    private var lastSubmittedAt: Duration?

    mutating func evaluate(dirtyRatio rawDirtyRatio: Double, timestamp: Duration) -> FrameGateDecision {
        let dirtyRatio = min(max(rawDirtyRatio, 0), 1)
        let isFirstFrame = lastTimestamp == nil
        if let lastTimestamp, timestamp < lastTimestamp {
            return FrameGateDecision(shouldSubmit: false, state: state, dirtyRatio: dirtyRatio)
        }
        lastTimestamp = timestamp

        let previousState = state
        if dirtyRatio >= 0.005 {
            transition(to: .motion15, at: timestamp)
        } else if dirtyRatio > 0 {
            if state == .motion15 {
                stateEnteredAt = timestamp
            } else {
                transition(to: .detail15, at: timestamp)
            }
        } else {
            downshiftIfNeeded(at: timestamp)
        }

        // ScreenCaptureKit may report its first complete frame without dirty rects.
        // WebRTC still needs that base image before the receiver can retain idle content.
        if isFirstFrame {
            lastSubmittedAt = timestamp
            return FrameGateDecision(shouldSubmit: true, state: state, dirtyRatio: dirtyRatio)
        }

        guard dirtyRatio > 0, let interval = state.minimumSubmitInterval else {
            return FrameGateDecision(shouldSubmit: false, state: state, dirtyRatio: dirtyRatio)
        }
        let upgraded = priority(of: state) > priority(of: previousState)
        let due = lastSubmittedAt.map { timestamp - $0 >= interval } ?? true
        let shouldSubmit = upgraded || due
        if shouldSubmit {
            lastSubmittedAt = timestamp
        }
        return FrameGateDecision(shouldSubmit: shouldSubmit, state: state, dirtyRatio: dirtyRatio)
    }

    private mutating func downshiftIfNeeded(at timestamp: Duration) {
        guard let stateEnteredAt else { return }
        let elapsed = timestamp - stateEnteredAt
        switch state {
        case .motion15 where elapsed >= .milliseconds(500):
            transition(to: .detail15, at: timestamp)
        case .detail15 where elapsed >= .milliseconds(800):
            transition(to: .quiet5, at: timestamp)
        case .quiet5 where elapsed >= .milliseconds(300):
            transition(to: .idle, at: timestamp)
        default:
            break
        }
    }

    private mutating func transition(to newState: FrameGateState, at timestamp: Duration) {
        if state != newState {
            state = newState
        }
        stateEnteredAt = timestamp
    }

    private func priority(of state: FrameGateState) -> Int {
        switch state {
        case .idle: 0
        case .quiet5: 1
        case .detail15: 2
        case .motion15: 3
        }
    }
}
