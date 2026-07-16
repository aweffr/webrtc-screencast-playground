#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parent
MODULE_PATH = ROOT / "render-static-qp-report.py"
EVIDENCE_MODULE_PATH = ROOT / "static_qp_evidence.py"


class StaticQpReportTests(unittest.TestCase):
    def test_report_requires_and_renders_all_four_qp_cases(self):
        spec = importlib.util.spec_from_file_location("static_qp_report", MODULE_PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        with tempfile.TemporaryDirectory() as temporary:
            experiment = pathlib.Path(temporary) / "experiment"
            experiment.mkdir()
            (experiment / "manifest.json").write_text(json.dumps({
                "generated_at": "2026-07-16T00:00:00Z",
                "xcframework_sha256": "abc123",
                "profile": "production-relay",
                "source": "main",
                "run_seconds": 30,
            }))
            for requested, actual, score in [
                (24, 23, 81.1), (22, 21, 82.2), (20, 19, 83.3), (18, 17, 84.4)
            ]:
                case = experiment / f"qp-{requested}"
                case.mkdir()
                (case / "qp-evidence.json").write_text(json.dumps({
                    "evidence_binding": "generation-session-stable-across-screenshot",
                    "requested_max_qp": requested,
                    "effective_max_qp": requested,
                    "max_qp_apply_state": "applied",
                    "max_qp_generation": 2,
                    "max_qp_applied_encoder_session_id": "vt-one",
                    "last_key_frame_qp": actual,
                    "last_key_frame_bytes": 12345,
                    "last_qp_sample_generation": 2,
                    "last_qp_sample_encoder_session_id": "vt-one",
                    "encoder_session_id": "vt-one",
                }))
                (case / "vmaf.json").write_text(json.dumps({
                    "pooled_metrics": {"vmaf": {"mean": score}}
                }))
                (case / "android-received-final.png").write_bytes(b"png")
                metrics = case / "e2e" / "run.test" / "macos" / "session-sender"
                metrics.mkdir(parents=True)
                (metrics / "metrics.jsonl").write_text("\n".join(json.dumps(row) for row in [
                    {"event": "signaling_connect_started", "monotonic_ns": 1_000_000},
                    {"event": "signaling_connected", "monotonic_ns": 5_000_000},
                    {"event": "sender_join_started", "monotonic_ns": 6_000_000},
                    {"event": "peer_paired", "monotonic_ns": 9_000_000},
                    {"event": "local_offer", "monotonic_ns": 10_000_000},
                    {"event": "peer_connection_connected", "monotonic_ns": 191_000_000},
                ]) + "\n")

            output = pathlib.Path(temporary) / "report.md"
            module.render_report(experiment, output)
            report = output.read_text()
            self.assertIn("| 24 | 24 | 23 |", report)
            self.assertIn("| 18 | 18 | 17 |", report)
            self.assertIn("VMAF（参考）", report)
            self.assertIn("| 24 | 4.000 | 3.000 | 181.000 |", report)
            self.assertEqual(report.count("android-received-final.png"), 4)
            self.assertIn(
                "(report/qp-24-android-received-final.png)",
                report,
            )

    def test_case_rejects_qp_sample_from_another_generation_or_session(self):
        spec = importlib.util.spec_from_file_location("static_qp_report", MODULE_PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        with tempfile.TemporaryDirectory() as temporary:
            experiment = pathlib.Path(temporary)
            case = experiment / "qp-24"
            case.mkdir()
            (case / "android-received-final.png").write_bytes(b"png")
            (case / "vmaf.json").write_text(json.dumps({
                "pooled_metrics": {"vmaf": {"mean": 80.0}}
            }))
            (case / "qp-evidence.json").write_text(json.dumps({
                "requested_max_qp": 24,
                "effective_max_qp": 24,
                "max_qp_apply_state": "applied",
                "max_qp_generation": 2,
                "max_qp_applied_encoder_session_id": "vt-two",
                "last_key_frame_qp": 23,
                "last_key_frame_bytes": 12345,
                "last_qp_sample_generation": 1,
                "last_qp_sample_encoder_session_id": "vt-one",
            }))

            with self.assertRaisesRegex(RuntimeError, "QP sample binding"):
                module.load_case(experiment, 24)


class StaticQpCaptureEvidenceTests(unittest.TestCase):
    @staticmethod
    def load_module():
        spec = importlib.util.spec_from_file_location(
            "static_qp_evidence", EVIDENCE_MODULE_PATH
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    @staticmethod
    def boundary(generation, session, actual_qp=22, encoded_bytes=12345):
        return {
            "clarity_mode": "static_clarity",
            "requested_max_qp": 22,
            "effective_max_qp": 22,
            "max_qp_apply_state": "applied",
            "max_qp_generation": generation,
            "max_qp_applied_encoder_session_id": session,
            "last_key_frame_qp": actual_qp,
            "last_key_frame_bytes": encoded_bytes,
            "last_qp_sample_generation": generation,
            "last_qp_sample_encoder_session_id": session,
        }

    def test_latest_bound_evidence_uses_latest_matching_record(self):
        module = self.load_module()
        stale = self.boundary(1, "vt-one")
        mismatched = self.boundary(2, "vt-two")
        mismatched["last_qp_sample_encoder_session_id"] = "vt-one"
        current = self.boundary(3, "vt-three", encoded_bytes=33333)
        records = [
            {"event": "rtc_stats", "fields": {"sender_media_boundary": stale}},
            {"event": "rtc_stats", "fields": {"sender_media_boundary": mismatched}},
            {"event": "rtc_stats", "fields": {"sender_media_boundary": current}},
        ]

        self.assertEqual(module.latest_bound_evidence(records, 22), current)

    def test_capture_window_rejects_generation_or_session_change(self):
        module = self.load_module()
        before = self.boundary(2, "vt-two")
        self.assertTrue(module.same_capture_window(before, dict(before)))
        self.assertFalse(
            module.same_capture_window(before, self.boundary(3, "vt-three"))
        )


if __name__ == "__main__":
    unittest.main()
