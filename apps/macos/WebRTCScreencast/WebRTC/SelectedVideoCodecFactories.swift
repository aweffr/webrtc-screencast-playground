import Foundation
@preconcurrency import WebRTC

final class SelectedVideoEncoderFactory: NSObject, RTCVideoEncoderFactory {
    private let base = RTCDefaultVideoEncoderFactory()
    private let policy: VideoCodecPolicy

    init(policy: VideoCodecPolicy) {
        self.policy = policy
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        orderedCodecs(base.supportedCodecs(), policy: policy)
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

    init(policy: VideoCodecPolicy) {
        self.policy = policy
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        orderedCodecs(base.supportedCodecs(), policy: policy)
    }

    func createDecoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoDecoder)? {
        if info.name.caseInsensitiveCompare("H265") == .orderedSame {
            return RTCVideoDecoderH265()
        }
        return base.createDecoder(info)
    }
}

private func orderedCodecs(_ baseCodecs: [RTCVideoCodecInfo], policy: VideoCodecPolicy) -> [RTCVideoCodecInfo] {
    let h264 = baseCodecs.filter {
        $0.name.caseInsensitiveCompare("H264") == .orderedSame
            && $0.parameters["packetization-mode"] == "1"
    }
    let h265 = [RTCVideoCodecInfo(name: "H265")]
    let codecsByName = ["H264": h264, "H265": h265]
    return policy.orderedCodecNames.flatMap { codecsByName[$0] ?? [] }
}
