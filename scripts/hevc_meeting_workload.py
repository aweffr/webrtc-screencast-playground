#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import tempfile
import time
from typing import NamedTuple


QUALITY_EVIDENCE_SEQUENCES = (1, 4, 8)


def browser_launch_config() -> dict:
    return {
        "browser": {
            "browserName": "chromium",
            "launchOptions": {
                "channel": "chrome",
                "headless": False,
                "args": ["--kiosk"],
            },
            "contextOptions": {
                "screen": {"width": 1920, "height": 1080},
                "viewport": {"width": 1920, "height": 1080},
            },
        }
    }


def find_kiosk_process_id(profile: pathlib.Path, process_table: str) -> int:
    profile_argument = f"--user-data-dir={profile}"
    executable = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    for row in process_table.splitlines():
        fields = row.strip().split(maxsplit=1)
        if len(fields) != 2:
            continue
        process_id, command = fields
        if command.startswith(executable) and "--kiosk" in command and profile_argument in command:
            return int(process_id)
    raise RuntimeError("Chrome kiosk process was not found")


def activate_chrome_fullscreen(profile: pathlib.Path) -> None:
    deadline = time.monotonic() + 5
    while True:
        process_table = subprocess.run(
            ["ps", "-axo", "pid=,command="],
            check=True,
            text=True,
            capture_output=True,
        ).stdout
        try:
            process_id = find_kiosk_process_id(profile, process_table)
            break
        except RuntimeError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.1)
    program = (
        "import AppKit; import CoreGraphics; import Foundation; "
        f"guard let app = NSRunningApplication(processIdentifier: {process_id}) "
        "else { exit(2) }; app.unhide(); "
        "guard app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) "
        "else { exit(3) }; usleep(250000); "
        "let source = CGEventSource(stateID: .hidSystemState); "
        "let flags: CGEventFlags = [.maskControl, .maskCommand]; "
        "let down = CGEvent(keyboardEventSource: source, virtualKey: 3, keyDown: true); "
        "down?.flags = flags; down?.post(tap: .cghidEventTap); usleep(80000); "
        "let up = CGEvent(keyboardEventSource: source, virtualKey: 3, keyDown: false); "
        "up?.flags = flags; up?.post(tap: .cghidEventTap)"
    )
    subprocess.run(["/usr/bin/swift", "-e", program], check=True, capture_output=True)


class ScrollBurst(NamedTuple):
    sequence: int
    planned_seconds: int
    expected_offset: int
    steps: int = 12
    step_pixels: int = 60
    step_interval_seconds: float = 0.05


class WorkloadSchedule(NamedTuple):
    initial_static_seconds: int
    scroll_phase_end_seconds: int
    final_static_seconds: int
    bursts: tuple[ScrollBurst, ...]

    @property
    def total_seconds(self) -> int:
        return self.scroll_phase_end_seconds + self.final_static_seconds


def default_schedule() -> WorkloadSchedule:
    return WorkloadSchedule(
        initial_static_seconds=20,
        scroll_phase_end_seconds=68,
        final_static_seconds=20,
        bursts=tuple(
            ScrollBurst(
                sequence=index,
                planned_seconds=20 + (index - 1) * 8,
                expected_offset=index * 720,
            )
            for index in range(1, 7)
        ),
    )


def validate_burst_evidence(rows: list[dict]) -> bool:
    if [row.get("sequence") for row in rows] != list(range(1, 7)):
        return False
    return all(
        row.get("expected_offset") == index * 720
        and abs(row.get("actual_offset", -10_000) - index * 720) <= 1
        for index, row in enumerate(rows, start=1)
    )


def scroll_program(sequence: int) -> str:
    return f"""async page => {{
  const markerEpochMs = await page.evaluate(() => {{
    window.__experimentMarker.setSequence({sequence});
    return performance.timeOrigin + performance.now();
  }});
  const offsets = [];
  for (let step = 0; step < 12; step += 1) {{
    await page.mouse.wheel(0, 60);
    await page.waitForTimeout(50);
    offsets.push(await page.evaluate(() => window.scrollY));
  }}
  return {{ marker_epoch_ms: markerEpochMs, offsets, actual_offset: offsets[offsets.length - 1] }};
}}"""


