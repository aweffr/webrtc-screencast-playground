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

    def test_h264_baseline_uses_reference_decoder_compatible_profile(self):
        runtime = {"video_codec_policy": "default"}
        tuning = {"encoder": {}}

        _, generated_tuning = experiment.generate_configs(
            runtime, tuning, experiment.base_cases()[0]
        )

        self.assertEqual(
            generated_tuning["encoder"]["h264_profile"],
            "CONSTRAINED_BASELINE",
        )
        self.assertEqual(generated_tuning["encoder"]["h264_level"], "4.1")


class GateAndSelectionTests(unittest.TestCase):
    def baseline(self):
        return {
            "first_frame_ms": 400.0,
            "active_e2e_p95_ms": 80.0,
            "max_render_gap_ms": 300.0,
            "vt_drop_ratio": 0.005,
            "marker_sequence_delivery_ratio": 1.0,
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
            "marker_sequence_delivery_ratio": 1.0,
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
            "marker_sequence_delivery_ratio": 5 / 6,
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

        thrashing = {**self.baseline(), "state_cycles": 7}
        self.assertFalse(experiment.evaluate_gates(self.baseline(), thrashing)["eligible"])

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

    def test_base_report_stops_when_every_hevc_candidate_fails(self):
        analyses = {}
        for case in experiment.base_cases():
            run = {
                **self.baseline(),
                "case_id": case.case_id,
                "static_max_qp": case.static_max_qp,
                "active_max_qp": case.active_max_qp,
                "marker_valid": 6,
                "marker_total": 6,
                "active_e2e_samples_ms": [80.0] * 6,
            }
            if case.case_id != "A0":
                run["manual_text_clear"] = False
            analyses[case.case_id] = [copy.deepcopy(run) for _ in range(3)]

        report = experiment.build_base_report(analyses)

        self.assertFalse(report["run_features"])
        self.assertIsNone(report["winner_id"])
        self.assertIn("不进入 feature stage", report["conclusion"])
        self.assertEqual([item["case_id"] for item in report["cases"]],
                         ["A0", "A1", "B0", "B1"])

    def test_base_report_selects_only_an_eligible_hevc_winner(self):
        analyses = {}
        for case in experiment.base_cases():
            run = {
                **self.baseline(),
                "case_id": case.case_id,
                "static_max_qp": case.static_max_qp,
                "active_max_qp": case.active_max_qp,
                "marker_valid": 6,
                "marker_total": 6,
                "active_e2e_samples_ms": [80.0] * 6,
            }
            if case.case_id == "A1":
                run["static_ssim_y_worst"] = 0.980
                run["static_psnr_y_worst"] = 38.0
            analyses[case.case_id] = [copy.deepcopy(run) for _ in range(3)]

        report = experiment.build_base_report(analyses)

        self.assertTrue(report["run_features"])
        self.assertEqual(report["winner_id"], "B0")
        b0 = next(item for item in report["cases"] if item["case_id"] == "B0")
        self.assertTrue(b0["eligible"])


class EvidenceAnalysisTests(unittest.TestCase):
    def test_content_state_cycles_bind_each_scroll_to_applied_active_then_static_qp(self):
        case = experiment.base_cases()[2]
        workload = []
        sender = []
        for sequence in range(1, 7):
            planned = sequence * 10_000_000_000
            marker = planned + 600_000_000
            workload.append({
                "event": "scroll_burst",
                "sequence": sequence,
                "planned_monotonic_ns": planned,
                "marker_monotonic_ns": marker,
            })
            sender.extend([
                self.applied_qp_record(
                    planned + 900_000_000,
                    "motion",
                    case.active_max_qp,
                    sequence * 2,
                ),
                self.applied_qp_record(
                    planned + 3_000_000_000,
                    "static_clarity",
                    case.static_max_qp,
                    sequence * 2 + 1,
                ),
            ])
        workload.append({
            "event": "final_marker",
            "sequence": 8,
            "marker_monotonic_ns": 70_000_000_000,
        })

        cycles = experiment.content_state_cycles(case, workload, sender)

        self.assertEqual(len(cycles), 6)
        self.assertTrue(all(cycle["valid"] for cycle in cycles))
        self.assertEqual(cycles[0]["active"]["max_qp"], 39)
        self.assertEqual(cycles[0]["static"]["max_qp"], 33)

        sender = [
            record for record in sender
            if not (record["monotonic_ns"] == 43_000_000_000)
        ]
        cycles = experiment.content_state_cycles(case, workload, sender)
        self.assertFalse(cycles[3]["valid"])
        self.assertIsNone(cycles[3]["static"])

    def test_aggregates_observed_qp_histograms_across_runs(self):
        first = [0] * 52
        second = [0] * 52
        first[24] = 3
        first[30] = 1
        second[30] = 4
        second[39] = 1

        summary = experiment.aggregate_qp_distribution([
            {"encoder_telemetry": {
                "key_qp_histogram": first,
                "delta_qp_histogram": second,
            }},
        ])

        self.assertEqual(summary["key_qp_p50"], 24)
        self.assertEqual(summary["key_qp_p95"], 30)
        self.assertEqual(summary["delta_qp_p50"], 30)
        self.assertEqual(summary["delta_qp_p95"], 39)
        self.assertEqual(summary["observed_qp_max"], 39)

    def test_parses_y_plane_image_metrics_from_ffmpeg(self):
        output = """
[Parsed_psnr_4] PSNR y:42.125000 u:48.0 v:47.0 average:43.0
[Parsed_ssim_4] SSIM Y:0.998750 (29.0) U:0.99 V:0.99 All:0.99
"""

        self.assertEqual(
            experiment.parse_image_metrics(output),
            {"psnr_y": 42.125, "ssim_y": 0.99875},
        )

    def test_workload_marker_commits_use_rendered_marker_sequences(self):
        commits = experiment.workload_marker_commits([
            {"event": "scroll_burst", "sequence": 1, "marker_monotonic_ns": 100},
            {"event": "scroll_burst", "sequence": 6, "marker_monotonic_ns": 600},
            {"event": "final_marker", "sequence": 8, "marker_monotonic_ns": 800},
        ])

        self.assertEqual(commits, {2: 100, 7: 600, 8: 800})

    def test_encoder_telemetry_sums_latest_snapshot_per_generation(self):
        def record(session, generation, submitted, encoded, dropped, qp):
            histogram = [0] * 52
            histogram[qp] = encoded
            return {"event": "rtc_stats", "fields": {"sender_media_boundary": {
                "encoder_session_id": session,
                "max_qp_generation": generation,
                "video_toolbox_submitted_frames": submitted,
                "video_toolbox_encoded_frames": encoded,
                "video_toolbox_dropped_frames": dropped,
                "key_frame_qp_histogram": [0] * 52,
                "delta_frame_qp_histogram": histogram,
            }}}

        summary = experiment.encoder_telemetry([
            record("vt-1", 1, 10, 9, 1, 32),
            record("vt-1", 1, 20, 18, 2, 32),
            record("vt-2", 2, 5, 5, 0, 24),
        ])

        self.assertEqual(summary["submitted_frames"], 25)
        self.assertEqual(summary["encoded_frames"], 23)
        self.assertEqual(summary["dropped_frames"], 2)
        self.assertEqual(summary["drop_ratio"], 2 / 25)
        self.assertEqual(summary["delta_qp_histogram"][32], 18)
        self.assertEqual(summary["delta_qp_histogram"][24], 5)
        self.assertEqual(summary["generation_count"], 2)

    def test_run_analysis_correlates_workload_capture_and_android_render(self):
        histogram = [0] * 52
        histogram[24] = 6
        workload = [
            {"event": "scroll_burst", "sequence": sequence - 1,
             "planned_monotonic_ns": sequence * 10_000_000,
             "marker_monotonic_ns": sequence * 10_000_000 + 600_000}
            for sequence in range(2, 8)
        ] + [
            {"event": "final_marker", "sequence": 8,
             "marker_monotonic_ns": 100_000_000},
            {"event": "workload_completed", "valid": True},
        ]
        sender = [
            {"event": "clock_calibrated", "fields": {"offset_ns": 100}},
            {"event": "sender_join_started", "monotonic_ns": 100_000},
            *[
                {"event": "baseline_capture_detected", "fields": {
                    "sequence": sequence,
                    "callback_monotonic_ns": sequence * 10_000_000 + 700_000,
                }}
                for sequence in range(1, 9)
            ],
            *[
                record
                for sequence in range(1, 7)
                for record in (
                    self.applied_qp_record(
                        (sequence + 1) * 10_000_000 + 800_000,
                        "motion",
                        32,
                        sequence * 2,
                    ),
                    self.applied_qp_record(
                        (sequence + 1) * 10_000_000 + 3_000_000,
                        "static_clarity",
                        24,
                        sequence * 2 + 1,
                    ),
                )
            ],
        ]
        for record in sender:
            if record.get("event") == "rtc_stats":
                record["fields"]["outbound_video"] = {
                    "codec": "video/H265",
                    "bitrate_bps": 4_000_000,
                }
                boundary = record["fields"]["sender_media_boundary"]
                boundary["clarity_motion_restores"] = 6
                boundary["clarity_successful_refreshes"] = 7
        receiver = [
            {"event": "clock_calibration", "fields": {"offset_ns": 200}},
            *[
                {"event": "baseline_android_render_detected", "fields": {
                    "sequence": sequence,
                    "local_monotonic_ns": sequence * 10_000_000 + 800_000,
                }}
                for sequence in range(1, 9)
            ],
            {"event": "baseline_android_active_gap_summary", "fields": {
                "max_frame_gap_ms": 180.0,
            }},
        ]

        result = experiment.analyze_run_records(
            experiment.base_cases()[1],
            workload,
            sender,
            receiver,
            static_image_metrics=[
                {"ssim_y": 0.991, "psnr_y": 42.0},
                {"ssim_y": 0.989, "psnr_y": 41.0},
            ],
            manual_text_clear=True,
        )

        self.assertEqual(result["codec"], "video/H265")
        self.assertEqual(len(result["active_e2e_samples_ms"]), 6)
        self.assertAlmostEqual(result["active_e2e_p95_ms"], 0.2001)
        self.assertAlmostEqual(result["first_frame_ms"], 10.7001)
        self.assertEqual(result["max_render_gap_ms"], 180.0)
        self.assertEqual(result["vt_drop_ratio"], 0)
        self.assertEqual(result["marker_valid"], 6)
        self.assertEqual(result["marker_total"], 6)
        self.assertEqual(result["state_cycles"], 6)
        self.assertTrue(all(item["valid"] for item in result["content_state_cycles"]))
        self.assertEqual(result["static_ssim_y_worst"], 0.989)
        self.assertEqual(result["static_psnr_y_worst"], 41.0)
        self.assertTrue(result["manual_text_clear"])

    @staticmethod
    def applied_qp_record(monotonic_ns, mode, max_qp, generation):
        histogram = [0] * 52
        histogram[max_qp] = 1
        session = f"vt-{generation}"
        return {"event": "rtc_stats", "monotonic_ns": monotonic_ns, "fields": {
            "sender_media_boundary": {
                "clarity_mode": mode,
                "requested_max_qp": max_qp,
                "effective_max_qp": max_qp,
                "max_qp_apply_state": "applied",
                "max_qp_generation": generation,
                "encoder_session_id": session,
                "max_qp_applied_encoder_session_id": session,
                "last_qp_sample_generation": generation,
                "last_qp_sample_encoder_session_id": session,
                "last_key_frame_qp": max_qp,
                "video_toolbox_submitted_frames": 1,
                "video_toolbox_encoded_frames": 1,
                "video_toolbox_dropped_frames": 0,
                "key_frame_qp_histogram": histogram,
                "delta_frame_qp_histogram": [0] * 52,
            },
        }}


if __name__ == "__main__":
    unittest.main()
