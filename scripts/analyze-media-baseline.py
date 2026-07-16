#!/usr/bin/env python3
import argparse
import json
import math
import pathlib
import re
import subprocess


CHART_REGIONS = {
    "text_and_gradient": (320, 40, 1536, 160),
    "color_patches": (320, 224, 1536, 112),
    "fine_lines": (320, 400, 680, 300),
    "checkerboard_gradient": (320, 720, 1536, 296),
}
GLOBAL_CHART_CROP = (320, 0, 1536, 1080)
MARKER_ROI = (64, 64, 192, 192)


def load_jsonl(path):
    with pathlib.Path(path).open(encoding="utf-8") as stream:
        return [json.loads(line) for line in stream if line.strip()]


def correlate_latency(sender_records, receiver_records):
    commits = event_values(sender_records, "baseline_marker_committed", "committed_monotonic_ns")
    captures = event_values(sender_records, "baseline_capture_detected", "callback_monotonic_ns")
    decodes = event_values(receiver_records, "baseline_decode_detected", "callback_monotonic_ns")
    samples = []
    for sequence in sorted(commits.keys() & captures.keys() & decodes.keys()):
        commit = commits[sequence]
        capture = captures[sequence]
        decode = decodes[sequence]
        if commit <= capture <= decode:
            samples.append({
            "sequence": sequence,
            "committed_monotonic_ns": commit,
            "commit_to_capture_ms": (capture - commit) / 1_000_000,
                "capture_to_decode_ms": (decode - capture) / 1_000_000,
                "software_end_to_end_ms": (decode - commit) / 1_000_000,
            })
    return samples


def measurement_window(samples, selected_path_verified_ns, warmup_seconds=10, duration_seconds=60):
    start = selected_path_verified_ns + warmup_seconds * 1_000_000_000
    end = start + duration_seconds * 1_000_000_000
    return [
        sample for sample in samples
        if start <= sample["committed_monotonic_ns"] < end
    ]


def require_evidence(samples, quality_samples=None):
    if not samples:
        raise RuntimeError("no correlatable marker in the measurement window")
    if quality_samples is not None and (
        len(quality_samples) != 3 or any("error" in sample for sample in quality_samples)
    ):
        raise RuntimeError("expected three complete image triplets")


def marker_counters(sender_records, receiver_records, start_ns, end_ns):
    commits = event_values(sender_records, "baseline_marker_committed", "committed_monotonic_ns")
    captures = event_values(sender_records, "baseline_capture_detected", "callback_monotonic_ns")
    decodes = event_values(receiver_records, "baseline_decode_detected", "callback_monotonic_ns")
    target_sequences = {
        sequence for sequence, committed_ns in commits.items()
        if start_ns <= committed_ns < end_ns
    }
    capture_sequences = target_sequences & captures.keys()
    decode_sequences = target_sequences & decodes.keys()

    def invalid_count(records, stage):
        return sum(
            1 for record in records
            if record.get("event") == "baseline_marker_invalid"
            and record.get("fields", {}).get("stage") == stage
            and record.get("fields", {}).get("reason") == "checksum_mismatch"
            and isinstance(record.get("fields", {}).get("callback_monotonic_ns"), int)
            and start_ns <= record["fields"]["callback_monotonic_ns"] < end_ns
        )

    return {
        "committed": len(target_sequences),
        "capture_detected": len(capture_sequences),
        "capture_missing": len(target_sequences - capture_sequences),
        "decode_detected": len(decode_sequences),
        "decode_missing": len(target_sequences - decode_sequences),
        "capture_crc_invalid": invalid_count(sender_records, "capture"),
        "decode_crc_invalid": invalid_count(receiver_records, "decode"),
    }


def event_values(records, event, value_key):
    values = {}
    for record in records:
        if record.get("event") != event:
            continue
        fields = record.get("fields", {})
        sequence = fields.get("sequence")
        value = fields.get(value_key)
        if isinstance(sequence, int) and isinstance(value, int):
            values.setdefault(sequence, value)
    return values


def connection_timing(sender_records, receiver_records):
    receiver_connect_start = event_time(receiver_records, "signaling_connect_started")
    receiver_connected = event_time(receiver_records, "signaling_connected")
    register_started = event_time(receiver_records, "receiver_register_started")
    registered = event_time(receiver_records, "receiver_registered")
    sender_connect_start = event_time(sender_records, "signaling_connect_started")
    sender_connected = event_time(sender_records, "signaling_connected")
    sender_join_started = event_time(sender_records, "sender_join_started")
    paired_times = [
        event_time(sender_records, "peer_paired"),
        event_time(receiver_records, "peer_paired"),
    ]
    connected_times = [connected_time(sender_records), connected_time(receiver_records)]
    first_paired = required_extreme(paired_times, min, "peer_paired")
    both_paired = required_extreme(paired_times, max, "peer_paired")
    both_connected = required_extreme(connected_times, max, "peer_connection_connected")
    return {
        "receiver_websocket_connect_ms": elapsed_ms(receiver_connect_start, receiver_connected),
        "pairing_code_issue_ms": elapsed_ms(register_started, registered),
        "sender_websocket_connect_ms": elapsed_ms(sender_connect_start, sender_connected),
        "sender_join_to_paired_ms": elapsed_ms(sender_join_started, both_paired),
        "signaling_ready_total_ms": elapsed_ms(receiver_connect_start, both_paired),
        "webrtc_negotiation_ms": elapsed_ms(first_paired, both_connected),
    }


