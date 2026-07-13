import Foundation

struct SessionFailure: Error, Equatable, Sendable {
    let code: String
    let message: String
}

enum SessionState: Equatable, Sendable {
    case idle
    case connectingSignaling(role: CastingRole)
    case waitingForPeer(role: CastingRole)
    case negotiating(role: CastingRole)
    case connected(role: CastingRole)
    case ending
    case failed(SessionFailure)
}

enum SessionEvent: Equatable, Sendable {
    case begin(role: CastingRole)
    case signalingConnected
    case senderJoinRequested(code: String)
    case peerPaired
    case localOfferCreated
    case negotiationCompleted
    case endRequested
    case ended
    case failed(SessionFailure)
}

struct InvalidSessionTransition: Error, Equatable, Sendable {
    let state: SessionState
    let event: SessionEvent
}

struct SessionStateMachine: Sendable {
    private(set) var state: SessionState = .idle

    mutating func handle(_ event: SessionEvent) throws {
        switch (state, event) {
        case (.idle, .begin(let role)):
            state = .connectingSignaling(role: role)
        case (.connectingSignaling(let role), .signalingConnected):
            state = .waitingForPeer(role: role)
        case (.waitingForPeer(role: .sender), .senderJoinRequested):
            break
        case (.waitingForPeer(let role), .peerPaired):
            state = .negotiating(role: role)
        case (.negotiating(role: .sender), .localOfferCreated):
            break
        case (.negotiating(let role), .negotiationCompleted):
            state = .connected(role: role)
        case (.idle, .ended), (.ending, .endRequested):
            break
        case (_, .endRequested):
            state = .ending
        case (_, .ended):
            state = .idle
        case (_, .failed(let failure)):
            state = .failed(failure)
        default:
            throw InvalidSessionTransition(state: state, event: event)
        }
    }
}
