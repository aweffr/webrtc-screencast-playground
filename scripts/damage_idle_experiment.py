#!/usr/bin/env python3
import argparse
import importlib.util
import json
import pathlib
import statistics
from typing import NamedTuple


class ExperimentCase(NamedTuple):
    case_id: str
    codec_policy: str
    static_qp: int
    active_qp: int


def cases() -> dict[str, ExperimentCase]:
    return {
        "D0": ExperimentCase("D0", "h264-only", 24, 32),
        "D1": ExperimentCase("D1", "h264-only", 24, 32),
        "H1": ExperimentCase("H1", "h265-only", 33, 39),
    }


def formal_order() -> tuple[str, ...]:
    return ("D0", "D1", "D1", "D0", "D0", "D1")


def activity_markers(records: list[dict]) -> list[int]:
    return sorted(
        record["marker_monotonic_ns"]
        for record in records
        if record.get("event") == "activity_episode"
        and isinstance(record.get("marker_monotonic_ns"), int)
    )


def capture_samples(records: list[dict]) -> list[dict]:
    return [
        record.get("fields", {}).get("capture", {})
        for record in records
        if record.get("event") == "rtc_stats"
    ]


def unique_transition_values(samples: list[dict], field: str) -> list[int]:
    return sorted({
        sample[field]
        for sample in samples
        if isinstance(sample.get(field), int)
    })


def evaluate_detector_evidence(
    workload_records: list[dict],
    sender_records: list[dict],
) -> dict:
    markers = activity_markers(workload_records)
    samples = capture_samples(sender_records)
    active_transitions = unique_transition_values(
        samples, "last_active_transition_monotonic_ns")
    static_transitions = unique_transition_values(
        samples, "last_static_transition_monotonic_ns")

    observation_end = max(
        (record.get("monotonic_ns", 0) for record in sender_records),
        default=0,
    )
    active_latencies = []
    episode_active_transitions = []
    episode_static_transitions = []
    for index, marker in enumerate(markers):
        interval_end = markers[index + 1] if index + 1 < len(markers) else observation_end + 1
        active = next((
            value for value in active_transitions
            if marker <= value < interval_end
        ), None)
        if active is None:
            continue
        episode_active_transitions.append(active)
        active_latencies.append((active - marker) / 1_000_000)
        static = next((
            value for value in static_transitions
            if active <= value < interval_end
        ), None)
        if static is not None:
            episode_static_transitions.append(static)

    static_pairs = {}
    ambiguous_static_pairs = set()
    for sample in samples:
        transition = sample.get("last_static_transition_monotonic_ns")
        damage = sample.get("last_damage_monotonic_ns")
        if isinstance(transition, int) and isinstance(damage, int):
            if transition >= damage:
                static_pairs.setdefault(transition, damage)
            else:
                ambiguous_static_pairs.add(transition)
    static_quiet_latencies = [
        (transition - static_pairs[transition]) / 1_000_000
        for transition in sorted(static_pairs)
    ]

    active_count = max(
        (sample.get("active_transition_count", 0) for sample in samples),
        default=0,
    )
    static_count = max(
        (sample.get("static_transition_count", 0) for sample in samples),
        default=0,
    )
    synthetic_count = max(
        (sample.get("synthetic_clarity_refreshes", 0) for sample in samples),
        default=0,
    )
    boundaries = [
        record.get("fields", {}).get("sender_media_boundary", {})
        for record in sender_records
        if record.get("event") == "rtc_stats"
    ]
    restores = max(
        (boundary.get("clarity_active_restores", 0) for boundary in boundaries),
        default=0,
    )
    successful = max(
        (boundary.get("clarity_successful_refreshes", 0) for boundary in boundaries),
        default=0,
    )
    failed = max(
        (boundary.get("clarity_failed_refreshes", 0) for boundary in boundaries),
        default=0,
    )

    failures = []
    if len(markers) != 6:
        failures.append("workload_episode_count")
    if len(episode_active_transitions) != len(markers):
        failures.append("active_episode_coverage")
    elif any(value < 0 or value > 200 for value in active_latencies):
        failures.append("active_episode_latency")
    initial_static = bool(markers) and any(value < markers[0] for value in static_transitions)
    if not initial_static or len(episode_static_transitions) != len(markers):
        failures.append("static_episode_coverage")
    if not static_quiet_latencies or any(
        value < 600 or value > 900 for value in static_quiet_latencies
    ):
        failures.append("static_quiet_latency")
    maximum_active_transitions = len(markers) * 3
    if not (
        len(markers) <= active_count <= maximum_active_transitions
        and len(markers) + 1 <= static_count <= maximum_active_transitions + 1
        and static_count in (active_count, active_count + 1)
    ):
        failures.append("transition_bound")
    if synthetic_count != static_count:
        failures.append("synthetic_clarity_refresh_count")
    if restores != active_count:
        failures.append("active_restore_count")
    if successful != static_count or failed != 0:
        failures.append("clarity_refresh_result")
    return {
        "eligible": not failures,
        "failures": failures,
        "active_latencies_ms": active_latencies,
        "static_quiet_latencies_ms": static_quiet_latencies,
        "ambiguous_static_pair_count": len(ambiguous_static_pairs - set(static_pairs)),
        "episode_active_transition_count": len(episode_active_transitions),
        "episode_static_transition_count": len(episode_static_transitions),
        "active_transition_count": active_count,
        "static_transition_count": static_count,
        "synthetic_clarity_refreshes": synthetic_count,
        "active_restores": restores,
        "successful_refreshes": successful,
        "failed_refreshes": failed,
    }


