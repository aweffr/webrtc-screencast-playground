import Foundation
import WebRTC

enum IceServerProviderError: Error, Equatable {
    case missingTURN
    case invalidTURNURL
    case missingCredentials
}

struct IceConfigurationEvidence: CustomStringConvertible, Equatable, Sendable {
    let profile: ICEProfile
    let transportPolicy: String
    let tcpCandidatesEnabled: Bool
    let turnURL: String?

    var description: String {
        "IceConfigurationEvidence(profile: \(profile.rawValue), transportPolicy: \(transportPolicy), tcpCandidatesEnabled: \(tcpCandidatesEnabled), turnURL: \(turnURL ?? "none"))"
    }
}

struct IceConfigurationResult {
    let configuration: RTCConfiguration
    let evidence: IceConfigurationEvidence
}

enum IceServerProvider {
    static func make(profile: ICEProfile, turn: TURNCredentials?) throws -> IceConfigurationResult {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.tcpCandidatePolicy = .disabled
        configuration.continualGatheringPolicy = .gatherContinually

        switch profile {
        case .directBaseline:
            configuration.iceTransportPolicy = .all
            configuration.iceServers = []
            return IceConfigurationResult(
                configuration: configuration,
                evidence: IceConfigurationEvidence(
                    profile: profile,
                    transportPolicy: "all",
                    tcpCandidatesEnabled: false,
                    turnURL: nil
                )
            )
        case .productionRelay:
            guard let turn else { throw IceServerProviderError.missingTURN }
            guard turn.url.scheme?.lowercased() == "turn",
                  URLComponents(url: turn.url, resolvingAgainstBaseURL: false)?
                    .queryItems?.contains(where: {
                        $0.name.lowercased() == "transport" && $0.value?.lowercased() == "udp"
                    }) == true else {
                throw IceServerProviderError.invalidTURNURL
            }
            guard !turn.username.isEmpty, !turn.password.isEmpty else {
                throw IceServerProviderError.missingCredentials
            }
            configuration.iceTransportPolicy = .relay
            configuration.iceServers = [RTCIceServer(
                urlStrings: [turn.url.absoluteString],
                username: turn.username,
                credential: turn.password
            )]
            return IceConfigurationResult(
                configuration: configuration,
                evidence: IceConfigurationEvidence(
                    profile: profile,
                    transportPolicy: "relay",
                    tcpCandidatesEnabled: false,
                    turnURL: turn.url.absoluteString
                )
            )
        }
    }
}
