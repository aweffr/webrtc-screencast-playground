#!/usr/bin/env python3
import argparse
import copy
import functools
import json
import math
import pathlib
import re
import statistics
import subprocess
from typing import NamedTuple


class PolicyCase(NamedTuple):
    case_id: str
    codec_policy: str
    static_max_qp: int | None
    active_max_qp: int | None
    repetitions: int
    spatial_aq: str = "DEFAULT"
    allow_frame_reordering: bool = False
    low_latency_rate_control: bool = False


def base_cases() -> tuple[PolicyCase, ...]:
    return (
        PolicyCase("A0", "h264-only", 24, 32, 3),
        PolicyCase("A1", "h265-only", 24, 32, 3),
        PolicyCase("B0", "h265-only", 33, 39, 3),
        PolicyCase("B1", "h265-only", 30, 39, 3),
    )


def feature_cases(winner: PolicyCase) -> tuple[PolicyCase, ...]:
    common = {
        "codec_policy": "h265-only",
        "static_max_qp": winner.static_max_qp,
        "active_max_qp": winner.active_max_qp,
        "repetitions": 2,
    }
    return (
        PolicyCase("C0", **common, spatial_aq="DISABLE"),
        PolicyCase("C1", **common, allow_frame_reordering=True),
        PolicyCase(
            "C2",
            "h265-only",
            None,
            None,
            2,
            low_latency_rate_control=True,
        ),
    )


def stage_order(cases: tuple[PolicyCase, ...]) -> list[str]:
    groups = (("A0", "A1"), ("B0", "B1"), ("C0", "C1", "C2"))
    by_id = {case.case_id: case for case in cases}
    result = []
    for group in groups:
        present = [by_id[case_id] for case_id in group if case_id in by_id]
        if not present:
            continue
        for repetition in range(max(case.repetitions for case in present)):
            result.extend(case.case_id for case in present if repetition < case.repetitions)
    return result


def should_run_features(results: dict[str, dict]) -> bool:
    return any(results.get(case_id, {}).get("eligible") is True
               for case_id in ("A1", "B0", "B1"))


class AttemptBudget:
    def __init__(self, max_attempts: int = 23, max_retries: int = 4):
        self.max_attempts = max_attempts
        self.max_retries = max_retries
        self.total_attempts = 0
        self.infrastructure_retries = 0
        self.attempts_by_case: dict[str, int] = {}

    def can_attempt(self, case_id: str) -> bool:
        attempts = self.attempts_by_case.get(case_id, 0)
        return (
            self.total_attempts < self.max_attempts
            and attempts < 2
            and (attempts == 0 or self.infrastructure_retries < self.max_retries)
        )

    def record_attempt(self, case_id: str) -> None:
        prior = self.attempts_by_case.get(case_id, 0)
        self.attempts_by_case[case_id] = prior + 1
        self.total_attempts += 1
        if prior > 0:
            self.infrastructure_retries += 1


def generate_configs(
    runtime: dict,
    tuning: dict,
    case: PolicyCase,
) -> tuple[dict, dict]:
    generated_runtime = copy.deepcopy(runtime)
    generated_tuning = copy.deepcopy(tuning)
    generated_runtime["video_codec_policy"] = case.codec_policy
    encoder = generated_tuning["encoder"]
    if case.codec_policy == "h264-only":
        # The fixed Android reference decoder has no High-profile intersection.
        # Keep the 1080p level explicit so A0 remains a valid deployable baseline.
        encoder["h264_profile"] = "CONSTRAINED_BASELINE"
        encoder["h264_level"] = "4.1"
    encoder["allow_frame_reordering"] = case.allow_frame_reordering
    encoder["video_toolbox_low_latency_rate_control"] = case.low_latency_rate_control
    if case.low_latency_rate_control:
        generated_runtime.pop("static_max_qp", None)
        encoder.pop("max_qp", None)
        encoder.pop("video_toolbox_spatial_adaptive_qp", None)
    else:
        generated_runtime["static_max_qp"] = case.static_max_qp
        encoder["max_qp"] = case.active_max_qp
        encoder["video_toolbox_spatial_adaptive_qp"] = case.spatial_aq
    return generated_runtime, generated_tuning


