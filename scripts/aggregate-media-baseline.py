#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import pathlib
import statistics


LATENCY_KEYS = ["commit_to_capture_ms", "capture_to_decode_ms", "software_end_to_end_ms"]
QUALITY_COMPARISONS = ["source_to_capture", "capture_to_decode", "source_to_decode"]
QUALITY_KEYS = ["psnr_y", "psnr_cb", "psnr_cr", "ssim_y", "vmaf_reference"]


def percentile(values, fraction):
    values = sorted(values)
    if not values:
        return None
    position = (len(values) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return values[lower]
    return values[lower] + (values[upper] - values[lower]) * (position - lower)


def distribution(values):
    numeric = [value for value in values if isinstance(value, (int, float))]
    return {
        "count": len(numeric),
        "p50": percentile(numeric, 0.5),
        "p95": percentile(numeric, 0.95),
        "max": max(numeric) if numeric else None,
    }


def score_summary(values):
    numeric = [value for value in values if isinstance(value, (int, float))]
    return {
        "count": len(numeric),
        "median": statistics.median(numeric) if numeric else None,
        "worst": min(numeric) if numeric else None,
    }


def build_aggregate(reports, host_context, artifact_checksums):
    profiles = {}
    for profile in sorted({report["profile"] for report in reports}):
        runs = [report for report in reports if report["profile"] == profile]
        profile_result = {"run_count": len(runs)}
        for key in LATENCY_KEYS:
            profile_result[key] = distribution([
                sample[key] for run in runs for sample in run["latency_samples"]
            ])
        profile_result["connection_timing"] = {
            key: distribution([run["connection_timing"].get(key) for run in runs])
            for key in sorted({key for run in runs for key in run["connection_timing"]})
        }
        profile_result["marker_counters"] = {
            key: sum(run.get("marker_counters", {}).get(key, 0) for run in runs)
            for key in sorted({key for run in runs for key in run.get("marker_counters", {})})
        }
        profile_result["quality"] = {}
        for comparison in QUALITY_COMPARISONS:
            comparison_result = {}
            for key in QUALITY_KEYS:
                values = [
                    sample.get("comparisons", {}).get(comparison, {}).get(key)
                    for run in runs for sample in run.get("quality_samples", [])
                ]
                comparison_result[key] = score_summary(values)
            profile_result["quality"][comparison] = comparison_result
        profiles[profile] = profile_result

    paired = []
    rounds = sorted({report["round"] for report in reports})
    for round_number in rounds:
        direct = next((r for r in reports if r["round"] == round_number and r["profile"] == "direct-baseline"), None)
        turn = next((r for r in reports if r["round"] == round_number and r["profile"] == "production-relay"), None)
        if not direct or not turn:
            continue
        direct_p50 = distribution([s["software_end_to_end_ms"] for s in direct["latency_samples"]])["p50"]
        turn_p50 = distribution([s["software_end_to_end_ms"] for s in turn["latency_samples"]])["p50"]
        paired.append({
            "round": round_number,
            "software_end_to_end_p50_ms": turn_p50 - direct_p50,
            "webrtc_negotiation_ms": (
                turn["connection_timing"]["webrtc_negotiation_ms"]
                - direct["connection_timing"]["webrtc_negotiation_ms"]
            ),
        })
    return {
        "schema_version": 1,
        "host_context": host_context,
        "artifact_checksums": artifact_checksums,
        "profiles": profiles,
        "paired_round_deltas": paired,
        "runs": reports,
    }


def render_markdown(result):
    lines = [
        "# Automated Media Baseline",
        "",
        f"Commit: `{result['host_context'].get('git_commit', 'unknown')}`",
        "",
        "| Profile | Runs | Valid | Software E2E p50 / p95 / max (ms) | Capture→Decode p50 (ms) | Negotiation p50 (ms) | Source→Decode PSNR-Y / SSIM-Y / VMAF median |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for profile, values in result["profiles"].items():
        software = values["software_end_to_end_ms"]
        media = values["capture_to_decode_ms"]
        negotiation = values["connection_timing"]["webrtc_negotiation_ms"]
        quality = values["quality"]["source_to_decode"]
        counters = values["marker_counters"]
        lines.append(
            f"| {profile} | {values['run_count']} | {software['count']}/{counters.get('committed', 0)} | "
            f"{software['p50']:.2f} / {software['p95']:.2f} / {software['max']:.2f} | "
            f"{media['p50']:.2f} | {negotiation['p50']:.2f} | "
            f"{quality['psnr_y']['median']:.2f} / {quality['ssim_y']['median']:.4f} / {quality['vmaf_reference']['median']:.2f} |"
        )
    lines.extend(["", "TURN minus Direct paired-round deltas:", "", "| Round | Software E2E p50 (ms) | Negotiation (ms) |", "|---:|---:|---:|"])
    for pair in result["paired_round_deltas"]:
        lines.append(f"| {pair['round']} | {pair['software_end_to_end_p50_ms']:.2f} | {pair['webrtc_negotiation_ms']:.2f} |")
    lines.extend(["", "VMAF is a reference metric only; this baseline defines no performance or quality gate.", ""])
    return "\n".join(lines)


def checksum(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def evidence_checksums(artifact_root, host_context, reports):
    paths = {host_context, *reports}
    for report in reports:
        run_root = report.parent
        paths.update(run_root.glob("diagnostics/*/metrics.jsonl"))
        paths.update(run_root.glob("diagnostics/*/*.png"))
        paths.update(run_root.glob("*-heatmap.png"))
        paths.update(run_root.glob("*-vmaf.json"))
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
    args.output_json.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    args.output_markdown.write_text(render_markdown(result), encoding="utf-8")


if __name__ == "__main__":
    main()
