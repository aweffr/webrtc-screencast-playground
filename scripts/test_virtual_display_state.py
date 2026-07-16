import contextlib
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest


MODULE_PATH = pathlib.Path(__file__).with_name("check-virtual-display-state.py")
SPEC = importlib.util.spec_from_file_location("virtual_display_state", MODULE_PATH)
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)


class VirtualDisplayStateTests(unittest.TestCase):
    def test_counts_nested_display_names(self):
        payload = profiler_payload([
            "Built-in Retina Display",
            "WebRTC Screencast Extended Display",
            "WebRTC Screencast Extended Display",
            "WebRTC Screencast Extended Display",
        ])

        self.assertEqual(
            checker.count_named_displays(payload, "WebRTC Screencast Extended Display"),
            3,
        )
        self.assertEqual(
            checker.count_named_displays(payload, "WebRTC Screencast Removal Companion"),
            0,
        )

    def test_main_accepts_only_expected_managed_display_count(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            clean = root / "clean.json"
            leaked = root / "leaked.json"
            clean.write_text(json.dumps(profiler_payload(["Color LCD"])), encoding="utf-8")
            leaked.write_text(
                json.dumps(profiler_payload(["WebRTC Screencast Removal Companion"])),
                encoding="utf-8",
            )

            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(
                io.StringIO()
            ):
                self.assertEqual(checker.main(["--expect", "0", "--input", str(clean)]), 0)
                self.assertNotEqual(checker.main(["--expect", "0", "--input", str(leaked)]), 0)


def profiler_payload(display_names):
    return {
        "SPDisplaysDataType": [{
            "_name": "Apple M-series",
            "spdisplays_ndrvs": [{"_name": name} for name in display_names],
        }],
    }


if __name__ == "__main__":
    unittest.main()
