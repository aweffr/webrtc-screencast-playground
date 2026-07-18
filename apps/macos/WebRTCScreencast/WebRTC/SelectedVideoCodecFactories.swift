import Foundation
@preconcurrency import WebRTC

final class SelectedVideoEncoderFactory: NSObject, RTCVideoEncoderFactory {
    private let base = RTCDefaultVideoEncoderFactory()
    private let policy: VideoCodecPolicy
    private let h264ProfileLevelIDOverride: String?

    init(policy: VideoCodecPolicy, h264ProfileLevelIDOverride: String? = nil) {
        self.policy = policy
        self.h264ProfileLevelIDOverride = h264ProfileLevelIDOverride
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        orderedCodecs(
            base.supportedCodecs(),
            policy: policy,
            h264ProfileLevelIDOverride: h264ProfileLevelIDOverride
        )
    }

    func createEncoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoEncoder)? {
        if info.name.caseInsensitiveCompare("H265") == .orderedSame {
            return RTCVideoEncoderH265(codecInfo: info)
        }
        return base.createEncoder(info)
    }
}

final class SelectedVideoDecoderFactory: NSObject, RTCVideoDecoderFactory {
    private let base = RTCDefaultVideoDecoderFactory()
    private let policy: VideoCodecPolicy
    private let h264ProfileLevelIDOverride: String?

    init(policy: VideoCodecPolicy, h264ProfileLevelIDOverride: String? = nil) {
        self.policy = policy
        self.h264ProfileLevelIDOverride = h264ProfileLevelIDOverride
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        orderedCodecs(
            base.supportedCodecs(),
            policy: policy,
            h264ProfileLevelIDOverride: h264ProfileLevelIDOverride
        )
    }

    func createDecoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoDecoder)? {
        if info.name.caseInsensitiveCompare("H265") == .orderedSame {
            return RTCVideoDecoderH265()
        }
        return base.createDecoder(info)
    }
}

private func orderedCodecs(
    _ baseCodecs: [RTCVideoCodecInfo],
    policy: VideoCodecPolicy,
    h264ProfileLevelIDOverride: String?
) -> [RTCVideoCodecInfo] {
    let baseH264 = baseCodecs.filter {
        $0.name.caseInsensitiveCompare("H264") == .orderedSame
            && $0.parameters["packetization-mode"] == "1"
    }
    let h264: [RTCVideoCodecInfo]
    if let h264ProfileLevelIDOverride, let codec = baseH264.first {
        var parameters = codec.parameters
        parameters["profile-level-id"] = h264ProfileLevelIDOverride
        h264 = [RTCVideoCodecInfo(
            name: codec.name,
            parameters: parameters,
            scalabilityModes: codec.scalabilityModes
        )]
    } else {
        h264 = baseH264
    }
    let h265 = [RTCVideoCodecInfo(name: "H265")]
    let codecsByName = ["H264": h264, "H265": h265]
    return policy.orderedCodecNames.flatMap { codecsByName[$0] ?? [] }
}
