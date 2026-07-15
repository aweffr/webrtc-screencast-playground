#!/usr/bin/env python3
import argparse
import importlib.util
import json
import math
import pathlib


EXPECTED_WIDTH = 1920
EXPECTED_HEIGHT = 1080
QUALITY_SEQUENCES = (30, 80, 130)


def load_jsonl(path):
    with pathlib.Path(path).open(encoding="utf-8") as stream:
        return [json.loads(line) for line in stream if line.strip()]


def require_calibration(records, side):
    event = "clock_calibrated" if side == "sender" else "clock_calibration"
    for record in records:
        if record.get("event") != event:
            continue
        fields = record.get("fields", {})
        required = ("sample_count", "offset_ns", "round_trip_ns", "uncertainty_ns")
        if not all(is_integer(fields.get(key)) for key in required):
            break
        if fields["sample_count"] != 5:
            raise RuntimeError(f"{side} clock calibration must contain five samples")
        if fields["round_trip_ns"] < 0 or fields["uncertainty_ns"] < 0:
            break
        return {
            "sample_count": fields["sample_count"],
            "offset_ns": fields["offset_ns"],
            "round_trip_ns": fields["round_trip_ns"],
            "uncertainty_ns": fields["uncertainty_ns"],
        }
    raise RuntimeError(f"{side} clock calibration missing or invalid")


def correlate_latency(sender_records, receiver_records):
    sender_calibration = require_calibration(sender_records, "sender")
    receiver_calibration = require_calibration(receiver_records, "receiver")
    commits = sequence_values(
        sender_records, "baseline_marker_committed", "committed_monotonic_ns")
    captures = sequence_values(
        sender_records, "baseline_capture_detected", "callback_monotonic_ns")
    renders = sequence_render_values(receiver_records)
    samples = []
    for sequence in sorted(commits.keys() & captures.keys() & renders.keys()):
        commit_local = commits[sequence]
        capture_local = captures[sequence]
        render = renders[sequence]
        commit_common = to_common_time(commit_local, sender_calibration)
        capture_common = to_common_time(capture_local, sender_calibration)
        render_common = to_common_time(render["local_monotonic_ns"], receiver_calibration)
        if render["common_time_ns"] != render_common:
            raise RuntimeError(
                f"Android common-time mismatch for marker sequence {sequence}")
        if not commit_common <= capture_common <= render_common:
            raise RuntimeError(
                f"non-monotonic calibrated marker timestamps for sequence {sequence}")
        samples.append({
            "sequence": sequence,
            "sender_commit_local_monotonic_ns": commit_local,
            "sender_commit_common_time_ns": commit_common,
            "sender_capture_local_monotonic_ns": capture_local,
            "sender_capture_common_time_ns": capture_common,
            "android_render_local_monotonic_ns": render["local_monotonic_ns"],
            "android_render_common_time_ns": render_common,
            "marker_commit_to_capture_ms": (capture_common - commit_common) / 1_000_000,
            "capture_to_android_render_ms": (render_common - capture_common) / 1_000_000,
            "android_render_software_end_to_end_ms": (render_common - commit_common) / 1_000_000,
        })
    return samples


def sequence_values(records, event, value_key):
    values = {}
    for record in records:
        if record.get("event") != event:
            continue
        fields = record.get("fields", {})
        sequence = fields.get("sequence")
        value = fields.get(value_key)
        if is_integer(sequence) and is_integer(value):
            values.setdefault(sequence, value)
    return values


def sequence_render_values(records):
    values = {}
    for record in records:
        if record.get("event") != "baseline_android_render_detected":
            continue
        fields = record.get("fields", {})
        required = ("sequence", "local_monotonic_ns", "common_time_ns")
        if all(is_integer(fields.get(key)) for key in required):
            values.setdefault(fields["sequence"], {
                "local_monotonic_ns": fields["local_monotonic_ns"],
                "common_time_ns": fields["common_time_ns"],
            })
    return values


def to_common_time(local_monotonic_ns, calibration):
    value = local_monotonic_ns + calibration["offset_ns"]
    if not -(2**63) <= value < 2**63:
        raise RuntimeError("calibrated common time overflows signed 64-bit range")
    return value


