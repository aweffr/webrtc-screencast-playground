#!/usr/bin/env python3
import argparse
import json
import pathlib
import subprocess
import sys


MANAGED_DISPLAY_NAMES = (
    "WebRTC Screencast Extended Display",
    "WebRTC Screencast Removal Companion",
)


def count_named_displays(payload, display_name):
    if isinstance(payload, dict):
        count = int(payload.get("_name") == display_name)
        nested = sum(
            count_named_displays(value, display_name)
            for value in payload.values()
        )
        return count + nested
    if isinstance(payload, list):
        return sum(count_named_displays(value, display_name) for value in payload)
    return 0


def load_payload(input_path):
    if input_path is not None:
        return json.loads(pathlib.Path(input_path).read_text(encoding="utf-8"))
    completed = subprocess.run(
        ["system_profiler", "-json", "SPDisplaysDataType"],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(completed.stdout)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Verify that the media baseline owns no stale virtual displays."
    )
    parser.add_argument("--expect", type=int, required=True)
    parser.add_argument("--input", help="Read a saved system_profiler JSON fixture.")
    args = parser.parse_args(argv)

    try:
        payload = load_payload(args.input)
    except (OSError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"unable to inspect display state: {error}", file=sys.stderr)
        return 2

    counts = {
        name: count_named_displays(payload, name)
        for name in MANAGED_DISPLAY_NAMES
    }
    observed = sum(counts.values())
    if observed != args.expect:
        details = ", ".join(f"{name}={count}" for name, count in counts.items())
        print(
            f"expected {args.expect} managed virtual displays, observed {observed} ({details}); "
            "stop the baseline and reset the user session before retrying",
            file=sys.stderr,
        )
        return 1
    print(f"managed virtual display count: {observed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
