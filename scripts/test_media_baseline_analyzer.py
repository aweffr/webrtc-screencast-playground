import importlib.util
import pathlib
import unittest
from unittest import mock


MODULE_PATH = pathlib.Path(__file__).with_name("analyze-media-baseline.py")
SPEC = importlib.util.spec_from_file_location("media_baseline_analyzer", MODULE_PATH)
analyzer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(analyzer)


class MediaBaselineAnalyzerTests(unittest.TestCase):
    def test_correlates_three_latency_segments_by_sequence(self):
        sender = [
            record("baseline_marker_committed", 100, sequence=7, committed_monotonic_ns=100),
            record("baseline_capture_detected", 140, sequence=7, callback_monotonic_ns=130),
        ]
        receiver = [
            record("baseline_decode_detected", 190, sequence=7, callback_monotonic_ns=180),
        ]

        samples = analyzer.correlate_latency(sender, receiver)

        self.assertEqual(samples, [{
            "sequence": 7,
            "committed_monotonic_ns": 100,
            "commit_to_capture_ms": 0.00003,
            "capture_to_decode_ms": 0.00005,
            "software_end_to_end_ms": 0.00008,
        }])

    def test_summarizes_connection_timing_without_mixing_negotiation(self):
        receiver = [
            record("signaling_connect_started", 1_000),
            record("signaling_connected", 1_020),
            record("receiver_register_started", 1_025),
            record("receiver_registered", 1_040),
            record("peer_paired", 2_100),
            record("peer_connection_connected", 2_300),
        ]
        sender = [
            record("signaling_connect_started", 2_000),
            record("signaling_connected", 2_030),
            record("sender_join_started", 2_040),
            record("peer_paired", 2_110),
            record("peer_connection_connected", 2_350),
        ]

        timing = analyzer.connection_timing(sender, receiver)

        self.assertEqual(timing["receiver_websocket_connect_ms"], 0.00002)
        self.assertEqual(timing["pairing_code_issue_ms"], 0.000015)
        self.assertEqual(timing["sender_websocket_connect_ms"], 0.00003)
        self.assertEqual(timing["sender_join_to_paired_ms"], 0.00007)
        self.assertEqual(timing["signaling_ready_total_ms"], 0.00111)
        self.assertEqual(timing["webrtc_negotiation_ms"], 0.00025)

    def test_measurement_window_excludes_ten_second_warmup(self):
        selected_path_ns = 1_000_000_000
        samples = [
            {"sequence": sequence, "committed_monotonic_ns": selected_path_ns + sequence * 500_000_000}
            for sequence in range(1, 141)
        ]

        window = analyzer.measurement_window(samples, selected_path_ns)

        self.assertEqual(len(window), 120)
        self.assertEqual(window[0]["sequence"], 20)
        self.assertEqual(window[-1]["sequence"], 139)

    @mock.patch.object(analyzer, "run_ffmpeg")
    def test_yuv_filter_reports_luma_and_chroma_components(self, run_ffmpeg):
        run_ffmpeg.return_value = mock.Mock(
            stderr="PSNR y:40.1 u:41.2 v:42.3 average:41.0 min:41.0 max:41.0"
        )

        values = analyzer.run_filter(
            pathlib.Path("distorted.png"), pathlib.Path("reference.png"),
            "psnr", r"PSNR y:(\S+) u:(\S+) v:(\S+) average:(\S+)",
        )

        self.assertEqual(values, ("40.1", "41.2", "42.3", "41.0"))
        self.assertIn("format=yuv444p", run_ffmpeg.call_args.args[0][8])

    @mock.patch.object(analyzer, "run_ffmpeg")
    def test_region_filter_crops_both_inputs_identically(self, run_ffmpeg):
        run_ffmpeg.return_value = mock.Mock(
            stderr="PSNR y:40.1 u:41.2 v:42.3 average:41.0 min:41.0 max:41.0"
        )

        analyzer.run_filter(
            pathlib.Path("distorted.png"), pathlib.Path("reference.png"),
            "psnr", r"PSNR y:(\S+) u:(\S+) v:(\S+) average:(\S+)",
            crop=(320, 224, 1536, 112),
        )

        graph = run_ffmpeg.call_args.args[0][8]
        self.assertEqual(graph.count("crop=1536:112:320:224"), 2)

    def test_requires_correlated_marker_and_three_quality_samples(self):
        with self.assertRaisesRegex(RuntimeError, "no correlatable marker"):
            analyzer.require_evidence([], [{}, {}, {}])
        with self.assertRaisesRegex(RuntimeError, "three complete image triplets"):
            analyzer.require_evidence([{"sequence": 21}], [{}, {}])

    def test_marker_counters_separate_missing_and_crc_invalid_observations(self):
        sender = [
            record("baseline_marker_committed", 10, sequence=1, committed_monotonic_ns=10),
            record("baseline_marker_committed", 20, sequence=2, committed_monotonic_ns=20),
            record("baseline_capture_detected", 21, sequence=1, callback_monotonic_ns=21),
            record("baseline_marker_invalid", 22, stage="capture", reason="checksum_mismatch", callback_monotonic_ns=22),
        ]
        receiver = [
            record("baseline_decode_detected", 23, sequence=1, callback_monotonic_ns=23),
            record("baseline_marker_invalid", 24, stage="decode", reason="checksum_mismatch", callback_monotonic_ns=24),
        ]

        counters = analyzer.marker_counters(sender, receiver, start_ns=10, end_ns=30)

        self.assertEqual(counters, {
            "committed": 2,
            "capture_detected": 1,
            "capture_missing": 1,
            "decode_detected": 1,
            "decode_missing": 1,
            "capture_crc_invalid": 1,
            "decode_crc_invalid": 1,
        })


def record(event, monotonic_ns, **fields):
    return {"event": event, "monotonic_ns": monotonic_ns, "fields": fields}


if __name__ == "__main__":
    unittest.main()
