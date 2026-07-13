import Foundation

enum RTCStatisticValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }
}

struct RTCStatisticSnapshot: Equatable, Sendable {
    let id: String
    let type: String
    let values: [String: RTCStatisticValue]
}

enum SelectedPathVerificationStatus: String, Equatable, Sendable {
    case unknown
    case verified
    case violation
}

struct SelectedPathEvidence: Equatable, Sendable {
    let status: SelectedPathVerificationStatus
    let selectedPairID: String?
    let localCandidateType: String?
    let remoteCandidateType: String?
    let protocolValue: String?
}

enum SelectedPathVerifier {
    static func verify(
        profile: ICEProfile,
        statistics: [RTCStatisticSnapshot]
    ) -> SelectedPathEvidence {
        let byID = Dictionary(uniqueKeysWithValues: statistics.map { ($0.id, $0) })
        let transportPairID = statistics.first(where: { $0.type == "transport" })?
            .values["selectedCandidatePairId"]?.stringValue
        let fallbackPairID = statistics.first(where: { statistic in
            guard statistic.type == "candidate-pair" else { return false }
            return statistic.values["selected"] == .bool(true)
                || (statistic.values["nominated"] == .bool(true)
                    && statistic.values["state"]?.stringValue == "succeeded")
        })?.id
        guard let pairID = transportPairID ?? fallbackPairID,
              let pair = byID[pairID],
              pair.type == "candidate-pair",
              pair.values["state"]?.stringValue == "succeeded",
              let localID = pair.values["localCandidateId"]?.stringValue,
              let remoteID = pair.values["remoteCandidateId"]?.stringValue,
              let local = byID[localID],
              let remote = byID[remoteID] else {
            return SelectedPathEvidence(
                status: .unknown,
                selectedPairID: transportPairID ?? fallbackPairID,
                localCandidateType: nil,
                remoteCandidateType: nil,
                protocolValue: nil
            )
        }

        let localType = local.values["candidateType"]?.stringValue?.lowercased()
        let remoteType = remote.values["candidateType"]?.stringValue?.lowercased()
        let transport = (local.values["relayProtocol"]?.stringValue
            ?? local.values["protocol"]?.stringValue)?.lowercased()
        let isValid: Bool
        switch profile {
        case .directBaseline:
            isValid = localType != "relay" && remoteType != "relay"
        case .productionRelay:
            isValid = localType == "relay" && transport == "udp"
        }
        return SelectedPathEvidence(
            status: isValid ? .verified : .violation,
            selectedPairID: pairID,
            localCandidateType: localType,
            remoteCandidateType: remoteType,
            protocolValue: transport
        )
    }
}
