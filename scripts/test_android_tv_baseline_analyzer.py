import importlib.util
import pathlib
import tempfile
import unittest


MODULE_PATH = pathlib.Path(__file__).with_name("analyze-android-tv-baseline.py")
SPEC = importlib.util.spec_from_file_location("android_tv_baseline_analyzer", MODULE_PATH)
analyzer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(analyzer)


class AndroidTvBaselineAnalyzerTests(unittest.TestCase):
    def test_correlates_only_after_mapping_different_monotonic_epochs(self):
        sender = [
            record("clock_calibrated", 10, sample_count=5, offset_ns=9_000_000_000,
                   round_trip_ns=100_000, uncertainty_ns=50_000),
            record("baseline_marker_committed", 1_000_000, sequence=30,
                   committed_monotonic_ns=1_000_000),
            record("baseline_capture_detected", 2_000_000, sequence=30,
                   callback_monotonic_ns=2_000_000),
        ]
        receiver = [
            record("clock_calibration", 20, sample_count=5, offset_ns=4_004_000_000,
                   round_trip_ns=200_000, uncertainty_ns=100_000),
            record("baseline_android_render_detected", 5_000_000_000, sequence=30,
                   local_monotonic_ns=5_000_000_000,
                   common_time_ns=9_004_000_000,
                   frame_width=1920, frame_height=1080),
        ]

        samples = analyzer.correlate_latency(sender, receiver)

        self.assertEqual(samples, [{
            "sequence": 30,
            "sender_commit_local_monotonic_ns": 1_000_000,
            "sender_commit_common_time_ns": 9_001_000_000,
            "sender_capture_local_monotonic_ns": 2_000_000,
            "sender_capture_common_time_ns": 9_002_000_000,
            "android_render_local_monotonic_ns": 5_000_000_000,
            "android_render_common_time_ns": 9_004_000_000,
            "marker_commit_to_capture_ms": 1.0,
            "capture_to_android_render_ms": 2.0,
            "android_render_software_end_to_end_ms": 3.0,
        }])

    def test_rejects_missing_or_incomplete_clock_calibration(self):
        with self.assertRaisesRegex(RuntimeError, "sender clock calibration"):
            analyzer.correlate_latency([], calibrated_receiver())
        with self.assertRaisesRegex(RuntimeError, "five samples"):
            analyzer.correlate_latency(
                [record("clock_calibrated", 1, sample_count=4, offset_ns=0,
                        round_trip_ns=10, uncertainty_ns=5)],
                calibrated_receiver(),
            )

    def test_rejects_provided_android_common_time_that_does_not_match_calibration(self):
        sender = calibrated_sender() + [
            record("baseline_marker_committed", 100, sequence=30,
                   committed_monotonic_ns=100),
            record("baseline_capture_detected", 200, sequence=30,
                   callback_monotonic_ns=200),
        ]
        receiver = calibrated_receiver() + [
            record("baseline_android_render_detected", 300, sequence=30,
                   local_monotonic_ns=300, common_time_ns=999,
                   frame_width=1920, frame_height=1080),
        ]

        with self.assertRaisesRegex(RuntimeError, "Android common-time mismatch"):
            analyzer.correlate_latency(sender, receiver)

    def test_rejects_selected_path_violation_for_both_profiles(self):
        direct_sender = [record(
            "selected_path", 1, status="verified", local_candidate_type="relay",
            remote_candidate_type="host", protocol="udp")]
        direct_receiver = [record(
            "rtc_stats", 2, path_status="accepted", local_path_type="relay",
            remote_path_type="host", path_protocol="udp")]
        with self.assertRaisesRegex(RuntimeError, "direct-baseline selected-path violation"):
            analyzer.require_selected_path(direct_sender, direct_receiver, "direct-baseline")

        relay_sender = [record(
            "selected_path", 1, status="verified", local_candidate_type="relay",
            remote_candidate_type="relay", protocol="tcp")]
        relay_receiver = [record(
            "rtc_stats", 2, path_status="accepted", local_path_type="relay",
            remote_path_type="relay", path_protocol="tcp")]
        with self.assertRaisesRegex(RuntimeError, "production-relay selected-path violation"):
            analyzer.require_selected_path(relay_sender, relay_receiver, "production-relay")

    def test_rejects_relay_profile_when_only_local_candidate_is_relay(self):
        sender = [record(
            "selected_path", 1, status="verified", local_candidate_type="relay",
            remote_candidate_type="host", protocol="udp")]
        receiver = [record(
            "rtc_stats", 2, path_status="accepted", local_path_type="relay",
            remote_path_type="host", path_protocol="udp")]

        with self.assertRaisesRegex(RuntimeError, "production-relay selected-path violation"):
            analyzer.require_selected_path(sender, receiver, "production-relay")

    def test_requires_android_1920_by_1080_render_evidence(self):
        receiver = [record(
            "baseline_android_render_detected", 1, sequence=30,
            local_monotonic_ns=1, common_time_ns=1,
            frame_width=1280, frame_height=720)]

        with self.assertRaisesRegex(RuntimeError, "1920x1080"):
            analyzer.require_render_resolution(receiver)

    def test_requires_three_complete_cross_platform_image_triplets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            sender = root / "sender"
            receiver = root / "receiver"
            sender.mkdir()
            receiver.mkdir()
            for sequence in (30, 80, 130):
                (sender / f"source-reference-{sequence:06d}.png").write_bytes(b"source")
                (sender / f"sender-capture-{sequence:06d}.png").write_bytes(b"capture")
                (receiver / f"android-decoded-seq-{sequence:06d}.png").write_bytes(b"decode")
            (receiver / "android-decoded-seq-000080.png").unlink()

            with self.assertRaisesRegex(RuntimeError, "three complete image triplets"):
                analyzer.require_image_triplets(sender, receiver)

    def test_rejects_configured_credential_in_retained_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "safe.jsonl").write_text('{"event":"safe"}\n', encoding="utf-8")
            (root / "receiver.log").write_text("leaked turn-secret-123", encoding="utf-8")

            with self.assertRaisesRegex(RuntimeError, "configured credential"):
                analyzer.reject_credentials([root], ["turn-user-123", "turn-secret-123"])


def record(event, monotonic_ns, **fields):
    return {"event": event, "monotonic_ns": monotonic_ns, "fields": fields}


def calibrated_sender():
    return [record("clock_calibrated", 1, sample_count=5, offset_ns=0,
                   round_trip_ns=10, uncertainty_ns=5)]


def calibrated_receiver():
    return [record("clock_calibration", 1, sample_count=5, offset_ns=0,
                   round_trip_ns=10, uncertainty_ns=5)]


if __name__ == "__main__":
    unittest.main()