def evaluate_gates(baseline: dict, candidate: dict) -> dict:
    failures = []
    checks = (
        (candidate["first_frame_ms"] <= baseline["first_frame_ms"] + 100,
         "first_frame_regression"),
        (candidate["active_e2e_p95_ms"] <= baseline["active_e2e_p95_ms"] + 10,
         "active_latency_regression"),
        (candidate["max_render_gap_ms"] <= 500, "render_freeze"),
        (candidate["vt_drop_ratio"] <= 0.01, "video_toolbox_drop"),
        (candidate["marker_sequence_delivery_ratio"] == 1.0,
         "marker_sequence_delivery"),
        (candidate["max_bitrate_bps"] <= 5_000_000, "bitrate_cap"),
        (candidate["state_cycles"] == 6, "content_state_cycles"),
        (candidate["manual_text_clear"] is True, "manual_text_clarity"),
    )
    failures.extend(name for passed, name in checks if not passed)
    ssim_regression = baseline["static_ssim_y_worst"] - candidate["static_ssim_y_worst"]
    psnr_regression = baseline["static_psnr_y_worst"] - candidate["static_psnr_y_worst"]
    if ssim_regression > 0.002 and psnr_regression > 0.5:
        failures.append("static_image_quality")
    return {"eligible": not failures, "failures": failures}


def select_winner(candidates: list[dict]) -> dict | None:
    eligible = [candidate for candidate in candidates
                if candidate.get("eligible") is True
                and candidate.get("static_max_qp") is not None]
    if not eligible:
        return None
    return sorted(eligible, key=functools.cmp_to_key(_compare_candidates))[0]


def _compare_candidates(left: dict, right: dict) -> int:
    for key, tolerance, higher_is_better in (
        ("static_ssim_y_worst", 0.002, True),
        ("static_psnr_y_worst", 0.5, True),
        ("active_e2e_p95_ms", 5.0, False),
        ("first_frame_ms", 5.0, False),
    ):
        difference = left[key] - right[key]
        if abs(difference) >= tolerance:
            left_wins = difference > 0 if higher_is_better else difference < 0
            return -1 if left_wins else 1
    for key in ("vt_drop_ratio", "max_render_gap_ms", "max_bitrate_bps"):
        if left[key] != right[key]:
            return -1 if left[key] < right[key] else 1
    if left["static_max_qp"] != right["static_max_qp"]:
        return -1 if left["static_max_qp"] > right["static_max_qp"] else 1
    if left["case_id"] == right["case_id"]:
        return 0
    return -1 if left["case_id"] < right["case_id"] else 1


def aggregate_runs(case: PolicyCase, runs: list[dict]) -> dict:
    latency_samples = [sample for run in runs
                       for sample in run.get("active_e2e_samples_ms", [])]
    marker_valid = sum(run.get("marker_valid", 0) for run in runs)
    marker_total = sum(run.get("marker_total", 0) for run in runs)
    result = {
        "case_id": case.case_id,
        "static_max_qp": case.static_max_qp,
        "active_max_qp": case.active_max_qp,
        "first_frame_ms": statistics.median(run["first_frame_ms"] for run in runs),
        "active_e2e_p95_ms": percentile(latency_samples, 0.95) if latency_samples else max(
            run["active_e2e_p95_ms"] for run in runs),
        "max_render_gap_ms": max(run["max_render_gap_ms"] for run in runs),
        "vt_drop_ratio": max(run["vt_drop_ratio"] for run in runs),
        "marker_sequence_delivery_ratio": (
            marker_valid / marker_total if marker_total else min(
                run["marker_sequence_delivery_ratio"] for run in runs
            )
        ),
        "max_bitrate_bps": max(run["max_bitrate_bps"] for run in runs),
        "state_cycles": min(run["state_cycles"] for run in runs),
        "static_ssim_y_worst": min(run["static_ssim_y_worst"] for run in runs),
        "static_psnr_y_worst": min(run["static_psnr_y_worst"] for run in runs),
        "manual_text_clear": all(run["manual_text_clear"] for run in runs),
        "run_count": len(runs),
    }
    result.update(aggregate_qp_distribution(runs))
    return result


