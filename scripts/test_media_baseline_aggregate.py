import importlib.util
import pathlib
import tempfile
import unittest


MODULE_PATH = pathlib.Path(__file__).with_name("aggregate-media-baseline.py")
SPEC = importlib.util.spec_from_file_location("media_baseline_aggregate", MODULE_PATH)
aggregate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(aggregate)


class MediaBaselineAggregateTests(unittest.TestCase):
    def test_aggregates_profiles_and_paired_round_delta(self):
        reports = [
            report("direct-baseline", 1, [40.0, 50.0], 6.0, 90.0),
            report("production-relay", 1, [60.0, 70.0], 180.0, 80.0),
        ]

        result = aggregate.build_aggregate(reports, {"git_commit": "abc"}, {})

        self.assertEqual(result["profiles"]["direct-baseline"]["software_end_to_end_ms"]["p50"], 45.0)
        self.assertEqual(result["profiles"]["production-relay"]["quality"]["source_to_decode"]["vmaf_reference"]["median"], 80.0)
        self.assertEqual(result["paired_round_deltas"][0]["software_end_to_end_p50_ms"], 20.0)

    def test_evidence_checksums_keep_duplicate_basenames_distinct(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            host = root / "host-context.json"
            first = root / "round-1" / "media-baseline-report.json"
            second = root / "round-2" / "media-baseline-report.json"
            for path in [host, first, second]:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(str(path), encoding="utf-8")

            checksums = aggregate.evidence_checksums(root, host, [first, second])

            self.assertEqual(set(checksums), {
                "host-context.json",
                "round-1/media-baseline-report.json",
                "round-2/media-baseline-report.json",
            })


def report(profile, round_number, latencies, negotiation_ms, vmaf):
    return {
        "profile": profile,
        "round": round_number,
        "latency_samples": [
            {
                "commit_to_capture_ms": value / 2,
                "capture_to_decode_ms": value / 2,
                "software_end_to_end_ms": value,
            }
            for value in latencies
        ],
        "connection_timing": {"webrtc_negotiation_ms": negotiation_ms},
        "marker_counters": {"committed": 2, "capture_missing": 0, "decode_missing": 0},
        "quality_samples": [{
            "comparisons": {
                "source_to_decode": {"psnr_y": 30.0, "ssim_y": 0.95, "vmaf_reference": vmaf},
            },
        }],
    }


if __name__ == "__main__":
    unittest.main()
