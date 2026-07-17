import copy
import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).with_name("hevc_meeting_experiment.py")
SPEC = importlib.util.spec_from_file_location("hevc_meeting_experiment", MODULE_PATH)
experiment = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(experiment)


class PolicyMatrixTests(unittest.TestCase):
    def test_base_matrix_keeps_h264_head_to_head_and_two_hevc_candidates(self):
        cases = experiment.base_cases()

        self.assertEqual(
            [(case.case_id, case.codec_policy, case.static_max_qp, case.active_max_qp)
             for case in cases],
            [
                ("A0", "h264-only", 24, 32),
                ("A1", "h265-only", 24, 32),
                ("B0", "h265-only", 33, 39),
                ("B1", "h265-only", 30, 39),
            ],
        )
        self.assertTrue(all(case.repetitions == 3 for case in cases))

    def test_feature_cases_change_one_experiment_dimension(self):
        winner = experiment.base_cases()[3]
        cases = experiment.feature_cases(winner)

        self.assertEqual([case.case_id for case in cases], ["C0", "C1", "C2"])
        self.assertEqual(cases[0].spatial_aq, "DISABLE")
        self.assertFalse(cases[1].allow_frame_reordering is False)
        self.assertTrue(cases[2].low_latency_rate_control)
        self.assertIsNone(cases[2].static_max_qp)
        self.assertIsNone(cases[2].active_max_qp)
        self.assertTrue(all(case.repetitions == 2 for case in cases))

    def test_stage_order_is_interleaved_and_stops_when_all_hevc_fails(self):
        self.assertEqual(
            experiment.stage_order(experiment.base_cases()),
            ["A0", "A1", "A0", "A1", "A0", "A1",
             "B0", "B1", "B0", "B1", "B0", "B1"],
        )
        self.assertFalse(experiment.should_run_features({
            "A1": {"eligible": False},
            "B0": {"eligible": False},
            "B1": {"eligible": False},
        }))
        self.assertTrue(experiment.should_run_features({
            "A1": {"eligible": False},
            "B0": {"eligible": True},
            "B1": {"eligible": False},
        }))

    def test_attempt_budget_limits_each_case_global_retries_and_total(self):
        budget = experiment.AttemptBudget()
        self.assertEqual(budget.max_attempts, 23)
        self.assertTrue(budget.can_attempt("A0"))
        budget.record_attempt("A0")
        self.assertTrue(budget.can_attempt("A0"))
        budget.record_attempt("A0")
        self.assertFalse(budget.can_attempt("A0"))

        for case_id in ("A1", "B0", "B1"):
            budget.record_attempt(case_id)
            budget.record_attempt(case_id)
        self.assertEqual(budget.infrastructure_retries, 4)
        self.assertTrue(budget.can_attempt("C0"))
        budget.record_attempt("C0")
        self.assertFalse(budget.can_attempt("C0"))

    def test_policy_generation_preserves_common_parameters(self):
        runtime = {"video_codec_policy": "default", "static_max_qp": 24}
        tuning = {
            "sender": {"max_fps": 15, "max_bitrate_bps": 5_000_000},
            "encoder": {
                "max_qp": 32,
                "allow_frame_reordering": False,
                "video_toolbox_low_latency_rate_control": False,
                "video_toolbox_spatial_adaptive_qp": "DEFAULT",
            },
        }
        original_runtime = copy.deepcopy(runtime)
        original_tuning = copy.deepcopy(tuning)

        generated_runtime, generated_tuning = experiment.generate_configs(
            runtime, tuning, experiment.base_cases()[2]
        )

        self.assertEqual(generated_runtime["video_codec_policy"], "h265-only")
        self.assertEqual(generated_runtime["static_max_qp"], 33)
        self.assertEqual(generated_tuning["encoder"]["max_qp"], 39)
        self.assertEqual(generated_tuning["sender"]["max_fps"], 15)
        self.assertEqual(generated_tuning["sender"]["max_bitrate_bps"], 5_000_000)
        self.assertEqual(runtime, original_runtime)
        self.assertEqual(tuning, original_tuning)


class GateAndSelectionTests(unittest.TestCase):
    def baseline(self):
        return {
            "first_frame_ms": 400.0,
            "active_e2e_p95_ms": 80.0,
            "max_render_gap_ms": 300.0,
            "vt_drop_ratio": 0.005,
            "marker_valid_ratio": 0.98,
            "max_bitrate_bps": 4_500_000,
            "state_cycles": 6,
            "static_ssim_y_worst": 0.990,
            "static_psnr_y_worst": 42.0,
            "manual_text_clear": True,
        }

    def test_all_documented_gate_boundaries_are_inclusive(self):
        baseline = self.baseline()
        candidate = {
            **baseline,
            "first_frame_ms": 500.0,
            "active_e2e_p95_ms": 90.0,
            "max_render_gap_ms": 500.0,
            "vt_drop_ratio": 0.01,
            "marker_valid_ratio": 0.97,
            "max_bitrate_bps": 5_000_000,
            "static_ssim_y_worst": 0.988,
            "static_psnr_y_worst": 41.5,
        }

        result = experiment.evaluate_gates(baseline, candidate)

        self.assertTrue(result["eligible"])
        self.assertEqual(result["failures"], [])

    def test_each_business_regression_can_reject_a_candidate(self):
        mutations = {
            "first_frame_ms": 500.1,
            "active_e2e_p95_ms": 90.1,
            "max_render_gap_ms": 500.1,
            "vt_drop_ratio": 0.0101,
            "marker_valid_ratio": 0.969,
            "max_bitrate_bps": 5_000_001,
            "state_cycles": 5,
            "manual_text_clear": False,
        }
        for key, value in mutations.items():
            with self.subTest(key=key):
                candidate = {**self.baseline(), key: value}
                self.assertFalse(
                    experiment.evaluate_gates(self.baseline(), candidate)["eligible"]
                )

        candidate = {
            **self.baseline(),
            "static_ssim_y_worst": 0.9879,
            "static_psnr_y_worst": 41.49,
        }
        self.assertFalse(experiment.evaluate_gates(self.baseline(), candidate)["eligible"])

    def test_winner_order_and_tie_choose_weaker_qp_constraint(self):
        b0 = {**self.baseline(), "case_id": "B0", "eligible": True,
              "static_max_qp": 33, "active_e2e_p95_ms": 84.0}
        b1 = {**self.baseline(), "case_id": "B1", "eligible": True,
              "static_max_qp": 30, "active_e2e_p95_ms": 80.0,
              "static_ssim_y_worst": 0.993}
        self.assertEqual(experiment.select_winner([b0, b1])["case_id"], "B1")

        tied_b0 = {**b0, "active_e2e_p95_ms": 82.0,
                   "static_ssim_y_worst": 0.990}
        tied_b1 = {**b1, "active_e2e_p95_ms": 80.0,
                   "static_ssim_y_worst": 0.991}
        self.assertEqual(experiment.select_winner([tied_b0, tied_b1])["case_id"], "B0")


if __name__ == "__main__":
    unittest.main()
