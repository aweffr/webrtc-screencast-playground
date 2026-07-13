import CryptoKit
import Darwin
import Foundation

struct EffectiveConfiguration: Sendable {
    let signalingURL: URL
    let iceProfile: ICEProfile
    let role: CastingRole
    let source: CaptureSourceKind?
    let turnURL: URL?
    let metricsDirectory: URL
    let excludedReceiverPID: pid_t?
    let hash: String

    private let canonicalData: Data

    private struct Sanitized: Encodable {
        let signalingURL: String
        let iceProfile: ICEProfile
        let role: CastingRole
        let source: CaptureSourceKind?
        let turnURL: String?
        let metricsDirectory: String
        let excludedReceiverPID: pid_t?

        enum CodingKeys: String, CodingKey {
            case signalingURL = "signaling_url"
            case iceProfile = "ice_profile"
            case role
            case source
            case turnURL = "turn_url"
            case metricsDirectory = "metrics_directory"
            case excludedReceiverPID = "excluded_receiver_pid"
        }
    }

    init(
        signalingURL: URL,
        iceProfile: ICEProfile,
        role: CastingRole,
        source: CaptureSourceKind?,
        turnURL: URL?,
        metricsDirectory: URL,
        excludedReceiverPID: pid_t?
    ) throws {
        self.signalingURL = signalingURL
        self.iceProfile = iceProfile
        self.role = role
        self.source = source
        self.turnURL = turnURL
        self.metricsDirectory = metricsDirectory
        self.excludedReceiverPID = excludedReceiverPID
        let sanitized = Sanitized(
            signalingURL: signalingURL.absoluteString,
            iceProfile: iceProfile,
            role: role,
            source: source,
            turnURL: turnURL?.absoluteString,
            metricsDirectory: metricsDirectory.path,
            excludedReceiverPID: excludedReceiverPID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        canonicalData = try encoder.encode(sanitized)
        hash = SHA256.hash(data: canonicalData).map { String(format: "%02x", $0) }.joined()
    }

    func canonicalJSON() throws -> Data {
        canonicalData
    }
}
