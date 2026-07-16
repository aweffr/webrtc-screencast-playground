import XCTest
@testable import WebRTCScreencast

final class SelectedPathVerifierTests: XCTestCase {
    func testUnknownUntilSelectedPairCanBeLinked() {
        let evidence = SelectedPathVerifier.verify(profile: .productionRelay, statistics: [])
        XCTAssertEqual(evidence.status, .unknown)
    }

    func testDirectBaselineAcceptsNonRelayUDP() {
        let evidence = SelectedPathVerifier.verify(
            profile: .directBaseline,
            statistics: selectedPath(localType: "host", protocolValue: "udp")
        )
        XCTAssertEqual(evidence.status, .verified)
        XCTAssertEqual(evidence.localCandidateType, "host")
        XCTAssertEqual(evidence.protocolValue, "udp")
    }

    func testDirectBaselineRejectsRelayPath() {
        let evidence = SelectedPathVerifier.verify(
            profile: .directBaseline,
            statistics: selectedPath(localType: "relay", protocolValue: "udp")
        )
        XCTAssertEqual(evidence.status, .violation)
    }

    func testDirectBaselineRejectsNonUdpPath() {
        let evidence = SelectedPathVerifier.verify(
            profile: .directBaseline,
            statistics: selectedPath(localType: "host", protocolValue: "tcp")
        )
        XCTAssertEqual(evidence.status, .violation)
    }

    func testProductionRequiresRelayAndUDP() {
        XCTAssertEqual(SelectedPathVerifier.verify(
            profile: .productionRelay,
            statistics: selectedPath(
                localType: "relay",
                remoteType: "relay",
                protocolValue: "udp"
            )
        ).status, .verified)
        XCTAssertEqual(SelectedPathVerifier.verify(
            profile: .productionRelay,
            statistics: selectedPath(localType: "host", protocolValue: "udp")
        ).status, .violation)
        XCTAssertEqual(SelectedPathVerifier.verify(
            profile: .productionRelay,
            statistics: selectedPath(
                localType: "relay",
                remoteType: "relay",
                protocolValue: "tcp"
            )
        ).status, .violation)
        XCTAssertEqual(SelectedPathVerifier.verify(
            profile: .productionRelay,
            statistics: selectedPath(localType: "relay", protocolValue: "udp")
        ).status, .violation)
    }

    private func selectedPath(
        localType: String,
        remoteType: String = "host",
        protocolValue: String
    ) -> [RTCStatisticSnapshot] {
        [
            RTCStatisticSnapshot(
                id: "transport-1",
                type: "transport",
                values: ["selectedCandidatePairId": .string("pair-1")]
            ),
            RTCStatisticSnapshot(
                id: "pair-1",
                type: "candidate-pair",
                values: [
                    "state": .string("succeeded"),
                    "localCandidateId": .string("local-1"),
                    "remoteCandidateId": .string("remote-1"),
                ]
            ),
            RTCStatisticSnapshot(
                id: "local-1",
                type: "local-candidate",
                values: [
                    "candidateType": .string(localType),
                    "protocol": .string(protocolValue),
                ]
            ),
            RTCStatisticSnapshot(
                id: "remote-1",
                type: "remote-candidate",
                values: [
                    "candidateType": .string(remoteType),
                    "protocol": .string("udp"),
                ]
            ),
        ]
    }
}