def aggregate_qp_distribution(runs: list[dict]) -> dict:
    key_histogram = [0] * 52
    delta_histogram = [0] * 52
    found = False
    for run in runs:
        telemetry = run.get("encoder_telemetry")
        if not isinstance(telemetry, dict):
            continue
        found = True
        for target, field in (
            (key_histogram, "key_qp_histogram"),
            (delta_histogram, "delta_qp_histogram"),
        ):
            values = telemetry.get(field, [])
            if len(values) != 52:
                raise RuntimeError(f"{field} must contain 52 QP buckets")
            for index, count in enumerate(values):
                target[index] += count
    if not found:
        return {}

    def quantile(histogram: list[int], fraction: float) -> int | None:
        total = sum(histogram)
        if total == 0:
            return None
        target = math.ceil(total * fraction)
        cumulative = 0
        for qp, count in enumerate(histogram):
            cumulative += count
            if cumulative >= target:
                return qp
        raise AssertionError("unreachable histogram quantile")

    observed = [qp for qp in range(52)
                if key_histogram[qp] or delta_histogram[qp]]
    return {
        "key_qp_p50": quantile(key_histogram, 0.50),
        "key_qp_p95": quantile(key_histogram, 0.95),
        "delta_qp_p50": quantile(delta_histogram, 0.50),
        "delta_qp_p95": quantile(delta_histogram, 0.95),
        "observed_qp_max": max(observed) if observed else None,
    }


def build_base_report(analyses: dict[str, list[dict]]) -> dict:
    cases = base_cases()
    aggregates = []
    for case in cases:
        runs = analyses.get(case.case_id, [])
        if len(runs) != case.repetitions:
            raise RuntimeError(
                f"{case.case_id} requires {case.repetitions} analyzed runs, found {len(runs)}"
            )
        aggregates.append(aggregate_runs(case, runs))

    baseline = aggregates[0]
    baseline["eligible"] = True
    baseline["failures"] = []
    for candidate in aggregates[1:]:
        candidate.update(evaluate_gates(baseline, candidate))

    winner = select_winner(aggregates[1:])
    if winner is None:
        conclusion = (
            "HEVC 基础候选未同时满足延迟、清晰度和稳定性门槛；"
            "保持默认优先 H.264，不进入 feature stage。"
        )
    else:
        conclusion = (
            f"HEVC {winner['case_id']} 通过基础门槛；仅以该候选进入 feature stage，"
            "暂不改变默认优先 H.264 的产品策略。"
        )
    return {
        "stage": "base",
        "baseline_id": "A0",
        "winner_id": winner["case_id"] if winner else None,
        "run_features": winner is not None,
        "conclusion": conclusion,
        "cases": aggregates,
    }


def load_base_analyses(experiment_root: pathlib.Path) -> dict[str, list[dict]]:
    analyses = {}
    for case in base_cases():
        paths = sorted((experiment_root / "cases" / case.case_id).glob("run-*/analysis.json"))
        analyses[case.case_id] = [
            json.loads(path.read_text(encoding="utf-8")) for path in paths
        ]
    return analyses


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def workload_marker_commits(records: list[dict]) -> dict[int, int]:
    commits = {}
    for record in records:
        marker_ns = record.get("marker_monotonic_ns")
        if not isinstance(marker_ns, int):
            continue
        if record.get("event") == "scroll_burst":
            commits[record["sequence"] + 1] = marker_ns
        elif record.get("event") == "final_marker":
            commits[record["sequence"]] = marker_ns
    return commits


