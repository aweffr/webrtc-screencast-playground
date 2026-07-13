import Foundation

enum SignalingProtocolError: Error, Equatable {
    case invalidVersion(Int)
    case invalidMessageID
    case invalidPairingCode
    case invalidPayload(String)
}

enum PairingCode {
    static func normalize(_ input: String) throws -> String {
        let normalized = input.uppercased().filter { character in
            character != "-" && !character.isWhitespace
        }
        let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        guard normalized.count == 8, normalized.allSatisfy(alphabet.contains) else {
            throw SignalingProtocolError.invalidPairingCode
        }
        return normalized
    }
}

enum SignalingMessageType: String, Codable, CaseIterable, Sendable {
    case receiverRegister = "receiver.register"
    case receiverRegistered = "receiver.registered"
    case senderJoin = "sender.join"
    case sessionPaired = "session.paired"
    case sdpOffer = "sdp.offer"
    case sdpAnswer = "sdp.answer"
    case iceCandidate = "ice.candidate"
    case iceComplete = "ice.complete"
    case sessionHangup = "session.hangup"
    case error
}

enum SignalingPayload: Equatable, Sendable {
    case receiverRegister
    case receiverRegistered(sessionID: String, pairingCode: String, expiresAt: Date)
    case senderJoin(pairingCode: String)
    case sessionPaired(sessionID: String, role: CastingRole)
    case sdpOffer(String)
    case sdpAnswer(String)
    case iceCandidate(candidate: String, sdpMid: String, sdpMLineIndex: Int32)
    case iceComplete
    case sessionHangup(reason: String?)
    case serverError(code: String, message: String, relatedMessageID: String?)

    var type: SignalingMessageType {
        switch self {
        case .receiverRegister: .receiverRegister
        case .receiverRegistered: .receiverRegistered
        case .senderJoin: .senderJoin
        case .sessionPaired: .sessionPaired
        case .sdpOffer: .sdpOffer
        case .sdpAnswer: .sdpAnswer
        case .iceCandidate: .iceCandidate
        case .iceComplete: .iceComplete
        case .sessionHangup: .sessionHangup
        case .serverError: .error
        }
    }
}

struct SignalingEnvelope: Equatable, Sendable, Codable {
    static let protocolVersion = 1

    let version: Int
    let messageID: String
    let payload: SignalingPayload

    var type: SignalingMessageType { payload.type }

