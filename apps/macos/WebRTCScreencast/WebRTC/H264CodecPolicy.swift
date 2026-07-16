import Foundation
import WebRTC

struct CodecCapabilityDescriptor: Equatable, Sendable {
    let payloadType: Int?
    let kind: String
    let name: String
    let parameters: [String: String]
}

enum H264CodecPolicyError: Error, Equatable {
    case noEligibleH264
}

enum H264CodecPolicy {
    static let requiredProfileLevelID = "42e029"

    static func isEligible(name: String, parameters: [String: String]) -> Bool {
        name.caseInsensitiveCompare("H264") == .orderedSame
            && parameters["packetization-mode"] == "1"
    }

    static func select(_ capabilities: [CodecCapabilityDescriptor]) throws -> [CodecCapabilityDescriptor] {
        let eligibleH264 = capabilities.enumerated().filter { _, capability in
            capability.kind.caseInsensitiveCompare("video") == .orderedSame
                && isEligible(name: capability.name, parameters: capability.parameters)
        }
        guard !eligibleH264.isEmpty else { throw H264CodecPolicyError.noEligibleH264 }

        let orderedH264 = eligibleH264.sorted { lhs, rhs in
            let leftRank = profileRank(lhs.element.parameters["profile-level-id"])
            let rightRank = profileRank(rhs.element.parameters["profile-level-id"])
            return leftRank == rightRank ? lhs.offset < rhs.offset : leftRank < rightRank
        }.map(\.element)

        let rtxByAssociatedPayload = Dictionary(grouping: capabilities.filter { capability in
            capability.kind.caseInsensitiveCompare("video") == .orderedSame
                && capability.name.caseInsensitiveCompare("rtx") == .orderedSame
                && capability.parameters["apt"] != nil
        }) { $0.parameters["apt"]! }

        return orderedH264.flatMap { h264 -> [CodecCapabilityDescriptor] in
            guard let payloadType = h264.payloadType else { return [h264] }
            return [h264] + (rtxByAssociatedPayload[String(payloadType)] ?? [])
        }
    }

    static func selectCapabilities(_ capabilities: [RTCRtpCodecCapability]) throws -> [RTCRtpCodecCapability] {
        let descriptors = capabilities.map { capability in
            CodecCapabilityDescriptor(
                payloadType: capability.preferredPayloadType?.intValue,
                kind: capability.kind,
                name: capability.name,
                parameters: capability.parameters
            )
        }
        let selected = try select(descriptors)
        var remaining = Array(zip(descriptors, capabilities))
        return selected.compactMap { descriptor in
            guard let index = remaining.firstIndex(where: { $0.0 == descriptor }) else { return nil }
            return remaining.remove(at: index).1
        }
    }

    static func normalize(_ codec: RTCVideoCodecInfo) -> RTCVideoCodecInfo {
        var parameters = codec.parameters
        parameters["profile-level-id"] = requiredProfileLevelID
        return RTCVideoCodecInfo(
            name: codec.name,
            parameters: parameters,
            scalabilityModes: codec.scalabilityModes
        )
    }

    private static func profileRank(_ profileLevelID: String?) -> Int {
        guard let value = profileLevelID?.lowercased() else { return 2 }
        if value.hasPrefix("42c0") { return 0 }
        if value.hasPrefix("42") { return 1 }
        return 2
    }
}