def content_state_cycles(
    case: PolicyCase,
    workload_records: list[dict],
    sender_records: list[dict],
) -> list[dict]:
    if case.static_max_qp is None or case.active_max_qp is None:
        return []
    bursts = sorted(
        (
            record for record in workload_records
            if record.get("event") == "scroll_burst"
            and isinstance(record.get("sequence"), int)
            and isinstance(record.get("planned_monotonic_ns"), int)
            and isinstance(record.get("marker_monotonic_ns"), int)
        ),
        key=lambda record: record["sequence"],
    )
    final_marker_ns = next(
        (
            record["marker_monotonic_ns"] for record in workload_records
            if record.get("event") == "final_marker"
            and isinstance(record.get("marker_monotonic_ns"), int)
        ),
        None,
    )
    observations = []
    for record in sender_records:
        if record.get("event") != "rtc_stats" or not isinstance(record.get("monotonic_ns"), int):
            continue
        boundary = record.get("fields", {}).get("sender_media_boundary", {})
        generation = boundary.get("max_qp_generation")
        session = boundary.get("encoder_session_id")
        histogram = boundary.get("key_frame_qp_histogram")
        if not (
            boundary.get("max_qp_apply_state") == "applied"
            and isinstance(generation, int)
            and isinstance(session, str)
            and boundary.get("encoder_session_id")
                == boundary.get("max_qp_applied_encoder_session_id")
            and boundary.get("last_qp_sample_generation") == generation
            and boundary.get("last_qp_sample_encoder_session_id") == session
            and isinstance(histogram, list)
            and any(isinstance(count, int) and count > 0 for count in histogram)
        ):
            continue
        observations.append({
            "monotonic_ns": record["monotonic_ns"],
            "mode": boundary.get("clarity_mode"),
            "max_qp": boundary.get("effective_max_qp"),
            "generation": generation,
            "encoder_session_id": session,
            "last_key_frame_qp": boundary.get("last_key_frame_qp"),
        })

    cycles = []
    for index, burst in enumerate(bursts):
        window_end = (
            bursts[index + 1]["planned_monotonic_ns"]
            if index + 1 < len(bursts) else final_marker_ns
        )
        active_deadline = burst["marker_monotonic_ns"] + 1_500_000_000
        active = next(
            (
                item for item in observations
                if burst["planned_monotonic_ns"] <= item["monotonic_ns"] <= active_deadline
                and item["mode"] == "active"
                and item["max_qp"] == case.active_max_qp
            ),
            None,
        )
        static = None
        if active is not None and isinstance(window_end, int):
            static = next(
                (
                    item for item in observations
                    if active["monotonic_ns"] < item["monotonic_ns"] < window_end
                    and item["mode"] == "static_clarity"
                    and item["max_qp"] == case.static_max_qp
                    and item["generation"] > active["generation"]
                ),
                None,
            )
        cycles.append({
            "sequence": burst["sequence"],
            "valid": active is not None and static is not None,
            "active": active,
            "static": static,
        })
    return cycles


def encoder_telemetry(records: list[dict]) -> dict:
    latest = {}
    for record in records:
        if record.get("event") != "rtc_stats":
            continue
        boundary = record.get("fields", {}).get("sender_media_boundary", {})
        session = boundary.get("encoder_session_id")
        generation = boundary.get("max_qp_generation")
        submitted = boundary.get("video_toolbox_submitted_frames")
        if not isinstance(session, str) or not isinstance(generation, int) \
                or not isinstance(submitted, int):
            continue
        key = session, generation
        if submitted >= latest.get(key, {}).get("video_toolbox_submitted_frames", -1):
            latest[key] = boundary

    key_histogram = [0] * 52
    delta_histogram = [0] * 52
    submitted = encoded = dropped = 0
    for boundary in latest.values():
        submitted += boundary["video_toolbox_submitted_frames"]
        encoded += boundary["video_toolbox_encoded_frames"]
        dropped += boundary["video_toolbox_dropped_frames"]
        for target, field in (
            (key_histogram, "key_frame_qp_histogram"),
            (delta_histogram, "delta_frame_qp_histogram"),
        ):
            histogram = boundary[field]
            if len(histogram) != 52:
                raise RuntimeError(f"{field} must contain 52 QP buckets")
            for index, count in enumerate(histogram):
                target[index] += count
    return {
        "generation_count": len(latest),
        "submitted_frames": submitted,
        "encoded_frames": encoded,
        "dropped_frames": dropped,
        "drop_ratio": dropped / submitted if submitted else None,
        "key_qp_histogram": key_histogram,
        "delta_qp_histogram": delta_histogram,
    }