def connected_time(records):
    stable = event_time(records, "peer_connection_connected")
    if stable is not None:
        return stable
    # Compatibility for evidence captured before the stable semantic event existed.
    for state in ["connected", "RTCPeerConnectionState(rawValue: 2)"]:
        legacy = event_time(records, "peer_connection_state", state=state)
        if legacy is not None:
            return legacy
    return None


def required_extreme(values, operation, event):
    present = [value for value in values if value is not None]
    if len(present) != len(values):
        raise ValueError(f"required Sender/Receiver event missing: {event}")
    return operation(present)


def event_time(records, event, **required_fields):
    for record in records:
        if record.get("event") == event and all(record.get("fields", {}).get(key) == value for key, value in required_fields.items()):
            value = record.get("monotonic_ns")
            if isinstance(value, int):
                return value
    return None


def elapsed_ms(start, end):
    if start is None or end is None or end < start:
        return None
    return (end - start) / 1_000_000


def summarize(values):
    ordered = sorted(values)
    if not ordered:
        return {"count": 0, "p50": None, "p95": None, "max": None}
    return {
        "count": len(ordered),
        "p50": percentile(ordered, 0.50),
        "p95": percentile(ordered, 0.95),
        "max": ordered[-1],
    }


def percentile(ordered, fraction):
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def analyze_images(sender_dir, receiver_dir, output_dir):
    results = []
    for source in sorted(sender_dir.glob("source-reference-*.png")):
        sequence = source.stem.rsplit("-", 1)[-1]
        capture = sender_dir / f"sender-capture-{sequence}.png"
        decode = receiver_dir / f"receiver-decoded-{sequence}.png"
        if not capture.exists() or not decode.exists():
            results.append({"sequence": int(sequence), "error": "matched image triplet incomplete"})
            continue
        comparisons = {}
        for name, distorted, reference in [
            ("source_to_capture", capture, source),
            ("capture_to_decode", decode, capture),
            ("source_to_decode", decode, source),
        ]:
            comparisons[name] = image_metrics(distorted, reference, output_dir / f"{name}-{sequence}")
        results.append({"sequence": int(sequence), "comparisons": comparisons})
    return results


def image_metrics(distorted, reference, output_prefix):
    metrics = component_metrics(distorted, reference, GLOBAL_CHART_CROP)
    metrics["metric_scope"] = {
        "name": "chart_content",
        "crop": {"x": 320, "y": 0, "width": 1536, "height": 1080},
        "marker_excluded": True,
    }
    metrics["full_frame_excluding_marker"] = component_metrics(
        distorted,
        reference,
        crop=None,
        neutralize_roi=MARKER_ROI,
        total_pixels=1920 * 1080,
        excluded_pixels=192 * 192,
    )
    metrics["regions"] = {
        name: component_metrics(distorted, reference, crop)
        for name, crop in CHART_REGIONS.items()
    }
    vmaf_path = pathlib.Path(str(output_prefix) + "-vmaf.json")
    vmaf_graph = comparison_graph(
        "libvmaf=log_fmt=json:log_path="
        f"{escape_filter_path(vmaf_path)}:model=version=vmaf_v0.6.1",
        GLOBAL_CHART_CROP,
        pixel_format="yuv420p",
    )
    run_ffmpeg([
        "ffmpeg", "-hide_banner", "-nostats", "-loglevel", "error",
        "-i", str(distorted), "-i", str(reference),
        "-lavfi", vmaf_graph,
        "-f", "null", "-",
    ])
    vmaf_data = json.loads(vmaf_path.read_text(encoding="utf-8"))
    vmaf = vmaf_data.get("pooled_metrics", {}).get("vmaf", {}).get("mean")
    heatmap = pathlib.Path(str(output_prefix) + "-heatmap.png")
    run_ffmpeg([
        "ffmpeg", "-hide_banner", "-nostats", "-loglevel", "error", "-y",
        "-i", str(distorted), "-i", str(reference),
        "-filter_complex", "[0:v][1:v]blend=all_mode=difference,eq=contrast=4",
        "-frames:v", "1", str(heatmap),
    ])
    metrics.update({"vmaf_reference": vmaf, "heatmap": heatmap.name})
    return metrics


