import XCTest
@testable import WebRTCScreencast

final class VideoCodecPolicyTests: XCTestCase {
    func testFourPoliciesDefineCodecSetAndOrder() {
        XCTAssertEqual(VideoCodecPolicy.h264Only.orderedCodecNames, ["H264"])
        XCTAssertEqual(VideoCodecPolicy.h265Only.orderedCodecNames, ["H265"])
        XCTAssertEqual(VideoCodecPolicy.preferH265.orderedCodecNames, ["H265", "H264"])
        XCTAssertEqual(VideoCodecPolicy.default.orderedCodecNames, ["H264", "H265"])
    }
}
