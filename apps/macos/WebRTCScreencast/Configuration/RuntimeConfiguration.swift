import CryptoKit
import Darwin
import Foundation

struct TURNCredentials: Decodable, Sendable {
    let url: URL
    let username: String
    let password: String
}

enum RuntimeConfigurationError: Error, LocalizedError, Equatable {
    case missingConfigPath
    case unreadableConfig(String)
    case invalidSignalingURL
    case missingTURN
    case invalidTURNURL
    case missingTURNCredentials
    case receiverExclusionRequiresDirectBaseline

    var errorDescription: String? {
        switch self {
        case .missingConfigPath: "--config requires a path"
        case .unreadableConfig(let path): "Cannot read runtime configuration at \(path)"
        case .invalidSignalingURL: "Signaling URL must use ws:// or wss://"
        case .missingTURN: "Production relay requires TURN configuration"
        case .invalidTURNURL: "Production relay requires an explicit turn: URL with transport=udp"
        case .missingTURNCredentials: "Production relay requires non-empty TURN credentials"
        case .receiverExclusionRequiresDirectBaseline: "Receiver exclusion is available only in direct baseline"
        }
    }
}

struct RuntimeConfiguration: Decodable, Sendable, CustomDebugStringConvertible {
    let signalingURL: URL
    let iceProfile: ICEProfile
    let turn: TURNCredentials?
    let metricsDirectory: URL
    let excludedReceiverPID: pid_t?

    enum CodingKeys: String, CodingKey {
        case signalingURL = "signaling_url"
        case iceProfile = "ice_profile"
        case turn
        case metricsDirectory = "metrics_directory"
        case excludedReceiverPID = "excluded_receiver_pid"
    }

    init(
        signalingURL: URL,
        iceProfile: ICEProfile,
        turn: TURNCredentials?,
        metricsDirectory: URL,
        excludedReceiverPID: pid_t?
    ) {
        self.signalingURL = signalingURL
        self.iceProfile = iceProfile
        self.turn = turn
        self.metricsDirectory = metricsDirectory
        self.excludedReceiverPID = excludedReceiverPID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        signalingURL = try container.decode(URL.self, forKey: .signalingURL)
        iceProfile = try container.decode(ICEProfile.self, forKey: .iceProfile)
        turn = try container.decodeIfPresent(TURNCredentials.self, forKey: .turn)
        let metricsPath = try container.decode(String.self, forKey: .metricsDirectory)
        metricsDirectory = URL(filePath: (metricsPath as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        excludedReceiverPID = try container.decodeIfPresent(pid_t.self, forKey: .excludedReceiverPID)
    }

    var debugDescription: String {
        "RuntimeConfiguration(signalingURL: \(signalingURL.absoluteString), iceProfile: \(iceProfile.rawValue), turn: <redacted>)"
    }

    static func decode(_ data: Data) throws -> RuntimeConfiguration {
        try JSONDecoder().decode(RuntimeConfiguration.self, from: data)
    }

    static func load(arguments: [String], fileManager: FileManager = .default) throws -> RuntimeConfiguration {
        let path: String
        if let optionIndex = arguments.firstIndex(of: "--config") {
            guard arguments.indices.contains(optionIndex + 1) else {
                throw RuntimeConfigurationError.missingConfigPath
            }
            path = arguments[optionIndex + 1]
        } else {
            guard let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw RuntimeConfigurationError.unreadableConfig("Application Support")
            }
            path = applicationSupport
                .appending(path: "WebRTCScreencast", directoryHint: .isDirectory)
                .appending(path: "runtime.json", directoryHint: .notDirectory)
                .path
        }
        guard let data = fileManager.contents(atPath: path) else {
            throw RuntimeConfigurationError.unreadableConfig(path)
        }
        let configuration = try decode(data)
        try configuration.validate()
        return configuration
    }

    func validate() throws {
        guard let scheme = signalingURL.scheme?.lowercased(), scheme == "ws" || scheme == "wss" else {
            throw RuntimeConfigurationError.invalidSignalingURL
        }
        if iceProfile == .productionRelay {
            guard let turn else {
                throw RuntimeConfigurationError.missingTURN
            }
            guard turn.url.scheme?.lowercased() == "turn",
                  URLComponents(url: turn.url, resolvingAgainstBaseURL: false)?
                    .queryItems?.contains(where: { $0.name.lowercased() == "transport" && $0.value?.lowercased() == "udp" }) == true
            else {
                throw RuntimeConfigurationError.invalidTURNURL
            }
            guard !turn.username.isEmpty, !turn.password.isEmpty else {
                throw RuntimeConfigurationError.missingTURNCredentials
            }
            if excludedReceiverPID != nil {
                throw RuntimeConfigurationError.receiverExclusionRequiresDirectBaseline
            }
        }
    }

    func effective(role: CastingRole, source: CaptureSourceKind?) throws -> EffectiveConfiguration {
        try validate()
        return try EffectiveConfiguration(
            signalingURL: signalingURL,
            iceProfile: iceProfile,
            role: role,
            source: source,
            turnURL: iceProfile == .productionRelay ? turn?.url : nil,
            metricsDirectory: metricsDirectory,
            excludedReceiverPID: excludedReceiverPID
        )
    }


    func overriding(
        signalingURL: URL? = nil,
        iceProfile: ICEProfile? = nil,
        excludedReceiverPID: pid_t? = nil
    ) -> RuntimeConfiguration {
        RuntimeConfiguration(
            signalingURL: signalingURL ?? self.signalingURL,
            iceProfile: iceProfile ?? self.iceProfile,
            turn: turn,
            metricsDirectory: metricsDirectory,
            excludedReceiverPID: excludedReceiverPID ?? self.excludedReceiverPID
        )
    }
}