def analyze_run_records(
    case: PolicyCase,
    workload_records: list[dict],
    sender_records: list[dict],
    receiver_records: list[dict],
    *,
    static_image_metrics: list[dict],
    manual_text_clear: bool,
) -> dict:
    if not any(record.get("event") == "workload_completed"
               and record.get("valid") is True for record in workload_records):
        raise RuntimeError("workload did not complete with valid evidence")
    sender_offset = clock_offset(sender_records, "clock_calibrated")
    receiver_offset = clock_offset(receiver_records, "clock_calibration")
    commits = workload_marker_commits(workload_records)
    captures = sequence_field_values(
        sender_records, "baseline_capture_detected", "callback_monotonic_ns")
    renders = sequence_field_values(
        receiver_records, "baseline_android_render_detected", "local_monotonic_ns")
    active_sequences = sorted(sequence for sequence in commits if 2 <= sequence <= 7)
    active_samples = []
    for sequence in active_sequences:
        if sequence not in captures or sequence not in renders:
            continue
        commit_common = commits[sequence] + sender_offset
        capture_common = captures[sequence] + sender_offset
        render_common = renders[sequence] + receiver_offset
        if commit_common <= capture_common <= render_common:
            active_samples.append((render_common - commit_common) / 1_000_000)

    join_started = event_monotonic_ns(sender_records, "sender_join_started")
    if join_started is None or 1 not in renders:
        raise RuntimeError("first-frame timing evidence is incomplete")
    first_frame_ms = (
        renders[1] + receiver_offset - (join_started + sender_offset)
    ) / 1_000_000
    if first_frame_ms < 0:
        raise RuntimeError("first-frame timing is non-monotonic")

    codec_values = [
        record.get("fields", {}).get("outbound_video", {}).get("codec")
        for record in sender_records if record.get("event") == "rtc_stats"
    ]
    codec = next((value for value in reversed(codec_values)
                  if isinstance(value, str) and value), None)
    expected_codec = "video/H264" if case.codec_policy == "h264-only" else "video/H265"
    if codec != expected_codec:
        raise RuntimeError(f"expected {expected_codec}, observed {codec}")

    telemetry = encoder_telemetry(sender_records)
    if telemetry["drop_ratio"] is None:
        raise RuntimeError("VideoToolbox drop telemetry is missing")
    bitrates = [
        record.get("fields", {}).get("outbound_video", {}).get("bitrate_bps")
        for record in sender_records if record.get("event") == "rtc_stats"
    ]
    bitrates = [value for value in bitrates
                if isinstance(value, (int, float)) and not isinstance(value, bool)]
    if not bitrates:
        raise RuntimeError("sender bitrate evidence is missing")

    boundaries = [record.get("fields", {}).get("sender_media_boundary", {})
                  for record in sender_records if record.get("event") == "rtc_stats"]
    active_restores = max(
        (value.get("clarity_active_restores", 0) for value in boundaries), default=0)
    static_refreshes = max(
        (value.get("clarity_successful_refreshes", 0) for value in boundaries), default=0)
    render_gaps = [
        record.get("fields", {}).get("max_frame_gap_ms")
        for record in receiver_records
        if record.get("event") == "baseline_android_active_gap_summary"
    ]
    render_gaps = [value for value in render_gaps if isinstance(value, (int, float))]
    if not render_gaps:
        raise RuntimeError("Android active render-gap evidence is missing")
    if len(static_image_metrics) != 2:
        raise RuntimeError("initial and final static image metrics are required")

    marker_valid = len(set(active_sequences) & captures.keys() & renders.keys())
    cycles = content_state_cycles(case, workload_records, sender_records)
    counter_cycles = min(active_restores, max(0, static_refreshes - 1))
    bound_cycle_count = sum(cycle["valid"] for cycle in cycles)
    return {
        "case_id": case.case_id,
        "codec": codec,
        "static_max_qp": case.static_max_qp,
        "active_max_qp": case.active_max_qp,
        "first_frame_ms": first_frame_ms,
        "active_e2e_samples_ms": active_samples,
        "active_e2e_p95_ms": percentile(active_samples, 0.95),
        "max_render_gap_ms": max(render_gaps),
        "vt_drop_ratio": telemetry["drop_ratio"],
        "encoder_telemetry": telemetry,
        "marker_valid": marker_valid,
        "marker_total": len(active_sequences),
        "marker_sequence_delivery_ratio": marker_valid / len(active_sequences),
        "max_bitrate_bps": max(bitrates),
        "state_cycles": bound_cycle_count,
        "state_transition_roundtrips": counter_cycles,
        "content_state_cycles": cycles,
        "static_image_metrics": static_image_metrics,
        "static_ssim_y_worst": min(item["ssim_y"] for item in static_image_metrics),
        "static_psnr_y_worst": min(item["psnr_y"] for item in static_image_metrics),
        "manual_text_clear": manual_text_clear,
    }


def clock_offset(records: list[dict], event: str) -> int:
    for record in records:
        if record.get("event") == event:
            value = record.get("fields", {}).get("offset_ns")
            if isinstance(value, int) and not isinstance(value, bool):
                return value
    raise RuntimeError(f"missing {event} clock offset")


def sequence_field_values(records: list[dict], event: str, field: str) -> dict[int, int]:
    result = {}
    for record in records:
        fields = record.get("fields", {})
        sequence = fields.get("sequence")
        value = fields.get(field)
        if record.get("event") == event and isinstance(sequence, int) \
                and isinstance(value, int):
            result.setdefault(sequence, value)
    return result


