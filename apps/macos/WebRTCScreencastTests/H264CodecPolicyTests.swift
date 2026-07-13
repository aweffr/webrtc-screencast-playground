import XCTest
@testable import WebRTCScreencast

final class H264CodecPolicyTests: XCTestCase {
    func testKeepsPacketizationModeOneH264AndAssociatedRTX() throws {
        let capabilities = [
            codec(96, "VP8"),
            codec(97, "rtx", ["apt": "96"]),
            codec(100, "H264", ["packetization-mode": "0", "profile-level-id": "42e01f"]),
            codec(101, "H264", ["packetization-mode": "1", "profile-level-id": "4d001f"]),
            codec(102, "rtx", ["apt": "101"]),
            codec(103, "H264", ["packetization-mode": "1", "profile-level-id": "42e01f"]),
            codec(104, "rtx", ["apt": "103"]),
            CodecCapabilityDescriptor(payloadType: 105, kind: "audio", name: "H264", parameters: ["packetization-mode": "1"]),
        ]

        let selected = try H264CodecPolicy.select(capabilities)

        XCTAssertEqual(selected.map(\.payloadType), [103, 104, 101, 102])
        XCTAssertTrue(selected.filter { $0.name.caseInsensitiveCompare("H264") == .orderedSame }
            .allSatisfy { $0.kind == "video" && $0.parameters["packetization-mode"] == "1" })
    }

    func testConstrainedBaselineIsPreferredOverOtherProfiles() throws {
        let selected = try H264CodecPolicy.select([
            codec(101, "H264", ["packetization-mode": "1", "profile-level-id": "64001f"]),
            codec(102, "H264", ["packetization-mode": "1", "profile-level-id": "42c01f"]),
            codec(103, "H264", ["packetization-mode": "1", "profile-level-id": "42e01f"]),
        ])

        XCTAssertEqual(selected.map(\.payloadType), [102, 103, 101])
    }

    func testMissingEligibleH264Fails() {
        XCTAssertThrowsError(try H264CodecPolicy.select([
            codec(96, "VP8"),
            codec(100, "H264", ["packetization-mode": "0"]),
        ]))
    }

    private func codec(
        _ payloadType: Int,
        _ name: String,
        _ parameters: [String: String] = [:]
    ) -> CodecCapabilityDescriptor {
        CodecCapabilityDescriptor(
            payloadType: payloadType,
            kind: "video",
            name: name,
            parameters: parameters
        )
    }
}
