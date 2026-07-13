import Foundation
@preconcurrency import WebRTC

final class H264OnlyVideoEncoderFactory: NSObject, RTCVideoEncoderFactory {
    private let base = RTCDefaultVideoEncoderFactory()

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        base.supportedCodecs().filter {
            H264CodecPolicy.isEligible(name: $0.name, parameters: $0.parameters)
        }.map(H264CodecPolicy.normalize)
    }

    func createEncoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoEncoder)? {
        base.createEncoder(info)
    }
}

final class H264OnlyVideoDecoderFactory: NSObject, RTCVideoDecoderFactory {
    private let base = RTCDefaultVideoDecoderFactory()

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        base.supportedCodecs().filter {
            H264CodecPolicy.isEligible(name: $0.name, parameters: $0.parameters)
        }.map(H264CodecPolicy.normalize)
    }

    func createDecoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoDecoder)? {
        base.createDecoder(info)
    }
}
