import XCTest
@testable import WebRTCScreencast

final class SessionMetricsSamplerTests: XCTestCase {
    func testCaptureFieldsExposeExactContentActivityEvidence() {
        let snapshot = CaptureTelemetrySnapshot(
            callbackFrames: 30,
            submittedFrames: 12,
            droppedFrames: 18,
            lastTimestampNs: 900,
            lastDirtyRectCount: 1,
            lastDirtyRatio: 0.25,
            gateState: .detail15,
            contentActivityMode: .staticClarity,
            lastDamageMonotonicNs: 1_000,
            quietDeadlineMonotonicNs: 601_000,
            lastActiveTransitionMonotonicNs: 800,
            lastStaticTransitionMonotonicNs: 601_100,
            activeTransitionCount: 6,
            staticTransitionCount: 7,
            syntheticClarityRefreshes: 7
        )

        let fields = SessionMetricsSampler.fields(from: snapshot)

        XCTAssertEqual(fields["content_activity_mode"], .string("static_clarity"))
        XCTAssertEqual(fields["last_damage_monotonic_ns"], .integer(1_000))
        XCTAssertEqual(fields["quiet_deadline_monotonic_ns"], .integer(601_000))
        XCTAssertEqual(fields["last_active_transition_monotonic_ns"], .integer(800))
        XCTAssertEqual(fields["last_static_transition_monotonic_ns"], .integer(601_100))
        XCTAssertEqual(fields["active_transition_count"], .integer(6))
        XCTAssertEqual(fields["static_transition_count"], .integer(7))
        XCTAssertEqual(fields["synthetic_clarity_refreshes"], .integer(7))
        XCTAssertNil(fields["visual_stability_mode"])
        XCTAssertNil(fields["visual_changed_sample_ratio"])
    }
}