def aggregate_runs(runs: list[dict]) -> dict:
    if len(runs) != 3:
        raise ValueError("formal H.264 cases require exactly three runs")
    return {
        "first_frame_ms": statistics.median(run["first_frame_ms"] for run in runs),
        "active_e2e_p95_ms": statistics.median(run["active_e2e_p95_ms"] for run in runs),
        "max_render_gap_ms": max(run["max_render_gap_ms"] for run in runs),
        "vt_drop_ratio": max(run["vt_drop_ratio"] for run in runs),
        "bitrate_bps": max(run["bitrate_bps"] for run in runs),
        "marker_valid": sum(run["marker_valid"] for run in runs),
        "marker_total": sum(run["marker_total"] for run in runs),
        "static_ssim_y": min(run["static_ssim_y"] for run in runs),
        "static_psnr_y": min(run["static_psnr_y"] for run in runs),
        "manual_images_clear": all(run["manual_images_clear"] for run in runs),
        "detector_eligible": all(run["detector_eligible"] for run in runs),
        "qp_binding_valid": all(run["qp_binding_valid"] for run in runs),
        "run_count": len(runs),
    }


def evaluate_head_to_head(baseline_runs: list[dict], candidate_runs: list[dict]) -> dict:
    baseline = aggregate_runs(baseline_runs)
    candidate = aggregate_runs(candidate_runs)
    failures = []
    checks = (
        (candidate["detector_eligible"], "detector_contract"),
        (candidate["qp_binding_valid"], "qp_binding"),
        (candidate["marker_valid"] == candidate["marker_total"] == 18, "marker_delivery"),
        (candidate["manual_images_clear"], "manual_image_clarity"),
        (candidate["first_frame_ms"] <= baseline["first_frame_ms"] + 100, "first_frame_regression"),
        (candidate["active_e2e_p95_ms"] <= baseline["active_e2e_p95_ms"] + 10, "active_latency_regression"),
        (candidate["max_render_gap_ms"] <= 500, "render_gap"),
        (candidate["vt_drop_ratio"] <= 0.01, "video_toolbox_drop"),
        (candidate["bitrate_bps"] <= baseline["bitrate_bps"] * 1.05, "bitrate_regression"),
        (baseline["static_ssim_y"] - candidate["static_ssim_y"] <= 0.002, "static_ssim_regression"),
        (baseline["static_psnr_y"] - candidate["static_psnr_y"] <= 0.5, "static_psnr_regression"),
    )
    failures.extend(name for passed, name in checks if not passed)
    return {
        "eligible": not failures,
        "failures": failures,
        "baseline": baseline,
        "candidate": candidate,
    }


def authorizes_h265_smoke(head_to_head_report: dict) -> bool:
    return head_to_head_report.get("eligible") is True