def event_monotonic_ns(records: list[dict], event: str) -> int | None:
    for record in records:
        value = record.get("monotonic_ns")
        if record.get("event") == event and isinstance(value, int):
            return value
    return None


def parse_image_metrics(output: str) -> dict:
    psnr = re.search(r"PSNR y:([0-9.]+)", output)
    ssim = re.search(r"SSIM Y:([0-9.]+)", output)
    if not psnr or not ssim:
        raise RuntimeError("FFmpeg did not produce PSNR-Y and SSIM-Y")
    return {"psnr_y": float(psnr.group(1)), "ssim_y": float(ssim.group(1))}


def static_image_metrics(distorted: pathlib.Path, reference: pathlib.Path) -> dict:
    crop = "crop=1226:1046:570:34,format=yuv420p"
    outputs = []
    for metric in ("psnr", "ssim"):
        graph = f"[0:v]{crop}[a];[1:v]{crop}[b];[a][b]{metric}"
        result = subprocess.run(
            [
                "ffmpeg", "-hide_banner", "-nostats",
                "-i", str(distorted), "-i", str(reference),
                "-lavfi", graph, "-f", "null", "-",
            ],
            check=True,
            text=True,
            capture_output=True,
        )
        outputs.append(result.stderr)
    return parse_image_metrics("\n".join(outputs))


def load_jsonl(path: pathlib.Path) -> list[dict]:
    with path.open(encoding="utf-8") as source:
        return [json.loads(line) for line in source if line.strip()]


def resolve_valid_attempt(run_root: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path, pathlib.Path]:
    candidates = []
    for attempt in sorted(run_root.glob("attempt-*")):
        workload_path = attempt / "workload" / "workload.jsonl"
        sender_paths = list(attempt.glob("e2e/run.*/macos/*-sender/metrics.jsonl"))
        receiver_paths = list(attempt.glob("e2e/run.*/android/receiver.jsonl"))
        if not workload_path.is_file() or len(sender_paths) != 1 or len(receiver_paths) != 1:
            continue
        workload = load_jsonl(workload_path)
        if any(record.get("event") == "workload_completed" and record.get("valid") is True
               for record in workload):
            candidates.append((attempt, sender_paths[0], receiver_paths[0]))
    if len(candidates) != 1:
        raise RuntimeError(f"expected one valid attempt in {run_root}, found {len(candidates)}")
    return candidates[0]


def validate_case_qp_evidence(case: PolicyCase, sender_records: list[dict]) -> None:
    boundaries = [
        record.get("fields", {}).get("sender_media_boundary", {})
        for record in sender_records if record.get("event") == "rtc_stats"
    ]
    if case.low_latency_rate_control:
        if any(value.get("requested_max_qp") is not None for value in boundaries):
            raise RuntimeError("RTVC run unexpectedly requested MaxQP")
        return
    for expected in (case.static_max_qp, case.active_max_qp):
        if not any(
            value.get("requested_max_qp") == expected
            and value.get("effective_max_qp") == expected
            and value.get("max_qp_apply_state") == "applied"
            and value.get("encoder_session_id") == value.get("max_qp_applied_encoder_session_id")
            for value in boundaries
        ):
            raise RuntimeError(f"missing applied MaxQP evidence for {expected}")


def analyze_run_directory(
    run_root: pathlib.Path,
    *,
    manual_text_clear: bool,
) -> dict:
    policy = json.loads((run_root / "policy.json").read_text(encoding="utf-8"))
    case = PolicyCase(
        policy["case_id"],
        policy["codec_policy"],
        policy.get("static_max_qp"),
        policy.get("active_max_qp"),
        1,
        low_latency_rate_control=policy.get("static_max_qp") is None,
    )
    attempt, sender_path, receiver_path = resolve_valid_attempt(run_root)
    sender_records = load_jsonl(sender_path)
    receiver_records = load_jsonl(receiver_path)
    workload_records = load_jsonl(attempt / "workload" / "workload.jsonl")
    validate_case_qp_evidence(case, sender_records)
    sender_directory = sender_path.parent
    receiver_directory = receiver_path.parent
    image_metrics = []
    for sequence in (1, 8):
        reference = sender_directory / f"sender-capture-{sequence:06d}.png"
        distorted = receiver_directory / f"android-decoded-seq-{sequence:06d}.png"
        if not reference.is_file() or not distorted.is_file():
            raise RuntimeError(f"missing static screenshot pair for sequence {sequence}")
        image_metrics.append({
            "sequence": sequence,
            **static_image_metrics(distorted, reference),
        })
    result = analyze_run_records(
        case,
        workload_records,
        sender_records,
        receiver_records,
        static_image_metrics=image_metrics,
        manual_text_clear=manual_text_clear,
    )
    result["attempt"] = attempt.name
    result["evidence"] = {
        "workload": str((attempt / "workload").relative_to(run_root)),
        "sender": str(sender_directory.relative_to(run_root)),
        "android": str(receiver_directory.relative_to(run_root)),
    }
    return result


