#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import tempfile
import unittest


MODULE_PATH = pathlib.Path(__file__).with_name("hevc_meeting_workload.py")


def load_module():
    spec = importlib.util.spec_from_file_location("hevc_meeting_workload", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class HEVCMeetingWorkloadTests(unittest.TestCase):
    def test_default_schedule_matches_meeting_content_contract(self):
        module = load_module()
        schedule = module.default_schedule()
        self.assertEqual(schedule.initial_static_seconds, 25)
        self.assertEqual(schedule.scroll_phase_end_seconds, 55)
        self.assertEqual(schedule.final_static_seconds, 20)
        self.assertEqual(schedule.total_seconds, 75)
        self.assertEqual(
            [burst.planned_seconds for burst in schedule.bursts],
            [25, 30, 35, 40, 45, 50],
        )
        self.assertEqual(
            [burst.expected_offset for burst in schedule.bursts],
            [720, 1440, 2160, 2880, 3600, 4320],
        )
        for burst in schedule.bursts:
            self.assertEqual(burst.steps, 12)
            self.assertEqual(burst.step_pixels, 60)
            self.assertEqual(burst.step_interval_seconds, 0.05)
        self.assertEqual(module.QUALITY_EVIDENCE_SEQUENCES, (1, 4, 8))

    def test_offset_mismatch_or_missing_burst_invalidates_evidence(self):
        module = load_module()
        valid = [
            {"sequence": index, "expected_offset": index * 720, "actual_offset": index * 720}
            for index in range(1, 7)
        ]
        self.assertTrue(module.validate_burst_evidence(valid))
        mismatch = [dict(row) for row in valid]
        mismatch[2]["actual_offset"] += 2
        self.assertFalse(module.validate_burst_evidence(mismatch))
        self.assertFalse(module.validate_burst_evidence(valid[:-1]))

    def test_scroll_program_uses_real_wheel_steps_and_updates_marker_once(self):
        module = load_module()
        program = module.scroll_program(sequence=4)
        self.assertEqual(program.count("page.mouse.wheel(0, 60)"), 1)
        self.assertIn("for (let step = 0; step < 12; step += 1)", program)
        self.assertIn("page.waitForTimeout(50)", program)
        self.assertIn("window.__experimentMarker.setSequence(4)", program)
        self.assertIn("window.scrollY", program)
        with self.assertRaises(TypeError):
            module.scroll_program(sequence=4, interval_ms=1)

    def test_jsonl_writer_preserves_planned_and_actual_timing(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            output = pathlib.Path(temporary) / "workload.jsonl"
            writer = module.JSONLWriter(output)
            writer.write(
                "scroll_burst",
                sequence=1,
                planned_monotonic_ns=100,
                actual_monotonic_ns=105,
                expected_offset=720,
                actual_offset=720,
                valid=True,
            )
            row = json.loads(output.read_text())
            self.assertEqual(row["event"], "scroll_burst")
            self.assertEqual(row["planned_monotonic_ns"], 100)
            self.assertEqual(row["actual_monotonic_ns"], 105)
            self.assertTrue(row["valid"])


if __name__ == "__main__":
    unittest.main()
