import importlib.util
import pathlib
import tempfile
import unittest


MODULE_PATH = pathlib.Path(__file__).with_name("aggregate-android-tv-baseline.py")
SPEC = importlib.util.spec_from_file_location("android_tv_baseline_aggregate", MODULE_PATH)
aggregate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(aggregate)


class AndroidTvBaselineAggregateTests(unittest.TestCase):
    def test_aggregates_profile_latency_quality_and_paired_delta(self):
        reports = [
            report("direct-baseline", 1, 40.0, 25.0, 600.0, 78.0),
            report("production-relay", 1, 65.0, 45.0, 800.0, 75.0),
        ]

        result = aggregate.build_aggregate(reports, {"git_commit": "abc123"}, {})

        direct = result["profiles"]["direct-baseline"]
        self.assertEqual(direct["run_count"], 1)
        self.assertEqual(direct["android_render_software_end_to_end_ms"]["p50"], 40.0)
        self.assertEqual(direct["capture_to_android_render_ms"]["p50"], 25.0)
        self.assertEqual(direct["connection_timing"]["signaling_ready_total_ms"]["p50"], 600.0)
        self.assertEqual(
            direct["quality"]["source_to_android_render"]["vmaf_reference"]["median"],
            78.0,
        )
        self.assertEqual(
            result["paired_round_deltas"][0]["android_render_software_end_to_end_p50_ms"],
            25.0,
        )

    def test_markdown_exposes_signaling_and_vmaf_as_reference_only(self):
        result = aggregate.build_aggregate(
            [report("direct-baseline", 1, 40.0, 25.0, 600.0, 78.0)],
            {"git_commit": "abc123"},
            {},
        )

        markdown = aggregate.render_markdown(result)

        self.assertIn("Signaling ready p50", markdown)
        self.assertIn("VMAF", markdown)
        self.assertIn("reference metric only", markdown)
        self.assertIn("software marker", markdown)

    def test_checksums_cover_arbitrary_retained_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            context = root / "host-context.json"
            report_path = root / "baseline" / "run.1" / "android-tv-baseline-report.json"
            server_log = root / "baseline" / "run.1" / "server.log"
            report_path.parent.mkdir(parents=True)
            context.write_text("{}", encoding="utf-8")
            report_path.write_text("{}", encoding="utf-8")
            server_log.write_text("safe", encoding="utf-8")

            checksums = aggregate.evidence_checksums(root, context, [report_path])

            self.assertIn("baseline/run.1/server.log", checksums)


def report(profile, round_number, software_ms, capture_ms, signaling_ms, vmaf):
    return {
        "profile": profile,
        "round": round_number,
        "latency_semantics": "software markers; not optical glass-to-glass",
        "measurement_window": {"valid_sequences": 2},
        "latency_samples": [
            {
                "marker_commit_to_capture_ms": software_ms - capture_ms,
                "capture_to_android_render_ms": capture_ms,
                "android_render_software_end_to_end_ms": software_ms,
            }
        ],
        "connection_timing": {
            "signaling_ready_total_ms": signaling_ms,
            "webrtc_negotiation_to_media_ready_ms": signaling_ms / 2,
        },
        "quality_samples": [
            {
                "sequence": 30,
                "comparisons": {
                    "source_to_android_render": {
                        "psnr_y": 31.0,
                        "ssim_y": 0.96,
                        "vmaf_reference": vmaf,
                    }
                },
            }
        ],
    }


if __name__ == "__main__":
    unittest.main()