class JSONLWriter:
    def __init__(self, path: pathlib.Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def write(self, event: str, **fields) -> None:
        row = {"event": event, **fields}
        with self.path.open("a", encoding="utf-8") as output:
            output.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")


class PlaywrightController:
    def __init__(self, executable: str, session: str):
        self.executable = executable
        self.session = session
        self.profile: pathlib.Path | None = None

    def command(self, *arguments: str, raw: bool = False) -> str:
        command = [self.executable, f"-s={self.session}"]
        if raw:
            command.append("--raw")
        command.extend(arguments)
        result = subprocess.run(command, check=True, text=True, capture_output=True)
        return result.stdout.strip()

    def open(self, url: str, profile: pathlib.Path) -> None:
        self.profile = profile
        config = profile / "playwright-cli.json"
        config.write_text(
            json.dumps(browser_launch_config(), sort_keys=True),
            encoding="utf-8",
        )
        self.command(
            "open",
            url,
            "--headed",
            f"--profile={profile}",
            f"--config={config}",
        )

    def enter_native_fullscreen(self) -> None:
        if self.profile is None:
            raise RuntimeError("Chrome profile is not open")
        activate_chrome_fullscreen(self.profile)

    def run_code(self, program: str) -> dict:
        return json.loads(self.command("run-code", program, raw=True))

    def screenshot(self, path: pathlib.Path) -> None:
        subprocess.run(
            ["screencapture", "-x", "-D", "1", str(path)],
            check=True,
            capture_output=True,
        )

    def close(self) -> None:
        self.command("close")


def wait_until(target_ns: int) -> None:
    while True:
        remaining = (target_ns - time.monotonic_ns()) / 1_000_000_000
        if remaining <= 0:
            return
        time.sleep(min(remaining, 0.1))


def wait_for_file(path: pathlib.Path, timeout_seconds: float = 120) -> None:
    deadline = time.monotonic() + timeout_seconds
    while not path.is_file():
        if time.monotonic() >= deadline:
            raise RuntimeError(f"timed out waiting for {path.name}")
        time.sleep(0.1)


def enter_capture_mode(
    controller: PlaywrightController,
    *,
    fullscreen: bool,
    trigger_file: pathlib.Path | None,
    ready_file: pathlib.Path | None,
    writer: JSONLWriter,
    sleep=time.sleep,
) -> bool:
    if not fullscreen:
        return True
    if trigger_file is not None:
        wait_for_file(trigger_file)
    controller.enter_native_fullscreen()
    sleep(2)
    state = controller.run_code(
        "async page => await page.evaluate(() => ({width: innerWidth, height: innerHeight, scroll_y: scrollY, marker_sequence: Number(document.getElementById('experiment-marker').dataset.sequence)}))"
    )
    valid = (
        state["width"] == 1920
        and state["height"] == 1080
        and state["scroll_y"] == 0
        and state["marker_sequence"] == 1
    )
    writer.write(
        "capture_view_ready",
        monotonic_ns=time.monotonic_ns(),
        state=state,
        valid=valid,
    )
    if valid and ready_file is not None:
        ready_file.write_text("ready\n", encoding="utf-8")
    return valid


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_workload(
    *,
    url: str,
    output_directory: pathlib.Path,
    expected_chrome_version: str,
    session: str,
    time_scale: float,
    fullscreen: bool,
    executable: str,
    ready_file: pathlib.Path | None = None,
    start_file: pathlib.Path | None = None,
    fullscreen_trigger_file: pathlib.Path | None = None,
    fullscreen_ready_file: pathlib.Path | None = None,
) -> bool:
    schedule = default_schedule()
    output_directory.mkdir(parents=True, exist_ok=True)
    evidence_path = output_directory / "workload.jsonl"
    if evidence_path.exists():
        raise RuntimeError(f"refusing to overwrite {evidence_path}")
    writer = JSONLWriter(evidence_path)
    controller = PlaywrightController(executable, session)
    burst_rows: list[dict] = []
    with tempfile.TemporaryDirectory(prefix="hevc-meeting-chrome-") as profile:
        controller.open(url, pathlib.Path(profile))
        try:
            controller.command("press", "Meta+0")
            readiness = controller.run_code(
                """async page => {
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.mouse.move(960, 540);
  return await page.evaluate(() => ({
    chrome_version: navigator.userAgent,
    width: innerWidth,
    height: innerHeight,
    screen_width: screen.width,
    screen_height: screen.height,
    scroll_height: document.documentElement.scrollHeight,
    scroll_y: scrollY,
    marker: document.getElementById("experiment-marker").getBoundingClientRect().toJSON(),
    marker_sequence: Number(document.getElementById("experiment-marker").dataset.sequence),
    zoom: visualViewport.scale,
  }));
}"""
            )
            browser = controller.run_code(
                "async page => ({version: page.context().browser().version()})"
            )
            chrome_version = browser["version"]
            marker = readiness["marker"]
            ready = (
                chrome_version == expected_chrome_version
                and readiness["width"] == 1920
                and readiness["height"] == 1080
                and readiness["scroll_height"] >= 5400
                and readiness["scroll_y"] == 0
                and readiness["marker_sequence"] == 1
                and readiness["zoom"] == 1
                and [marker[key] for key in ("x", "y", "width", "height")]
                == [64, 64, 192, 192]
            )
            writer.write(
                "workload_started",
                monotonic_ns=time.monotonic_ns(),
                chrome_version=chrome_version,
                time_scale=time_scale,
                readiness=readiness,
                valid=ready,
            )
            if not ready:
                return False

            if ready_file is not None:
                ready_file.write_text("ready\n", encoding="utf-8")
            if not enter_capture_mode(
                controller,
                fullscreen=fullscreen,
                trigger_file=fullscreen_trigger_file,
                ready_file=fullscreen_ready_file,
                writer=writer,
            ):
                return False
            initial_path = output_directory / "initial-static.png"
            controller.screenshot(initial_path)
            writer.write(
                "screenshot",
                phase="initial_static",
                monotonic_ns=time.monotonic_ns(),
                scroll_y=0,
                path=initial_path.name,
                sha256=sha256(initial_path),
            )
            if start_file is not None:
                writer.write("workload_waiting_for_media", monotonic_ns=time.monotonic_ns())
                wait_for_file(start_file)
            start_ns = time.monotonic_ns()
            for burst in schedule.bursts:
                planned_ns = start_ns + round(burst.planned_seconds * time_scale * 1_000_000_000)
                wait_until(planned_ns)
                epoch_to_monotonic_ns = time.monotonic_ns() - time.time_ns()
                actual_ns = time.monotonic_ns()
                result = controller.run_code(scroll_program(burst.sequence + 1))
                marker_monotonic_ns = round(result["marker_epoch_ms"] * 1_000_000) + epoch_to_monotonic_ns
                actual_offset = round(result["actual_offset"])
                row = {
                    "sequence": burst.sequence,
                    "planned_monotonic_ns": planned_ns,
                    "actual_monotonic_ns": actual_ns,
                    "marker_monotonic_ns": marker_monotonic_ns,
                    "expected_offset": burst.expected_offset,
                    "actual_offset": actual_offset,
                    "step_offsets": result["offsets"],
                    "valid": abs(actual_offset - burst.expected_offset) <= 1,
                }
                burst_rows.append(row)
                writer.write("scroll_burst", **row)
                if burst.sequence == 3:
                    middle_path = output_directory / "middle-scroll.png"
                    controller.screenshot(middle_path)
                    writer.write(
                        "screenshot",
                        phase="middle_scroll",
                        monotonic_ns=time.monotonic_ns(),
                        scroll_y=actual_offset,
                        path=middle_path.name,
                        sha256=sha256(middle_path),
                    )

            settle_start_ns = start_ns + round(
                schedule.scroll_phase_end_seconds * time_scale * 1_000_000_000
            )
            wait_until(settle_start_ns)
            writer.write("final_static_started", monotonic_ns=time.monotonic_ns())
            wait_until(
                start_ns + round(schedule.total_seconds * time_scale * 1_000_000_000)
            )
            epoch_to_monotonic_ns = time.monotonic_ns() - time.time_ns()
            final_marker = controller.run_code(
                f"""async page => await page.evaluate(() => {{
  window.__experimentMarker.setSequence({QUALITY_EVIDENCE_SEQUENCES[-1]});
  return {{ marker_epoch_ms: performance.timeOrigin + performance.now() }};
}})"""
            )
            final_marker_monotonic_ns = (
                round(final_marker["marker_epoch_ms"] * 1_000_000) + epoch_to_monotonic_ns
            )
            writer.write(
                "final_marker",
                sequence=QUALITY_EVIDENCE_SEQUENCES[-1],
                marker_monotonic_ns=final_marker_monotonic_ns,
            )
            time.sleep(1)
            final_state = controller.run_code(
                "async page => await page.evaluate(() => ({scroll_y: scrollY, marker_sequence: Number(document.getElementById('experiment-marker').dataset.sequence)}))"
            )
            final_path = output_directory / "final-static.png"
            controller.screenshot(final_path)
            valid = (
                validate_burst_evidence(burst_rows)
                and abs(round(final_state["scroll_y"]) - 4320) <= 1
                and final_state["marker_sequence"] == QUALITY_EVIDENCE_SEQUENCES[-1]
            )
            writer.write(
                "screenshot",
                phase="final_static",
                monotonic_ns=time.monotonic_ns(),
                scroll_y=round(final_state["scroll_y"]),
                path=final_path.name,
                sha256=sha256(final_path),
            )
            writer.write("workload_completed", monotonic_ns=time.monotonic_ns(), valid=valid)
            return valid
        finally:
            controller.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--output-directory", type=pathlib.Path, required=True)
    parser.add_argument("--expected-chrome-version", default="150.0.7871.129")
    parser.add_argument("--session", default="hmw")
    parser.add_argument("--time-scale", type=float, default=1.0)
    parser.add_argument("--no-fullscreen", action="store_true")
    parser.add_argument("--ready-file", type=pathlib.Path)
    parser.add_argument("--start-file", type=pathlib.Path)
    parser.add_argument("--fullscreen-trigger-file", type=pathlib.Path)
    parser.add_argument("--fullscreen-ready-file", type=pathlib.Path)
    args = parser.parse_args()
    if not 0 < args.time_scale <= 1:
        parser.error("--time-scale must be in (0, 1]")
    executable = shutil.which("playwright-cli")
    if not executable:
        parser.error("playwright-cli is required")
    valid = run_workload(
        url=args.url,
        output_directory=args.output_directory,
        expected_chrome_version=args.expected_chrome_version,
        session=args.session,
        time_scale=args.time_scale,
        fullscreen=not args.no_fullscreen,
        executable=executable,
        ready_file=args.ready_file,
        start_file=args.start_file,
        fullscreen_trigger_file=args.fullscreen_trigger_file,
        fullscreen_ready_file=args.fullscreen_ready_file,
    )
    raise SystemExit(0 if valid else 1)


if __name__ == "__main__":
    main()