def require_selected_path(sender_records, receiver_records, profile):
    if profile not in {"direct-baseline", "production-relay"}:
        raise ValueError(f"unknown ICE profile: {profile}")
    sender_paths = [
        {
            "status": fields.get("status"),
            "local": fields.get("local_candidate_type"),
            "remote": fields.get("remote_candidate_type"),
            "protocol": normalized_protocol(fields.get("protocol")),
        }
        for record in sender_records
        if record.get("event") == "selected_path"
        for fields in [record.get("fields", {})]
    ]
    receiver_paths = [
        {
            "status": fields.get("path_status"),
            "local": fields.get("local_path_type"),
            "remote": fields.get("remote_path_type"),
            "protocol": normalized_protocol(fields.get("path_protocol")),
        }
        for record in receiver_records
        if record.get("event") == "rtc_stats"
        for fields in [record.get("fields", {})]
    ]
    valid = (
        path_matches_profile(sender_paths, profile)
        and path_matches_profile(receiver_paths, profile)
    )
    if not valid:
        raise RuntimeError(f"{profile} selected-path violation")


def path_matches_profile(paths, profile):
    for path in paths:
        if path["status"] not in {"verified", "accepted"} or path["protocol"] != "udp":
            continue
        if (
            profile == "production-relay"
            and path["local"] == "relay"
            and path["remote"] == "relay"
        ):
            return True
        if profile == "direct-baseline" and (
            path["local"] not in {None, "relay"}
            and path["remote"] not in {None, "relay"}
        ):
            return True
    return False


def normalized_protocol(value):
    if not isinstance(value, str):
        return None
    return value.lower().split("/", 1)[0]


def require_render_resolution(receiver_records):
    for record in receiver_records:
        fields = record.get("fields", {})
        if record.get("event") in {"baseline_android_render_detected", "rtc_stats"} and (
            fields.get("frame_width") == EXPECTED_WIDTH
            and fields.get("frame_height") == EXPECTED_HEIGHT
        ):
            return
    raise RuntimeError("missing Android 1920x1080 render evidence")


def require_image_triplets(sender_dir, receiver_dir):
    sender_dir = pathlib.Path(sender_dir)
    receiver_dir = pathlib.Path(receiver_dir)
    triplets = []
    for sequence in QUALITY_SEQUENCES:
        triplet = {
            "sequence": sequence,
            "source": sender_dir / f"source-reference-{sequence:06d}.png",
            "capture": sender_dir / f"sender-capture-{sequence:06d}.png",
            "android_render": receiver_dir / f"android-decoded-seq-{sequence:06d}.png",
        }
        if not all(path.is_file() for key, path in triplet.items() if key != "sequence"):
            raise RuntimeError("expected three complete image triplets")
        triplets.append(triplet)
    return triplets


def reject_credentials(paths, credentials):
    forbidden = [value.encode() for value in credentials if isinstance(value, str) and value]
    if not forbidden:
        return
    for root in map(pathlib.Path, paths):
        files = [root] if root.is_file() else (path for path in root.rglob("*") if path.is_file())
        for path in files:
            content = path.read_bytes()
            if any(secret in content for secret in forbidden):
                raise RuntimeError(f"retained evidence contains configured credential: {path}")


def measurement_window(samples, sender_records, sender_calibration, warmup_seconds, duration_seconds):
    selected_local = event_time(sender_records, "selected_path", status="verified")
    if selected_local is None:
        raise RuntimeError("sender verified selected-path timestamp missing")
    start = to_common_time(selected_local, sender_calibration) + warmup_seconds * 1_000_000_000
    end = start + duration_seconds * 1_000_000_000
    return [
        sample for sample in samples
        if start <= sample["sender_commit_common_time_ns"] < end
    ], start, end


def event_time(records, event, **required_fields):
    for record in records:
        fields = record.get("fields", {})
        if record.get("event") == event and all(
            fields.get(key) == value for key, value in required_fields.items()
        ):
            value = record.get("monotonic_ns")
            if is_integer(value):
                return value
    return None


def connection_timing(sender_records, receiver_records, sender_calibration, receiver_calibration):
    receiver_start = required_event_common(
        receiver_records, "signaling_connect_started", receiver_calibration)
    receiver_connected = required_event_common(
        receiver_records, "signaling_connected", receiver_calibration)
    receiver_registered = required_event_common(
        receiver_records, "receiver_registered", receiver_calibration)
    receiver_paired = required_event_common(
        receiver_records, "session_paired", receiver_calibration)
    receiver_playing = required_event_common(
        receiver_records, "remote_video_playing", receiver_calibration)
    sender_start = required_event_common(
        sender_records, "signaling_connect_started", sender_calibration)
    sender_connected = required_event_common(
        sender_records, "signaling_connected", sender_calibration)
    sender_join = required_event_common(
        sender_records, "sender_join_started", sender_calibration)
    sender_paired = required_event_common(
        sender_records, "peer_paired", sender_calibration)
    sender_peer_connected = required_event_common(
        sender_records, "peer_connection_connected", sender_calibration)
    first_paired = min(sender_paired, receiver_paired)
    both_paired = max(sender_paired, receiver_paired)
    both_media_ready = max(sender_peer_connected, receiver_playing)
    return {
        "receiver_websocket_connect_ms": elapsed_ms(receiver_start, receiver_connected),
        "pairing_code_issue_ms": elapsed_ms(receiver_start, receiver_registered),
        "sender_websocket_connect_ms": elapsed_ms(sender_start, sender_connected),
        "sender_join_to_paired_ms": elapsed_ms(sender_join, both_paired),
        "signaling_ready_total_ms": elapsed_ms(receiver_start, both_paired),
        "webrtc_negotiation_to_media_ready_ms": elapsed_ms(first_paired, both_media_ready),
    }


