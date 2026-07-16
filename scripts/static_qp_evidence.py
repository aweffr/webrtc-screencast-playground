#!/usr/bin/env python3
import argparse
import json
import pathlib
import sys


CAPTURE_IDENTITY_FIELDS = (
    "requested_max_qp",
    "effective_max_qp",
    "max_qp_generation",
    "max_qp_applied_encoder_session_id",
    "last_qp_sample_generation",
    "last_qp_sample_encoder_session_id",
    "last_key_frame_qp",
    "last_key_frame_bytes",
)


def is_bound_evidence(evidence, requested_qp):
    generation = evidence.get("max_qp_generation")
    applied_session = evidence.get("max_qp_applied_encoder_session_id")
    actual_qp = evidence.get("last_key_frame_qp")
    encoded_bytes = evidence.get("last_key_frame_bytes")
    return (
        evidence.get("clarity_mode") == "static_clarity"
        and evidence.get("requested_max_qp") == requested_qp
        and evidence.get("effective_max_qp") == requested_qp
        and evidence.get("max_qp_apply_state") == "applied"
        and isinstance(generation, int)
        and generation > 0
        and evidence.get("last_qp_sample_generation") == generation
        and isinstance(applied_session, str)
        and bool(applied_session)
        and evidence.get("last_qp_sample_encoder_session_id") == applied_session
        and isinstance(actual_qp, int)
        and 0 <= actual_qp <= requested_qp
        and isinstance(encoded_bytes, int)
        and encoded_bytes > 0
    )


def latest_bound_evidence(records, requested_qp):
    for index in range(len(records) - 1, -1, -1):
        record = records[index]
        if record.get("event") != "rtc_stats":
            continue
        evidence = record.get("fields", {}).get("sender_media_boundary")
        if isinstance(evidence, dict) and is_bound_evidence(evidence, requested_qp):
            result = dict(evidence)
            result["metrics_record_index"] = index
            return result
        raise ValueError(
            f"latest rtc_stats does not contain bound max-QP evidence for {requested_qp}"
        )
    raise ValueError("no rtc_stats records")


def same_capture_window(before, after):
    requested_qp = before.get("requested_max_qp")
    if not isinstance(requested_qp, int):
        return False
    if not is_bound_evidence(before, requested_qp):
        return False
    if not is_bound_evidence(after, requested_qp):
        return False
    before_index = before.get("metrics_record_index")
    after_index = after.get("metrics_record_index")
    if not isinstance(before_index, int) or not isinstance(after_index, int):
        return False
    if after_index <= before_index:
        return False
    return all(before.get(field) == after.get(field) for field in CAPTURE_IDENTITY_FIELDS)


def read_json(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def read_jsonl(path):
    records = []
    with pathlib.Path(path).open(encoding="utf-8") as stream:
        for line in stream:
            if line.strip():
                records.append(json.loads(line))
    return records


def write_json_atomic(path, payload):
    path = pathlib.Path(path)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def main(argv=None):
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    latest = subparsers.add_parser("latest")
    latest.add_argument("--metrics", required=True, type=pathlib.Path)
    latest.add_argument("--requested", required=True, type=int)
    latest.add_argument("--output", required=True, type=pathlib.Path)
    same = subparsers.add_parser("same-window")
    same.add_argument("--before", required=True, type=pathlib.Path)
    same.add_argument("--after", required=True, type=pathlib.Path)
    args = parser.parse_args(argv)

    try:
        if args.command == "latest":
            evidence = latest_bound_evidence(read_jsonl(args.metrics), args.requested)
            write_json_atomic(args.output, evidence)
            return 0
        return 0 if same_capture_window(read_json(args.before), read_json(args.after)) else 1
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
