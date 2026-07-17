#!/usr/bin/env python3
import argparse
import copy
import functools
import json
import math
import pathlib
import statistics
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
        (candidate["marker_valid_ratio"] >= baseline["marker_valid_ratio"] - 0.01,
         "marker_validity"),
        (candidate["max_bitrate_bps"] <= 5_000_000, "bitrate_cap"),
        (candidate["state_cycles"] >= 6, "content_state_cycles"),
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
    return {
        "case_id": case.case_id,
        "static_max_qp": case.static_max_qp,
        "active_max_qp": case.active_max_qp,
        "first_frame_ms": statistics.median(run["first_frame_ms"] for run in runs),
        "active_e2e_p95_ms": percentile(latency_samples, 0.95) if latency_samples else max(
            run["active_e2e_p95_ms"] for run in runs),
        "max_render_gap_ms": max(run["max_render_gap_ms"] for run in runs),
        "vt_drop_ratio": max(run["vt_drop_ratio"] for run in runs),
        "marker_valid_ratio": marker_valid / marker_total if marker_total else min(
            run["marker_valid_ratio"] for run in runs),
        "max_bitrate_bps": max(run["max_bitrate_bps"] for run in runs),
        "state_cycles": min(run["state_cycles"] for run in runs),
        "static_ssim_y_worst": min(run["static_ssim_y_worst"] for run in runs),
        "static_psnr_y_worst": min(run["static_psnr_y_worst"] for run in runs),
        "manual_text_clear": all(run["manual_text_clear"] for run in runs),
        "run_count": len(runs),
    }


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def render_markdown(report: dict) -> str:
    lines = [
        "# HEVC 会议投屏实验报告",
        "",
        f"结论：{report.get('conclusion', '尚未形成上线结论')}",
        "",
        "| Case | 有效 | STATIC/ACTIVE MaxQP | 首帧 ms | ACTIVE p95 ms | VT drop | 最差 SSIM-Y |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for result in report.get("cases", []):
        qp = f"{result.get('static_max_qp')}/{result.get('active_max_qp')}"
        lines.append(
            f"| {result['case_id']} | {'是' if result.get('eligible') else '否'} | {qp} | "
            f"{result['first_frame_ms']:.1f} | {result['active_e2e_p95_ms']:.1f} | "
            f"{result['vt_drop_ratio']:.4f} | {result['static_ssim_y_worst']:.4f} |"
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


if __name__ == "__main__":
    main()