    init(messageID: String, payload: SignalingPayload, version: Int = protocolVersion) {
        self.version = version
        self.messageID = messageID
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case messageID = "message_id"
        case type
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        messageID = try container.decode(String.self, forKey: .messageID)
        let type = try container.decode(SignalingMessageType.self, forKey: .type)
        guard version == Self.protocolVersion else {
            throw SignalingProtocolError.invalidVersion(version)
        }
        guard !messageID.isEmpty, messageID.utf8.count <= 64 else {
            throw SignalingProtocolError.invalidMessageID
        }

        switch type {
        case .receiverRegister:
            _ = try container.decode(EmptyPayload.self, forKey: .payload)
            payload = .receiverRegister
        case .receiverRegistered:
            let value = try container.decode(ReceiverRegisteredPayload.self, forKey: .payload)
            guard !value.sessionID.isEmpty else { throw SignalingProtocolError.invalidPayload("session_id") }
            payload = .receiverRegistered(
                sessionID: value.sessionID,
                pairingCode: try PairingCode.normalize(value.pairingCode),
                expiresAt: value.expiresAt
            )
        case .senderJoin:
            let value = try container.decode(SenderJoinPayload.self, forKey: .payload)
            payload = .senderJoin(pairingCode: try PairingCode.normalize(value.pairingCode))
        case .sessionPaired:
            let value = try container.decode(SessionPairedPayload.self, forKey: .payload)
            guard !value.sessionID.isEmpty else { throw SignalingProtocolError.invalidPayload("session_id") }
            payload = .sessionPaired(sessionID: value.sessionID, role: value.role)
        case .sdpOffer, .sdpAnswer:
            let value = try container.decode(SDPPayload.self, forKey: .payload)
            guard !value.sdp.isEmpty, value.sdp.utf8.count <= 128 * 1024 else {
                throw SignalingProtocolError.invalidPayload("sdp")
            }
            payload = type == .sdpOffer ? .sdpOffer(value.sdp) : .sdpAnswer(value.sdp)
        case .iceCandidate:
            let value = try container.decode(ICECandidatePayload.self, forKey: .payload)
            guard !value.candidate.isEmpty,
                  value.candidate.utf8.count <= 16 * 1024,
                  value.sdpMid.utf8.count <= 256,
                  value.sdpMLineIndex >= 0 else {
                throw SignalingProtocolError.invalidPayload("ice candidate")
            }
            payload = .iceCandidate(
                candidate: value.candidate,
                sdpMid: value.sdpMid,
                sdpMLineIndex: value.sdpMLineIndex
            )
        case .iceComplete:
            _ = try container.decode(EmptyPayload.self, forKey: .payload)
            payload = .iceComplete
        case .sessionHangup:
            let value = try container.decode(SessionHangupPayload.self, forKey: .payload)
            guard (value.reason?.utf8.count ?? 0) <= 256 else {
                throw SignalingProtocolError.invalidPayload("hangup reason")
            }
            payload = .sessionHangup(reason: value.reason)
        case .error:
            let value = try container.decode(ErrorPayload.self, forKey: .payload)
            guard !value.code.isEmpty,
                  !value.message.isEmpty,
                  value.code.utf8.count <= 64,
                  value.message.utf8.count <= 512,
                  (value.relatedMessageID?.utf8.count ?? 0) <= 64 else {
                throw SignalingProtocolError.invalidPayload("server error")
            }
            payload = .serverError(
                code: value.code,
                message: value.message,
                relatedMessageID: value.relatedMessageID
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        guard version == Self.protocolVersion else { throw SignalingProtocolError.invalidVersion(version) }
        guard !messageID.isEmpty, messageID.utf8.count <= 64 else { throw SignalingProtocolError.invalidMessageID }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(messageID, forKey: .messageID)
        try container.encode(type, forKey: .type)
        switch payload {
        case .receiverRegister:
            try container.encode(EmptyPayload(), forKey: .payload)
        case let .receiverRegistered(sessionID, pairingCode, expiresAt):
            try container.encode(
                ReceiverRegisteredPayload(sessionID: sessionID, pairingCode: try PairingCode.normalize(pairingCode), expiresAt: expiresAt),
                forKey: .payload
            )
        case let .senderJoin(pairingCode):
            try container.encode(SenderJoinPayload(pairingCode: try PairingCode.normalize(pairingCode)), forKey: .payload)
        case let .sessionPaired(sessionID, role):
            try container.encode(SessionPairedPayload(sessionID: sessionID, role: role), forKey: .payload)
        case let .sdpOffer(sdp), let .sdpAnswer(sdp):
            try container.encode(SDPPayload(sdp: sdp), forKey: .payload)
        case let .iceCandidate(candidate, sdpMid, sdpMLineIndex):
            try container.encode(
                ICECandidatePayload(candidate: candidate, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex),
                forKey: .payload
            )
        case .iceComplete:
            try container.encode(EmptyPayload(), forKey: .payload)
        case let .sessionHangup(reason):
            try container.encode(SessionHangupPayload(reason: reason), forKey: .payload)
        case let .serverError(code, message, relatedMessageID):
            try container.encode(
                ErrorPayload(code: code, message: message, relatedMessageID: relatedMessageID),
                forKey: .payload
            )
        }
    }
}

enum SignalingCodec {
    static func decode(_ data: Data) throws -> SignalingEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SignalingEnvelope.self, from: data)
    }

    static func encode(_ envelope: SignalingEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }
}

private struct EmptyPayload: Codable {}

private struct ReceiverRegisteredPayload: Codable {
    let sessionID: String
    let pairingCode: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case pairingCode = "pairing_code"
        case expiresAt = "expires_at"
    }
}

private struct SenderJoinPayload: Codable {
    let pairingCode: String
    enum CodingKeys: String, CodingKey { case pairingCode = "pairing_code" }
}

private struct SessionPairedPayload: Codable {
    let sessionID: String
    let role: CastingRole
    enum CodingKeys: String, CodingKey { case sessionID = "session_id"; case role }
}

private struct SDPPayload: Codable { let sdp: String }

private struct ICECandidatePayload: Codable {
    let candidate: String
    let sdpMid: String
    let sdpMLineIndex: Int32

    enum CodingKeys: String, CodingKey {
        case candidate
        case sdpMid = "sdp_mid"
        case sdpMLineIndex = "sdp_mline_index"
    }
}

private struct SessionHangupPayload: Codable { let reason: String? }

private struct ErrorPayload: Codable {
    let code: String
    let message: String
    let relatedMessageID: String?
    enum CodingKeys: String, CodingKey {
        case code, message
        case relatedMessageID = "related_message_id"
    }
}
