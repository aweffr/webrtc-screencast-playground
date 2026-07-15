#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import pathlib
import statistics


LATENCY_KEYS = (
    "marker_commit_to_capture_ms",
    "capture_to_android_render_ms",
    "android_render_software_end_to_end_ms",
)
QUALITY_COMPARISONS = (
    "source_to_capture",
    "capture_to_android_render",
    "source_to_android_render",
)
QUALITY_KEYS = ("psnr_y", "psnr_cb", "psnr_cr", "ssim_y", "vmaf_reference")


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return None
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def distribution(values):
    numeric = [value for value in values if is_number(value)]
    return {
        "count": len(numeric),
        "p50": percentile(numeric, 0.5),
        "p95": percentile(numeric, 0.95),
        "max": max(numeric) if numeric else None,
    }


def score_summary(values):
    numeric = [value for value in values if is_number(value)]
    return {
        "count": len(numeric),
        "median": statistics.median(numeric) if numeric else None,
        "worst": min(numeric) if numeric else None,
    }


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def build_aggregate(reports, host_context, artifact_checksums):
    profiles = {}
    for profile in sorted({report["profile"] for report in reports}):
        runs = [report for report in reports if report["profile"] == profile]
        profile_result = {
            "run_count": len(runs),
            "valid_sequences": sum(
                run.get("measurement_window", {}).get("valid_sequences", 0)
                for run in runs
            ),
        }
        for key in LATENCY_KEYS:
            profile_result[key] = distribution([
                sample.get(key)
                for run in runs
                for sample in run.get("latency_samples", [])
            ])
        timing_keys = sorted({
            key for run in runs for key in run.get("connection_timing", {})
        })
        profile_result["connection_timing"] = {
            key: distribution([
                run.get("connection_timing", {}).get(key) for run in runs
            ])
            for key in timing_keys
        }
        profile_result["quality"] = {}
        for comparison in QUALITY_COMPARISONS:
            profile_result["quality"][comparison] = {
                key: score_summary([
                    sample.get("comparisons", {}).get(comparison, {}).get(key)
                    for run in runs
                    for sample in run.get("quality_samples", [])
                ])
                for key in QUALITY_KEYS
            }
        profiles[profile] = profile_result

    paired = []
    for round_number in sorted({report["round"] for report in reports}):
        direct = find_report(reports, round_number, "direct-baseline")
        relay = find_report(reports, round_number, "production-relay")
        if direct is None or relay is None:
            continue
        direct_latency = distribution([
            sample["android_render_software_end_to_end_ms"]
            for sample in direct["latency_samples"]
        ])["p50"]
        relay_latency = distribution([
            sample["android_render_software_end_to_end_ms"]
            for sample in relay["latency_samples"]
        ])["p50"]
        paired.append({
            "round": round_number,
            "android_render_software_end_to_end_p50_ms": relay_latency - direct_latency,
            "signaling_ready_total_ms": (
                relay["connection_timing"]["signaling_ready_total_ms"]
                - direct["connection_timing"]["signaling_ready_total_ms"]
            ),
            "webrtc_negotiation_to_media_ready_ms": (
                relay["connection_timing"]["webrtc_negotiation_to_media_ready_ms"]
                - direct["connection_timing"]["webrtc_negotiation_to_media_ready_ms"]
            ),
        })
    return {
        "schema_version": 1,
        "latency_semantics": "software markers; not optical glass-to-glass",
        "host_context": host_context,
        "artifact_checksums": artifact_checksums,
        "profiles": profiles,
        "paired_round_deltas": paired,
        "runs": reports,
    }


def find_report(reports, round_number, profile):
    return next((
        report for report in reports
        if report["round"] == round_number and report["profile"] == profile
    ), None)


def render_markdown(result):
    lines = [
        "# macOS Sender to Android TV Receiver Baseline",
        "",
        f"Commit: `{result['host_context'].get('git_commit', 'unknown')}`",
        "",
        "Latency uses calibrated software markers; it is not optical glass-to-glass latency.",
        "",
        "| Profile | Runs | Valid markers | Software E2E p50 / p95 / max (ms) | Capture→Android render p50 (ms) | Signaling ready p50 (ms) | Negotiation→media p50 (ms) | Source→Android PSNR-Y / SSIM-Y / VMAF median |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for profile, values in result["profiles"].items():
        software = values["android_render_software_end_to_end_ms"]
        media = values["capture_to_android_render_ms"]
        timing = values["connection_timing"]
        quality = values["quality"]["source_to_android_render"]
        lines.append(
            f"| {profile} | {values['run_count']} | {values['valid_sequences']} | "
            f"{metric(software['p50'])} / {metric(software['p95'])} / {metric(software['max'])} | "
            f"{metric(media['p50'])} | "
            f"{metric(timing.get('signaling_ready_total_ms', {}).get('p50'))} | "
            f"{metric(timing.get('webrtc_negotiation_to_media_ready_ms', {}).get('p50'))} | "
            f"{metric(quality['psnr_y']['median'])} / "
            f"{metric(quality['ssim_y']['median'], 4)} / "
            f"{metric(quality['vmaf_reference']['median'])} |"
        )
    lines.extend([
        "",
        "TURN minus Direct paired-round deltas:",
        "",
        "| Round | Software E2E p50 (ms) | Signaling ready (ms) | Negotiation→media (ms) |",
        "|---:|---:|---:|---:|",
    ])
    for pair in result["paired_round_deltas"]:
        lines.append(
            f"| {pair['round']} | "
            f"{metric(pair['android_render_software_end_to_end_p50_ms'])} | "
            f"{metric(pair['signaling_ready_total_ms'])} | "
            f"{metric(pair['webrtc_negotiation_to_media_ready_ms'])} |"
        )
    lines.extend([
        "",
        "VMAF is a reference metric only; this baseline defines no latency or quality gate.",
        "",
    ])
    return "\n".join(lines)


def metric(value, precision=2):
    return "n/a" if not is_number(value) else f"{value:.{precision}f}"


def checksum(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def evidence_checksums(artifact_root, host_context, reports):
    paths = {
        path for path in artifact_root.rglob("*")
        if path.is_file()
    }
    paths.update({host_context, *reports})
    return {
        str(path.relative_to(artifact_root)): checksum(path)
        for path in sorted(paths)
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host-context", required=True, type=pathlib.Path)
    parser.add_argument("--output-json", required=True, type=pathlib.Path)
    parser.add_argument("--output-markdown", required=True, type=pathlib.Path)
    parser.add_argument("reports", nargs="+", type=pathlib.Path)
    args = parser.parse_args()
    reports = [json.loads(path.read_text(encoding="utf-8")) for path in args.reports]
    host_context = json.loads(args.host_context.read_text(encoding="utf-8"))
    artifact_root = args.output_json.parent
    checksums = evidence_checksums(artifact_root, args.host_context, args.reports)
    result = build_aggregate(reports, host_context, checksums)
    args.output_json.parent.mkdir(parents=True, exist_ok=True)
    args.output_markdown.parent.mkdir(parents=True, exist_ok=True)
    args.output_json.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    args.output_markdown.write_text(render_markdown(result), encoding="utf-8")


if __name__ == "__main__":
    main()
