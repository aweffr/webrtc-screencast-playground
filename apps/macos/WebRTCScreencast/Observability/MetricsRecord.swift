import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

struct MetricsContext: Equatable, Sendable {
    let schemaVersion: Int
    let sessionID: String
    let role: CastingRole
    let profile: ICEProfile
    let effectiveConfigHash: String
    let tuningRevision: UInt64
}

struct MetricsRecord: Codable, Sendable {
    let schemaVersion: Int
    let sessionID: String
    let role: CastingRole
    let profile: ICEProfile
    let effectiveConfigHash: String
    let tuningRevision: UInt64
    let wallTime: String
    let monotonicNs: UInt64
    let event: String
    let fields: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionID = "session_id"
        case role, profile
        case effectiveConfigHash = "effective_config_hash"
        case tuningRevision = "tuning_revision"
        case wallTime = "wall_time"
        case monotonicNs = "monotonic_ns"
        case event, fields
    }
}