def render_markdown(report: dict) -> str:
    lines = [
        "# HEVC 会议投屏实验报告",
        "",
        f"结论：{report.get('conclusion', '尚未形成上线结论')}",
        "",
        "| Case | 结论 | STATIC/ACTIVE MaxQP | 实际 key/delta QP p95 | 首帧 ms | ACTIVE p95 ms | VT drop | 最差 SSIM-Y | 未过门槛 |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---|",
    ]
    for result in report.get("cases", []):
        qp = f"{result.get('static_max_qp')}/{result.get('active_max_qp')}"
        observed_qp = f"{result.get('key_qp_p95', '—')}/{result.get('delta_qp_p95', '—')}"
        failures = ", ".join(result.get("failures", [])) or "—"
        if result["case_id"] == report.get("baseline_id"):
            status = "基线"
        else:
            status = "通过" if result.get("eligible") else "不通过"
        lines.append(
            f"| {result['case_id']} | {status} | {qp} | {observed_qp} | "
            f"{result['first_frame_ms']:.1f} | {result['active_e2e_p95_ms']:.1f} | "
            f"{result['vt_drop_ratio']:.4f} | {result['static_ssim_y_worst']:.4f} | {failures} |"
        )
    lines.extend(["", "人工截图检查是正式结论的必要证据，自动图像指标不能替代。", ""])
    return "\n".join(lines)


def case_by_id(case_id: str, winner_id: str | None = None) -> PolicyCase:
    cases = list(base_cases())
    if winner_id:
        winner = next(case for case in cases if case.case_id == winner_id)
        cases.extend(feature_cases(winner))
    return next(case for case in cases if case.case_id == case_id)


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    config_parser = subparsers.add_parser("configs")
    config_parser.add_argument("--case-id", required=True)
    config_parser.add_argument("--winner-id")
    config_parser.add_argument("--runtime", type=pathlib.Path, required=True)
    config_parser.add_argument("--tuning", type=pathlib.Path, required=True)
    config_parser.add_argument("--runtime-output", type=pathlib.Path, required=True)
    config_parser.add_argument("--tuning-output", type=pathlib.Path, required=True)
    analyze_parser = subparsers.add_parser("analyze-run")
    analyze_parser.add_argument("--run-root", type=pathlib.Path, required=True)
    analyze_parser.add_argument("--output", type=pathlib.Path)
    analyze_parser.add_argument("--manual-text-clear", action="store_true")
    report_parser = subparsers.add_parser("report-base")
    report_parser.add_argument("--experiment-root", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.command == "configs":
        case = case_by_id(args.case_id, args.winner_id)
        runtime, tuning = generate_configs(
            json.loads(args.runtime.read_text(encoding="utf-8")),
            json.loads(args.tuning.read_text(encoding="utf-8")),
            case,
        )
        args.runtime_output.write_text(json.dumps(runtime, indent=2) + "\n", encoding="utf-8")
        args.tuning_output.write_text(json.dumps(tuning, indent=2) + "\n", encoding="utf-8")
    elif args.command == "analyze-run":
        result = analyze_run_directory(
            args.run_root,
            manual_text_clear=args.manual_text_clear,
        )
        output = args.output or args.run_root / "analysis.json"
        output.write_text(
            json.dumps(result, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    elif args.command == "report-base":
        report = build_base_report(load_base_analyses(args.experiment_root))
        (args.experiment_root / "report.json").write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        (args.experiment_root / "report.md").write_text(
            render_markdown(report),
            encoding="utf-8",
        )
        print(args.experiment_root / "report.md")


if __name__ == "__main__":
    main()