def required_event_common(records, event, calibration):
    local = event_time(records, event)
    if local is None:
        raise RuntimeError(f"required timing event missing: {event}")
    return to_common_time(local, calibration)


def elapsed_ms(start, end):
    if end < start:
        raise RuntimeError("calibrated connection timing is non-monotonic")
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
    image_analyzer = load_existing_image_analyzer()
    output_dir = pathlib.Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    results = []
    for triplet in require_image_triplets(sender_dir, receiver_dir):
        sequence = triplet["sequence"]
        comparisons = {}
        for name, distorted, reference in (
            ("source_to_capture", triplet["capture"], triplet["source"]),
            ("capture_to_android_render", triplet["android_render"], triplet["capture"]),
            ("source_to_android_render", triplet["android_render"], triplet["source"]),
        ):
            comparisons[name] = image_analyzer.image_metrics(
                distorted, reference, output_dir / f"{name}-{sequence:06d}")
        results.append({"sequence": sequence, "comparisons": comparisons})
    return results


def load_existing_image_analyzer():
    path = pathlib.Path(__file__).with_name("analyze-media-baseline.py")
    spec = importlib.util.spec_from_file_location("existing_media_baseline_analyzer", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def runtime_credentials(path):
    if path is None:
        return []
    payload = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    turn = payload.get("turn", {})
    return [turn.get("username"), turn.get("password")]


def is_integer(value):
    return isinstance(value, int) and not isinstance(value, bool)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sender-dir", required=True, type=pathlib.Path)
    parser.add_argument("--receiver-dir", required=True, type=pathlib.Path)
    parser.add_argument("--profile", required=True,
                        choices=("direct-baseline", "production-relay"))
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--runtime-config", type=pathlib.Path)
    parser.add_argument("--warmup-seconds", type=int, default=10)
    parser.add_argument("--duration-seconds", type=int, default=60)
    parser.add_argument("--skip-images", action="store_true")
    args = parser.parse_args()

    sender_records = load_jsonl(args.sender_dir / "metrics.jsonl")
    receiver_records = load_jsonl(args.receiver_dir / "receiver.jsonl")
    sender_calibration = require_calibration(sender_records, "sender")
    receiver_calibration = require_calibration(receiver_records, "receiver")
    require_selected_path(sender_records, receiver_records, args.profile)
    require_render_resolution(receiver_records)
    all_samples = correlate_latency(sender_records, receiver_records)
    samples, start_ns, end_ns = measurement_window(
        all_samples, sender_records, sender_calibration,
        args.warmup_seconds, args.duration_seconds)
    if not samples:
        raise RuntimeError("no calibrated Android marker in the measurement window")
    quality = [] if args.skip_images else analyze_images(
        args.sender_dir, args.receiver_dir, args.output.parent)
    credentials = runtime_credentials(args.runtime_config)
    reject_credentials([args.sender_dir, args.receiver_dir, args.output.parent], credentials)

    latency_keys = (
        "marker_commit_to_capture_ms",
        "capture_to_android_render_ms",
        "android_render_software_end_to_end_ms",
    )
    report = {
        "latency_semantics": "software markers; not optical glass-to-glass",
        "clock_calibration": {
            "sender": sender_calibration,
            "android_receiver": receiver_calibration,
        },
        "measurement_window": {
            "start_common_time_ns": start_ns,
            "end_common_time_ns": end_ns,
            "warmup_seconds": args.warmup_seconds,
            "duration_seconds": args.duration_seconds,
            "correlated_sequences_before_windowing": len(all_samples),
            "valid_sequences": len(samples),
        },
        "latency_samples": samples,
        "latency_summary": {
            key: summarize([sample[key] for sample in samples])
            for key in latency_keys
        },
        "connection_timing": connection_timing(
            sender_records, receiver_records,
            sender_calibration, receiver_calibration),
        "quality_samples": quality,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    reject_credentials([args.output], credentials)


if __name__ == "__main__":
    main()
