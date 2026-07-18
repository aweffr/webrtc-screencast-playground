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
        self.assertEqual(schedule.initial_static_seconds, 20)
        self.assertEqual(schedule.scroll_phase_end_seconds, 68)
        self.assertEqual(schedule.final_static_seconds, 20)
        self.assertEqual(schedule.total_seconds, 88)
        self.assertEqual(
            [burst.planned_seconds for burst in schedule.bursts],
            [20, 28, 36, 44, 52, 60],
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

    def test_browser_launch_config_requests_dedicated_chrome_kiosk(self):
        module = load_module()

        config = module.browser_launch_config()

        self.assertEqual(config["browser"]["browserName"], "chromium")
        self.assertEqual(config["browser"]["launchOptions"]["channel"], "chrome")
        self.assertIn("--kiosk", config["browser"]["launchOptions"]["args"])
        self.assertNotIn(
            "--start-fullscreen",
            config["browser"]["launchOptions"]["args"],
        )
        self.assertEqual(
            config["browser"]["contextOptions"]["screen"],
            {"width": 1920, "height": 1080},
        )

    def test_finds_the_kiosk_process_for_the_playwright_profile(self):
        module = load_module()
        profile = pathlib.Path("/private/tmp/hevc-profile")
        process_table = """
  101 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=/other
  202 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --kiosk --user-data-dir=/private/tmp/hevc-profile --remote-debugging-pipe
  203 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper --user-data-dir=/private/tmp/hevc-profile
"""

        self.assertEqual(module.find_kiosk_process_id(profile, process_table), 202)
        with self.assertRaises(RuntimeError):
            module.find_kiosk_process_id(profile, process_table.replace("--kiosk", ""))

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

    def test_scroll_program_commits_marker_on_first_real_scroll_event(self):
        module = load_module()
        program = module.scroll_program(sequence=4)
        self.assertEqual(program.count("page.mouse.wheel(0, 60)"), 1)
        self.assertIn("for (let step = 0; step < 12; step += 1)", program)
        self.assertIn("page.waitForTimeout(50)", program)
        self.assertIn('window.addEventListener("scroll"', program)
        self.assertIn("if (!committed)", program)
        self.assertIn("window.__experimentMarker.setSequence(4)", program)
        self.assertIn("marker.style.top = `${window.scrollY + 64}px`", program)
        self.assertLess(
            program.index('window.addEventListener("scroll"'),
            program.index("page.mouse.wheel(0, 60)"),
        )
        self.assertLess(
            program.index("page.mouse.wheel(0, 60)"),
            program.index("await markerCommit"),
        )
        with self.assertRaises(TypeError):
            module.scroll_program(sequence=4, interval_ms=1)

    def test_scroll_program_keeps_marker_in_the_detection_roi_for_the_burst(self):
        module = load_module()

        program = module.scroll_program(sequence=4)

        self.assertIn('window.addEventListener("scroll", followScroll)', program)
        self.assertIn('window.removeEventListener("scroll", followScroll)', program)
        self.assertIn("if (!committed)", program)
        self.assertNotIn("{ once: true }", program)
        self.assertLess(
            program.index("const markerEpochMs = await markerCommit"),
            program.index('window.removeEventListener("scroll", followScroll)'),
        )

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

    def test_capture_gate_enters_fullscreen_then_publishes_fixed_geometry(self):
        module = load_module()

        class Controller:
            def __init__(self):
                self.commands = []
                self.native_fullscreen_calls = 0

            def command(self, *arguments):
                self.commands.append(arguments)

            def enter_native_fullscreen(self):
                self.native_fullscreen_calls += 1

            def run_code(self, _program):
                return {
                    "width": 1920,
                    "height": 1080,
                    "scroll_y": 0,
                    "marker_sequence": 1,
                }

        class Writer:
            def __init__(self):
                self.rows = []

            def write(self, event, **fields):
                self.rows.append((event, fields))

        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            trigger = directory / "enter-fullscreen"
            ready = directory / "fullscreen-ready"
            trigger.write_text("sender-started\n")
            controller = Controller()
            writer = Writer()

            self.assertTrue(
                module.enter_capture_mode(
                    controller,
                    fullscreen=True,
                    trigger_file=trigger,
                    ready_file=ready,
                    writer=writer,
                    sleep=lambda _seconds: None,
                )
            )
            self.assertEqual(controller.commands, [])
            self.assertEqual(controller.native_fullscreen_calls, 1)
            self.assertEqual(ready.read_text(), "ready\n")
            self.assertEqual(writer.rows[0][0], "capture_view_ready")
            self.assertTrue(writer.rows[0][1]["valid"])


if __name__ == "__main__":
    unittest.main()
