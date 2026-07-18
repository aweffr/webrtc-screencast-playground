#!/usr/bin/env python3
import argparse
import json
import pathlib
import tempfile
import time
from typing import NamedTuple

from hevc_meeting_workload import (
    JSONLWriter,
    PlaywrightController,
    enter_capture_mode,
    sha256,
    wait_for_file,
    wait_until,
)


SCREENSHOT_PHASES = ("initial", "fast", "slow", "typed", "cursor", "final")
TYPED_TEXT = "会议投屏清晰度 A1"


class ActivityEpisode(NamedTuple):
    kind: str
    sequence: int
    planned_seconds: int
    expected_offset: int
    steps: int = 0
    step_pixels: int = 0
    interval_ms: int = 50


class WorkloadSchedule(NamedTuple):
    initial_static_seconds: int
    final_static_start_seconds: int
    total_seconds: int
    episodes: tuple[ActivityEpisode, ...]


def default_schedule() -> WorkloadSchedule:
    return WorkloadSchedule(
        initial_static_seconds=20,
        final_static_start_seconds=68,
        total_seconds=88,
        episodes=(
            ActivityEpisode("fast_scroll", 2, 20, 720, 12, 60),
            ActivityEpisode("fast_scroll", 3, 28, 1_440, 12, 60),
            ActivityEpisode("fast_scroll", 4, 36, 2_160, 12, 60),
            ActivityEpisode("slow_scroll", 5, 44, 2_880, 40, 18),
            ActivityEpisode("typing", 6, 52, 2_880),
            ActivityEpisode("cursor", 7, 60, 2_880),
        ),
    )


def scroll_program(
    *,
    sequence: int,
    steps: int,
    step_pixels: int,
    interval_ms: int,
) -> str:
    return f"""async page => {{
  const markerEpochMs = await page.evaluate((sequence) => {{
    const marker = document.getElementById("experiment-marker");
    marker.style.top = `${{window.scrollY + 64}}px`;
    window.__experimentMarker.setSequence(sequence);
    return performance.timeOrigin + performance.now();
  }}, {sequence});
  const offsets = [];
  for (let step = 0; step < {steps}; step += 1) {{
    await page.mouse.wheel(0, {step_pixels});
    await page.waitForTimeout({interval_ms});
    offsets.push(await page.evaluate(() => window.scrollY));
  }}
  return {{ marker_epoch_ms: markerEpochMs, offsets, actual_offset: offsets.at(-1) }};
}}"""


def typing_program(sequence: int) -> str:
    return f"""async page => {{
  const markerEpochMs = await page.evaluate(() => {{
    window.__experimentMarker.setSequence({sequence});
    return performance.timeOrigin + performance.now();
  }});
  const input = page.locator("#experiment-input");
  await input.click();
  for (const character of {json.dumps(TYPED_TEXT, ensure_ascii=False)}) {{
    await page.keyboard.insertText(character);
    await page.waitForTimeout(80);
  }}
  await page.evaluate(() => document.activeElement.blur());
  return {{ marker_epoch_ms: markerEpochMs, value: await input.inputValue() }};
}}"""


def cursor_program(sequence: int) -> str:
    return f"""async page => {{
  const markerEpochMs = await page.evaluate(() => {{
    window.__experimentMarker.setSequence({sequence});
    return performance.timeOrigin + performance.now();
  }});
  const points = [[440,300],[520,340],[600,380],[680,420],[760,460],[840,500],
                  [920,540],[1000,580],[1080,620],[1160,660],[1240,700],[1320,740]];
  for (let index = 0; index < points.length; index += 1) {{
    await page.mouse.move(points[index][0], points[index][1]);
    await page.waitForTimeout(50);
  }}
  return {{ marker_epoch_ms: markerEpochMs, point_count: points.length }};
}}"""


def final_state_program() -> str:
    return "async page => await page.evaluate(() => ({scroll_y: scrollY, marker_sequence: Number(document.getElementById('experiment-marker').dataset.sequence)}))"


def epoch_ms_to_monotonic_ns(epoch_ms: float) -> int:
    return round(epoch_ms * 1_000_000) + (time.monotonic_ns() - time.time_ns())


def capture_screenshot(
    controller: PlaywrightController,
    writer: JSONLWriter,
    output_directory: pathlib.Path,
    phase: str,
) -> None:
    path = output_directory / f"{phase}.png"
    controller.screenshot(path)
    writer.write(
        "screenshot",
        phase=phase,
        monotonic_ns=time.monotonic_ns(),
        path=path.name,
        sha256=sha256(path),
    )