def component_metrics(
    distorted,
    reference,
    crop,
    neutralize_roi=None,
    total_pixels=None,
    excluded_pixels=0,
):
    psnr = run_filter(
        distorted, reference, "psnr",
        r"PSNR y:(\S+) u:(\S+) v:(\S+) average:(\S+)", crop=crop,
        neutralize_roi=neutralize_roi,
    )
    ssim = run_filter(
        distorted, reference, "ssim",
        r"SSIM Y:(\S+) \([^)]*\) U:(\S+) \([^)]*\) V:(\S+) \([^)]*\) All:(\S+)", crop=crop,
        neutralize_roi=neutralize_roi,
    )
    result = {
        "psnr_y": numeric(psnr[0]), "psnr_cb": numeric(psnr[1]), "psnr_cr": numeric(psnr[2]),
        "psnr_average": numeric(psnr[3]),
        "ssim_y": numeric(ssim[0]), "ssim_cb": numeric(ssim[1]), "ssim_cr": numeric(ssim[2]),
        "ssim_all": numeric(ssim[3]),
    }
    if total_pixels and excluded_pixels:
        ratio = total_pixels / (total_pixels - excluded_pixels)
        psnr_adjustment = 10 * math.log10(ratio)
        for key in ["psnr_y", "psnr_cb", "psnr_cr", "psnr_average"]:
            if isinstance(result[key], float):
                result[key] -= psnr_adjustment
        for key in ["ssim_y", "ssim_cb", "ssim_cr", "ssim_all"]:
            if isinstance(result[key], float):
                result[key] = (result[key] * total_pixels - excluded_pixels) / (total_pixels - excluded_pixels)
        result["excluded_roi"] = {"x": 64, "y": 64, "width": 192, "height": 192}
    return result


def run_filter(distorted, reference, filter_name, pattern, crop=None, neutralize_roi=None):
    filter_graph = comparison_graph(filter_name, crop, neutralize_roi=neutralize_roi)
    result = run_ffmpeg([
        "ffmpeg", "-hide_banner", "-nostats", "-i", str(distorted), "-i", str(reference),
        "-lavfi", filter_graph, "-f", "null", "-",
    ])
    match = re.search(pattern, result.stderr)
    if not match:
        raise RuntimeError(f"unable to parse {filter_name} output")
    return match.groups()


def comparison_graph(filter_name, crop=None, pixel_format="yuv444p", neutralize_roi=None):
    crop_filter = ""
    if crop:
        x, y, width, height = crop
        crop_filter = f"crop={width}:{height}:{x}:{y},"
    neutralize_filter = ""
    if neutralize_roi:
        x, y, width, height = neutralize_roi
        neutralize_filter = f"drawbox={x}:{y}:{width}:{height}:black:fill,"
    return (
        f"[0:v]{crop_filter}{neutralize_filter}format={pixel_format}[distorted];"
        f"[1:v]{crop_filter}{neutralize_filter}format={pixel_format}[reference];"
        f"[distorted][reference]{filter_name}"
    )


def run_ffmpeg(command):
    return subprocess.run(command, check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def escape_filter_path(path):
    return str(path).replace("\\", "\\\\").replace(":", "\\:").replace("'", "\\'")


def numeric(value):
    return "inf" if value.lower() in {"inf", "+inf"} else float(value)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sender-dir", required=True, type=pathlib.Path)
    parser.add_argument("--receiver-dir", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--skip-images", action="store_true")
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    sender_records = load_jsonl(args.sender_dir / "metrics.jsonl")
    receiver_records = load_jsonl(args.receiver_dir / "metrics.jsonl")
    selected_path_verified_ns = event_time(sender_records, "selected_path", status="verified")
    if selected_path_verified_ns is None:
        raise RuntimeError("selected_path verified event missing")
    all_samples = correlate_latency(sender_records, receiver_records)
    samples = measurement_window(all_samples, selected_path_verified_ns)
    measurement_start_ns = selected_path_verified_ns + 10_000_000_000
    measurement_end_ns = measurement_start_ns + 60_000_000_000
    quality_samples = None if args.skip_images else analyze_images(
        args.sender_dir, args.receiver_dir, args.output.parent
    )
    require_evidence(samples, quality_samples)
    report = {
        "configuration_identity": {
            "sender_effective_config_hash": sender_records[0].get("effective_config_hash") if sender_records else None,
            "receiver_effective_config_hash": receiver_records[0].get("effective_config_hash") if receiver_records else None,
        },
        "measurement_window": {
            "warmup_seconds": 10,
            "duration_seconds": 60,
            "marker_hz": 2,
            "target_sequences": 120,
            "correlated_sequences_before_windowing": len(all_samples),
            "valid_sequences": len(samples),
            "valid_ratio": len(samples) / 120,
        },
        "marker_counters": marker_counters(
            sender_records, receiver_records, measurement_start_ns, measurement_end_ns
        ),
        "latency_samples": samples,
        "latency_summary": {
            key: summarize([sample[key] for sample in samples])
            for key in ["commit_to_capture_ms", "capture_to_decode_ms", "software_end_to_end_ms"]
        },
        "connection_timing": connection_timing(sender_records, receiver_records),
        "quality_samples": [] if quality_samples is None else quality_samples,
    }
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