def load_jsonl(path: pathlib.Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def hevc_analysis_module():
    path = pathlib.Path(__file__).with_name("hevc_meeting_experiment.py")
    spec = importlib.util.spec_from_file_location("damage_idle_hevc_analysis", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def qp_binding_is_valid(sender_records: list[dict], expected_qps: tuple[int, int]) -> bool:
    boundaries = [
        record.get("fields", {}).get("sender_media_boundary", {})
        for record in sender_records
        if record.get("event") == "rtc_stats"
    ]
    return all(any(
        boundary.get("requested_max_qp") == expected
        and boundary.get("effective_max_qp") == expected
        and boundary.get("max_qp_apply_state") == "applied"
        and isinstance(boundary.get("encoder_session_id"), str)
        and boundary.get("encoder_session_id")
            == boundary.get("max_qp_applied_encoder_session_id")
        for boundary in boundaries
    ) for expected in expected_qps)


def analyze_run_directory(
    run_root: pathlib.Path,
    case_id: str,
    *,
    manual_images_clear: bool,
) -> dict:
    case = cases()[case_id]
    evidence_root = run_root / "valid-attempt"
    workload_records = load_jsonl(evidence_root / "workload" / "workload.jsonl")
    e2e_root = next((evidence_root / "e2e").glob("run.*"))
    sender_path = next((e2e_root / "macos").glob("*-sender/metrics.jsonl"))
    receiver_path = e2e_root / "android" / "receiver.jsonl"
    sender_records = load_jsonl(sender_path)
    receiver_records = load_jsonl(receiver_path)
    hevc = hevc_analysis_module()

    sender_offset = hevc.clock_offset(sender_records, "clock_calibrated")
    receiver_offset = hevc.clock_offset(receiver_records, "clock_calibration")
    markers = {
        record["sequence"]: record["marker_monotonic_ns"]
        for record in workload_records
        if record.get("event") == "activity_episode"
    }
    captures = hevc.sequence_field_values(
        sender_records, "baseline_capture_detected", "callback_monotonic_ns")
    renders = hevc.sequence_field_values(
        receiver_records, "baseline_android_render_detected", "local_monotonic_ns")
    latency_samples = []
    for sequence, marker in markers.items():
        if sequence not in captures or sequence not in renders:
            continue
        commit_common = marker + sender_offset
        capture_common = captures[sequence] + sender_offset
        render_common = renders[sequence] + receiver_offset
        if commit_common <= capture_common <= render_common:
            latency_samples.append((render_common - commit_common) / 1_000_000)

    join_started = hevc.event_monotonic_ns(sender_records, "sender_join_started")
    if join_started is None or 1 not in renders:
        raise RuntimeError("first-frame timing evidence is incomplete")
    first_frame_ms = (
        renders[1] + receiver_offset - (join_started + sender_offset)
    ) / 1_000_000
    telemetry = hevc.encoder_telemetry(sender_records)
    bitrates = [
        record.get("fields", {}).get("outbound_video", {}).get("bitrate_bps")
        for record in sender_records
        if record.get("event") == "rtc_stats"
    ]
    bitrates = [value for value in bitrates if isinstance(value, (int, float))]
    render_gaps = [
        record.get("fields", {}).get("max_frame_gap_ms")
        for record in receiver_records
        if record.get("event") == "baseline_android_active_gap_summary"
    ]
    render_gaps = [value for value in render_gaps if isinstance(value, (int, float))]
    if not latency_samples or telemetry["drop_ratio"] is None or not bitrates or not render_gaps:
        raise RuntimeError("operational experiment evidence is incomplete")

    image_pairs = (
        (
            e2e_root / "macos-main-source.png",
            e2e_root / "android" / "receiver-playing.png",
        ),
        (
            evidence_root / "workload" / "final.png",
            evidence_root / "android-final.png",
        ),
    )
    image_metrics = []
    for reference, distorted in image_pairs:
        if not reference.is_file() or not distorted.is_file():
            raise RuntimeError("initial/final screenshot pair is incomplete")
        image_metrics.append(hevc.static_image_metrics(distorted, reference))

    detector = evaluate_detector_evidence(workload_records, sender_records)
    marker_valid = len(set(markers) & captures.keys() & renders.keys())
    expected_codec = "video/H264" if case.codec_policy == "h264-only" else "video/H265"
    codecs = [
        record.get("fields", {}).get("outbound_video", {}).get("codec")
        for record in sender_records
        if record.get("event") == "rtc_stats"
    ]
    if expected_codec not in codecs:
        raise RuntimeError(f"expected {expected_codec} sender evidence")
    return {
        "case_id": case_id,
        "first_frame_ms": first_frame_ms,
        "active_e2e_p95_ms": hevc.percentile(latency_samples, 0.95),
        "max_render_gap_ms": max(render_gaps),
        "vt_drop_ratio": telemetry["drop_ratio"],
        "bitrate_bps": max(bitrates),
        "marker_valid": marker_valid,
        "marker_total": len(markers),
        "static_ssim_y": min(item["ssim_y"] for item in image_metrics),
        "static_psnr_y": min(item["psnr_y"] for item in image_metrics),
        "static_image_metrics": image_metrics,
        "manual_images_clear": manual_images_clear,
        "detector_eligible": detector["eligible"] if case_id == "D1" else False,
        "detector": detector if case_id == "D1" else None,
        "qp_binding_valid": qp_binding_is_valid(
            sender_records, (case.static_qp, case.active_qp)),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    analyze = subparsers.add_parser("analyze-run")
    analyze.add_argument("--run-root", type=pathlib.Path, required=True)
    analyze.add_argument("--case-id", choices=cases(), required=True)
    analyze.add_argument("--manual-images-clear", action="store_true")
    analyze.add_argument("--output", type=pathlib.Path, required=True)
    aggregate = subparsers.add_parser("aggregate")
    aggregate.add_argument("--baseline", type=pathlib.Path, required=True)
    aggregate.add_argument("--candidate", type=pathlib.Path, required=True)
    aggregate.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.command == "analyze-run":
        report = analyze_run_directory(
            args.run_root,
            args.case_id,
            manual_images_clear=args.manual_images_clear,
        )
        args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return 0
    baseline = json.loads(args.baseline.read_text(encoding="utf-8"))
    candidate = json.loads(args.candidate.read_text(encoding="utf-8"))
    report = evaluate_head_to_head(baseline, candidate)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0 if report["eligible"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