def run_workload(
    *,
    url: str,
    output_directory: pathlib.Path,
    expected_chrome_version: str,
    session: str,
    executable: str,
    start_file: pathlib.Path | None,
    fullscreen_trigger_file: pathlib.Path | None,
    fullscreen_ready_file: pathlib.Path | None,
) -> bool:
    schedule = default_schedule()
    output_directory.mkdir(parents=True, exist_ok=True)
    evidence_path = output_directory / "workload.jsonl"
    if evidence_path.exists():
        raise RuntimeError(f"refusing to overwrite {evidence_path}")
    writer = JSONLWriter(evidence_path)
    controller = PlaywrightController(executable, session)
    with tempfile.TemporaryDirectory(prefix="damage-idle-chrome-") as profile:
        controller.open(url, pathlib.Path(profile))
        try:
            controller.command("press", "Meta+0")
            readiness = controller.run_code(
                """async page => {
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.mouse.move(960, 540);
  return await page.evaluate(() => ({
    width: innerWidth,
    height: innerHeight,
    scroll_y: scrollY,
    scroll_height: document.documentElement.scrollHeight,
    marker_sequence: Number(document.getElementById("experiment-marker").dataset.sequence),
    marker: document.getElementById("experiment-marker").getBoundingClientRect().toJSON(),
    zoom: visualViewport.scale,
  }));
}"""
            )
            chrome_version = controller.run_code(
                "async page => ({version: page.context().browser().version()})"
            )["version"]
            marker = readiness["marker"]
            ready = (
                chrome_version == expected_chrome_version
                and readiness["width"] == 1_920
                and readiness["height"] == 1_080
                and readiness["scroll_y"] == 0
                and readiness["scroll_height"] >= 5_400
                and readiness["marker_sequence"] == 1
                and readiness["zoom"] == 1
                and [round(marker[key]) for key in ("x", "y", "width", "height")]
                == [64, 64, 192, 192]
            )
            writer.write(
                "workload_ready",
                monotonic_ns=time.monotonic_ns(),
                chrome_version=chrome_version,
                readiness=readiness,
                valid=ready,
            )
            if not ready or not enter_capture_mode(
                controller,
                fullscreen=True,
                trigger_file=fullscreen_trigger_file,
                ready_file=fullscreen_ready_file,
                writer=writer,
            ):
                return False
            if start_file is not None:
                wait_for_file(start_file)
            start_ns = time.monotonic_ns()
            writer.write("workload_started", monotonic_ns=start_ns)
            capture_screenshot(controller, writer, output_directory, "initial")

            episodes_valid = True
            for index, episode in enumerate(schedule.episodes):
                planned_ns = start_ns + episode.planned_seconds * 1_000_000_000
                wait_until(planned_ns)
                actual_ns = time.monotonic_ns()
                if episode.kind.endswith("scroll"):
                    result = controller.run_code(scroll_program(
                        sequence=episode.sequence,
                        steps=episode.steps,
                        step_pixels=episode.step_pixels,
                        interval_ms=episode.interval_ms,
                    ))
                elif episode.kind == "typing":
                    result = controller.run_code(typing_program(episode.sequence))
                else:
                    result = controller.run_code(cursor_program(episode.sequence))
                if episode.kind.endswith("scroll"):
                    episode_valid = abs(round(result["actual_offset"]) - episode.expected_offset) <= 1
                elif episode.kind == "typing":
                    episode_valid = result["value"] == TYPED_TEXT
                else:
                    episode_valid = result["point_count"] == 12
                episodes_valid = episodes_valid and episode_valid
                row = {
                    "kind": episode.kind,
                    "sequence": episode.sequence,
                    "planned_monotonic_ns": planned_ns,
                    "actual_monotonic_ns": actual_ns,
                    "marker_monotonic_ns": epoch_ms_to_monotonic_ns(result["marker_epoch_ms"]),
                    "expected_offset": episode.expected_offset,
                    "result": result,
                    "valid": episode_valid,
                }
                writer.write("activity_episode", **row)
                if index == 2:
                    capture_screenshot(controller, writer, output_directory, "fast")
                elif index == 3:
                    capture_screenshot(controller, writer, output_directory, "slow")
                elif index == 4:
                    capture_screenshot(controller, writer, output_directory, "typed")
                elif index == 5:
                    capture_screenshot(controller, writer, output_directory, "cursor")

            final_ns = start_ns + schedule.total_seconds * 1_000_000_000
            wait_until(final_ns)
            final_state = controller.run_code(final_state_program())
            writer.write("final_static", monotonic_ns=time.monotonic_ns(), state=final_state)
            capture_screenshot(controller, writer, output_directory, "final")
            valid = episodes_valid and abs(final_state["scroll_y"] - 2_880) <= 1 \
                and final_state["marker_sequence"] == 7
            writer.write("workload_completed", monotonic_ns=time.monotonic_ns(), valid=valid)
            return valid
        finally:
            controller.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--output-directory", required=True, type=pathlib.Path)
    parser.add_argument("--expected-chrome-version", default="150.0.7871.129")
    # Keep the session short: playwright-cli embeds it in a Unix socket path.
    parser.add_argument("--session", default="diw")
    parser.add_argument("--playwright-cli", default="playwright-cli")
    parser.add_argument("--start-file", type=pathlib.Path)
    parser.add_argument("--fullscreen-trigger-file", type=pathlib.Path)
    parser.add_argument("--fullscreen-ready-file", type=pathlib.Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    return 0 if run_workload(
        url=args.url,
        output_directory=args.output_directory,
        expected_chrome_version=args.expected_chrome_version,
        session=args.session,
        executable=args.playwright_cli,
        start_file=args.start_file,
        fullscreen_trigger_file=args.fullscreen_trigger_file,
        fullscreen_ready_file=args.fullscreen_ready_file,
    ) else 1


if __name__ == "__main__":
    raise SystemExit(main())
