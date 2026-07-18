import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).with_name("damage_idle_experiment.py")


def load_module():
    spec = importlib.util.spec_from_file_location("damage_idle_experiment", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def capture_record(monotonic_ns, **capture):
    defaults = {
        "active_transition_count": 0,
        "static_transition_count": 0,
        "synthetic_clarity_refreshes": 0,
        "last_damage_monotonic_ns": None,
        "last_active_transition_monotonic_ns": None,
        "last_static_transition_monotonic_ns": None,
    }
    defaults.update(capture)
    return {
        "event": "rtc_stats",
        "monotonic_ns": monotonic_ns,
        "fields": {"capture": defaults, "sender_media_boundary": {}},
    }


class DamageIdleExperimentTests(unittest.TestCase):
    def setUp(self):
        self.experiment = load_module()

    def test_formal_matrix_is_bounded_and_h265_is_one_smoke(self):
        self.assertEqual(
            self.experiment.formal_order(),
            ("D0", "D1", "D1", "D0", "D0", "D1"),
        )
        cases = self.experiment.cases()
        self.assertEqual((cases["D0"].codec_policy, cases["D0"].static_qp, cases["D0"].active_qp),
                         ("h264-only", 24, 32))
        self.assertEqual((cases["D1"].codec_policy, cases["D1"].static_qp, cases["D1"].active_qp),
                         ("h264-only", 24, 32))
        self.assertEqual((cases["H1"].codec_policy, cases["H1"].static_qp, cases["H1"].active_qp),
                         ("h265-only", 33, 39))
        self.assertFalse(self.experiment.includes_detector_evidence("D0"))
        self.assertTrue(self.experiment.includes_detector_evidence("D1"))
        self.assertTrue(self.experiment.includes_detector_evidence("H1"))

    def test_each_business_episode_restores_active_and_settles_static(self):
        start = 1_000_000_000
        markers = [start + second * 1_000_000_000 for second in (20, 28, 36, 44, 52, 60)]
        workload = [{"event": "workload_started", "monotonic_ns": start}]
        workload += [
            {"event": "activity_episode", "sequence": index + 2, "marker_monotonic_ns": marker}
            for index, marker in enumerate(markers)
        ]
        records = [capture_record(
            start + 700_000_000,
            last_damage_monotonic_ns=start + 50_000_000,
            last_static_transition_monotonic_ns=start + 700_000_000,
            static_transition_count=1,
            synthetic_clarity_refreshes=1,
        )]
        for index, marker in enumerate(markers, start=1):
            active = marker + 80_000_000
            damage = marker + 500_000_000
            static = damage + 650_000_000
            records.append(capture_record(
                active,
                last_active_transition_monotonic_ns=active,
                active_transition_count=index,
                static_transition_count=index,
                synthetic_clarity_refreshes=index,
            ))
            records.append(capture_record(
                static,
                last_damage_monotonic_ns=damage,
                last_active_transition_monotonic_ns=active,
                last_static_transition_monotonic_ns=static,
                active_transition_count=index,
                static_transition_count=index + 1,
                synthetic_clarity_refreshes=index + 1,
            ))
        records[-1]["fields"]["sender_media_boundary"] = {
            "clarity_active_restores": 6,
            "clarity_successful_refreshes": 7,
            "clarity_failed_refreshes": 0,
        }

        result = self.experiment.evaluate_detector_evidence(workload, records)

        self.assertTrue(result["eligible"], result["failures"])
        self.assertEqual(result["active_latencies_ms"], [80.0] * 6)
        self.assertEqual(result["static_quiet_latencies_ms"], [650.0] * 7)

    def test_real_extra_damage_is_allowed_with_a_bounded_transition_count(self):
        start = 1_000_000_000
        markers = [start + second * 1_000_000_000 for second in (20, 28, 36, 44, 52, 60)]
        workload = [
            {"event": "activity_episode", "sequence": index + 2, "marker_monotonic_ns": marker}
            for index, marker in enumerate(markers)
        ]
        records = [capture_record(
            start + 700_000_000,
            last_damage_monotonic_ns=start + 50_000_000,
            last_static_transition_monotonic_ns=start + 700_000_000,
            static_transition_count=1,
            synthetic_clarity_refreshes=1,
        )]
        active_count = 0
        static_count = 1
        for marker in markers:
            for offset in (80_000_000, 1_500_000_000):
                active_count += 1
                active = marker + offset
                damage = active + 100_000_000
                static = damage + 650_000_000
                records.append(capture_record(
                    active,
                    last_active_transition_monotonic_ns=active,
                    active_transition_count=active_count,
                    static_transition_count=static_count,
                    synthetic_clarity_refreshes=static_count,
                ))
                static_count += 1
                records.append(capture_record(
                    static,
                    last_damage_monotonic_ns=damage,
                    last_active_transition_monotonic_ns=active,
                    last_static_transition_monotonic_ns=static,
                    active_transition_count=active_count,
                    static_transition_count=static_count,
                    synthetic_clarity_refreshes=static_count,
                ))
        records[-1]["fields"]["sender_media_boundary"] = {
            "clarity_active_restores": active_count,
            "clarity_successful_refreshes": static_count,
            "clarity_failed_refreshes": 0,
        }

        result = self.experiment.evaluate_detector_evidence(workload, records)

        self.assertTrue(result["eligible"], result["failures"])
        self.assertEqual(result["active_transition_count"], 12)
        self.assertEqual(result["static_transition_count"], 13)
        self.assertEqual(result["active_latencies_ms"], [80.0] * 6)

    def test_detector_rejects_missing_episode_and_excessive_transitions(self):
        workload = [
            {"event": "workload_started", "monotonic_ns": 1_000},
            {"event": "activity_episode", "sequence": 2, "marker_monotonic_ns": 2_000},
        ]
        records = [capture_record(
            300_002_000,
            last_active_transition_monotonic_ns=300_002_000,
            active_transition_count=4,
            static_transition_count=1,
            synthetic_clarity_refreshes=1,
        )]

        result = self.experiment.evaluate_detector_evidence(workload, records)

        self.assertFalse(result["eligible"])
        self.assertIn("active_episode_latency", result["failures"])
        self.assertIn("static_episode_coverage", result["failures"])
        self.assertIn("transition_bound", result["failures"])

    def test_head_to_head_gates_compare_three_d1_runs_to_three_d0_runs(self):
        baseline = [self.experiment_run() for _ in range(3)]
        candidate = [self.experiment_run(
            first_frame_ms=190,
            active_e2e_p95_ms=48,
            bitrate_bps=4_100_000,
            static_ssim_y=0.989,
            static_psnr_y=39.6,
            detector_eligible=True,
        ) for _ in range(3)]

        report = self.experiment.evaluate_head_to_head(baseline, candidate)

        self.assertTrue(report["eligible"], report["failures"])
        self.assertTrue(self.experiment.authorizes_h265_smoke(report))

    def test_quality_or_operational_regression_blocks_h265_smoke(self):
        baseline = [self.experiment_run() for _ in range(3)]
        candidate = [self.experiment_run(
            bitrate_bps=4_300_000,
            static_ssim_y=0.987,
            static_psnr_y=39.4,
            detector_eligible=True,
        ) for _ in range(3)]

        report = self.experiment.evaluate_head_to_head(baseline, candidate)

        self.assertFalse(report["eligible"])
        self.assertIn("bitrate_regression", report["failures"])
        self.assertIn("static_ssim_regression", report["failures"])
        self.assertIn("static_psnr_regression", report["failures"])
        self.assertFalse(self.experiment.authorizes_h265_smoke(report))

    @staticmethod
    def experiment_run(**overrides):
        result = {
            "first_frame_ms": 100,
            "active_e2e_p95_ms": 40,
            "max_render_gap_ms": 400,
            "vt_drop_ratio": 0.005,
            "bitrate_bps": 4_000_000,
            "marker_valid": 6,
            "marker_total": 6,
            "static_ssim_y": 0.990,
            "static_psnr_y": 40.0,
            "manual_images_clear": True,
            "detector_eligible": False,
            "qp_binding_valid": True,
        }
        result.update(overrides)
        return result


if __name__ == "__main__":
    unittest.main()
