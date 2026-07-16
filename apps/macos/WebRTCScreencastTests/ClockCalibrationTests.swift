import Foundation
import XCTest
@testable import WebRTCScreencast

final class ClockCalibrationTests: XCTestCase {
    func testChooseUsesLowestRoundTripSample() throws {
        let calibration = try ClockCalibration.choose([
            .init(startedMonotonicNs: 1_000, finishedMonotonicNs: 1_500, serverUnixNs: 10_200),
            .init(startedMonotonicNs: 2_000, finishedMonotonicNs: 2_100, serverUnixNs: 11_050),
        ])

        XCTAssertEqual(calibration.roundTripNs, 100)
        XCTAssertEqual(calibration.offsetNs, 9_000)
        XCTAssertEqual(calibration.uncertaintyNs, 50)
        XCTAssertEqual(calibration.sampleCount, 2)
        XCTAssertEqual(try calibration.commonTimeNs(monotonicNs: 3_000), 12_000)
    }

    func testChooseRejectsEmptyNonIncreasingAndOverflowingSamples() throws {
        XCTAssertThrowsError(try ClockCalibration.choose([]))
        XCTAssertThrowsError(try ClockCalibration.choose([
            .init(startedMonotonicNs: 100, finishedMonotonicNs: 100, serverUnixNs: 1_000),
        ]))
        XCTAssertThrowsError(try ClockCalibration.choose([
            .init(startedMonotonicNs: 101, finishedMonotonicNs: 100, serverUnixNs: 1_000),
        ]))

        let calibration = try ClockCalibration.choose([
            .init(startedMonotonicNs: 100, finishedMonotonicNs: 200, serverUnixNs: 1_150),
        ])
        XCTAssertThrowsError(try calibration.commonTimeNs(monotonicNs: .max))
    }

    func testClockEndpointFollowsSignalingSecurityScheme() throws {
        XCTAssertEqual(
            try ClockCalibrationClient.endpoint(for: XCTUnwrap(URL(string: "ws://127.0.0.1:8080/ws"))).absoluteString,
            "http://127.0.0.1:8080/clock"
        )
        XCTAssertEqual(
            try ClockCalibrationClient.endpoint(for: XCTUnwrap(URL(string: "wss://cast.example.test/socket"))).absoluteString,
            "https://cast.example.test/clock"
        )
        XCTAssertThrowsError(
            try ClockCalibrationClient.endpoint(for: XCTUnwrap(URL(string: "https://cast.example.test/ws")))
        )
    }
}
