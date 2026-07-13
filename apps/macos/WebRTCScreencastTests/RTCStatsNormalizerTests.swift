import XCTest
@testable import WebRTCScreencast

final class RTCStatsNormalizerTests: XCTestCase {
    func testNormalizesOutboundCodecRemoteInboundAndSelectedPath() {
        var normalizer = RTCStatsNormalizer(profile: .productionRelay)
        let sample = normalizer.normalize(timestampUs: 1_000_000, statistics: [
            stat("codec-1", "codec", ["mimeType": .string("video/H264")]),
            stat("out-1", "outbound-rtp", [
                "kind": .string("video"), "codecId": .string("codec-1"),
                "bytesSent": .number(1_000), "framesEncoded": .string("20"),
                "qpSum": .number(400), "remoteId": .string("remote-in-1"),
                "encoderImplementation": .string("VideoToolbox"),
            ]),
            stat("remote-in-1", "remote-inbound-rtp", [
                "roundTripTime": .number(0.025), "packetsLost": .number(2),
            ]),
        ] + selectedPath())

        XCTAssertEqual(sample.outbound?.codecMimeType, "video/H264")
        XCTAssertEqual(sample.outbound?.bytes, 1_000)
        XCTAssertEqual(sample.outbound?.frames, 20)
        XCTAssertEqual(sample.outbound?.averageQP, 20)
        XCTAssertEqual(sample.outbound?.implementation, "VideoToolbox")
        XCTAssertEqual(sample.remoteInbound?.roundTripTimeMs, 25)
        XCTAssertEqual(sample.remoteInbound?.packetsLost, 2)
        XCTAssertEqual(sample.selectedPath.status, .verified)
        XCTAssertEqual(sample.selectedPath.localCandidateType, "relay")
        XCTAssertNil(sample.outbound?.bitrateBps)
    }

    func testDerivesRatesFromCounterDeltasWithoutInventingMissingValues() {
        var normalizer = RTCStatsNormalizer(profile: .directBaseline)
        _ = normalizer.normalize(timestampUs: 1_000_000, statistics: [
            stat("out", "outbound-rtp", ["kind": .string("video"), "bytesSent": .number(1_000), "framesEncoded": .number(10)]),
        ])
        let sample = normalizer.normalize(timestampUs: 2_000_000, statistics: [
            stat("out", "outbound-rtp", ["kind": .string("video"), "bytesSent": .number(126_000), "framesEncoded": .number(40)]),
        ])

        XCTAssertEqual(sample.outbound?.bitrateBps, 1_000_000)
        XCTAssertEqual(sample.outbound?.framesPerSecond, 30)
        XCTAssertNil(sample.outbound?.averageQP)
        XCTAssertNil(sample.remoteInbound)
    }

    func testNormalizesInboundAndCoercesSafeNumericStrings() {
        var normalizer = RTCStatsNormalizer(profile: .directBaseline)
        let sample = normalizer.normalize(timestampUs: 1, statistics: [
            stat("codec", "codec", ["mimeType": .string("video/H264")]),
            stat("in", "inbound-rtp", [
                "kind": .string("video"), "codecId": .string("codec"),
                "bytesReceived": .string("4096"), "framesDecoded": .string("12"),
                "framesDropped": .number(1), "qpSum": .number(120),
            ]),
        ])

        XCTAssertEqual(sample.inbound?.bytes, 4_096)
        XCTAssertEqual(sample.inbound?.frames, 12)
        XCTAssertEqual(sample.inbound?.framesDropped, 1)
        XCTAssertEqual(sample.inbound?.averageQP, 10)
        XCTAssertEqual(sample.inbound?.codecMimeType, "video/H264")
        XCTAssertNil(sample.inbound?.decoderImplementation)
    }

    func testInvalidOrDecreasingCountersDoNotProduceRates() {
        var normalizer = RTCStatsNormalizer(profile: .directBaseline)
        _ = normalizer.normalize(timestampUs: 2_000_000, statistics: [
            stat("out", "outbound-rtp", ["kind": .string("video"), "bytesSent": .number(100), "framesEncoded": .number(10)]),
        ])
        let sample = normalizer.normalize(timestampUs: 1_000_000, statistics: [
            stat("out", "outbound-rtp", ["kind": .string("video"), "bytesSent": .number(50), "framesEncoded": .string("not-a-number")]),
        ])
        XCTAssertNil(sample.outbound?.bitrateBps)
        XCTAssertNil(sample.outbound?.frames)
    }

    private func stat(_ id: String, _ type: String, _ values: [String: RTCStatisticValue]) -> RTCStatisticSnapshot {
        RTCStatisticSnapshot(id: id, type: type, values: values)
    }

    private func selectedPath() -> [RTCStatisticSnapshot] {
        [
            stat("transport", "transport", ["selectedCandidatePairId": .string("pair")]),
            stat("pair", "candidate-pair", [
                "state": .string("succeeded"),
                "localCandidateId": .string("local"),
                "remoteCandidateId": .string("remote"),
            ]),
            stat("local", "local-candidate", [
                "candidateType": .string("relay"), "relayProtocol": .string("udp"),
            ]),
            stat("remote", "remote-candidate", [
                "candidateType": .string("host"), "protocol": .string("udp"),
            ]),
        ]
    }
}
