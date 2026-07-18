import importlib.util
import pathlib
import sys
import unittest


MODULE_PATH = pathlib.Path(__file__).with_name("damage_idle_workload.py")


def load_module():
    sys.path.insert(0, str(MODULE_PATH.parent))
    spec = importlib.util.spec_from_file_location("damage_idle_workload", MODULE_PATH)
    try:
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        sys.path.pop(0)


class DamageIdleWorkloadTests(unittest.TestCase):
    def setUp(self):
        self.workload = load_module()

    def test_schedule_has_exactly_six_bounded_activity_episodes(self):
        schedule = self.workload.default_schedule()

        self.assertEqual(schedule.initial_static_seconds, 20)
        self.assertEqual(schedule.final_static_start_seconds, 68)
        self.assertEqual(schedule.total_seconds, 88)
        self.assertEqual(
            [(episode.kind, episode.planned_seconds) for episode in schedule.episodes],
            [
                ("fast_scroll", 20),
                ("fast_scroll", 28),
                ("fast_scroll", 36),
                ("slow_scroll", 44),
                ("typing", 52),
                ("cursor", 60),
            ],
        )

    def test_scroll_programs_use_fixed_steps_and_content_bound_marker(self):
        fast = self.workload.scroll_program(
            sequence=2,
            expected_offset=720,
            steps=12,
            step_pixels=60,
            interval_ms=50,
        )
        slow = self.workload.scroll_program(
            sequence=5,
            expected_offset=1440,
            steps=40,
            step_pixels=18,
            interval_ms=50,
        )

        self.assertIn("marker.style.top = `${expectedOffset + 64}px`", fast)
        self.assertIn("step < 12", fast)
        self.assertIn("page.mouse.wheel(0, 60)", fast)
        self.assertIn("step < 40", slow)
        self.assertIn("page.mouse.wheel(0, 18)", slow)
        self.assertNotIn("position: fixed", fast)

    def test_typing_and_cursor_programs_have_one_marker_commit_each(self):
        typing = self.workload.typing_program(sequence=6)
        cursor = self.workload.cursor_program(sequence=7)

        self.assertEqual(typing.count("setSequence(6)"), 1)
        self.assertIn("waitForTimeout(80)", typing)
        self.assertIn("document.activeElement.blur()", typing)
        self.assertEqual(cursor.count("setSequence(7)"), 1)
        self.assertIn("const points =", cursor)
        self.assertIn("points.length", cursor)
        self.assertIn("waitForTimeout(50)", cursor)

    def test_quality_screenshots_are_fixed_and_final_does_not_update_marker(self):
        self.assertEqual(
            self.workload.SCREENSHOT_PHASES,
            ("initial", "fast", "slow", "typed", "cursor", "final"),
        )
        self.assertNotIn("setSequence", self.workload.final_state_program())


if __name__ == "__main__":
    unittest.main()
