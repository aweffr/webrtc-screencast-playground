#!/usr/bin/env python3
import argparse
import json
import os
import pathlib


REQUESTED_QPS = (24, 22, 20, 18)


def read_json(path):
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def load_case(experiment_root, requested_qp):
    case_root = experiment_root / f"qp-{requested_qp}"
    evidence = read_json(case_root / "qp-evidence.json")
    vmaf = read_json(case_root / "vmaf.json")
    image = case_root / "android-received-final.png"
    if not image.is_file():
        raise RuntimeError(f"missing Android received image for QP {requested_qp}")
    if evidence.get("requested_max_qp") != requested_qp:
        raise RuntimeError(f"requested QP mismatch for case {requested_qp}")
    if evidence.get("effective_max_qp") != requested_qp:
        raise RuntimeError(f"effective QP mismatch for case {requested_qp}")
    if evidence.get("max_qp_apply_state") != "applied":
        raise RuntimeError(f"runtime QP was not applied for case {requested_qp}")
    actual_qp = evidence.get("last_key_frame_qp")
    if not isinstance(actual_qp, int) or not 0 <= actual_qp <= requested_qp:
        raise RuntimeError(f"invalid keyframe QP evidence for case {requested_qp}")
    score = vmaf.get("pooled_metrics", {}).get("vmaf", {}).get("mean")
    if not isinstance(score, (int, float)):
        raise RuntimeError(f"missing VMAF score for case {requested_qp}")
    return {"evidence": evidence, "vmaf": float(score), "image": image}


def render_report(experiment_root, output):
    experiment_root = pathlib.Path(experiment_root).resolve()
    output = pathlib.Path(output).resolve()
    manifest = read_json(experiment_root / "manifest.json")
    cases = {qp: load_case(experiment_root, qp) for qp in REQUESTED_QPS}
    output.parent.mkdir(parents=True, exist_ok=True)

    lines = [
        "# macOS 主屏幕静态 Max-QP 对比",
        "",
        "本报告记录同一台 Mac 发送到 Android TV API 31 arm64 emulator、"
        "经 production TURN/UDP 的四档静态画质实验。所有 case 均保持 1920×1080、"
        "静态 1 fps、动态 15 fps、5 Mbps；只改变静态 `MaxAllowedFrameQP`。",
        "",
        f"- 生成时间：`{manifest.get('generated_at', 'UNKNOWN')}`",
        f"- XCFramework SHA-256：`{manifest.get('xcframework_sha256', 'UNKNOWN')}`",
        f"- macOS app commit：`{manifest.get('app_commit', 'UNKNOWN')}`",
        f"- 发送端：`{manifest.get('hardware_model', 'UNKNOWN')}` / macOS "
        f"`{manifest.get('macos_version', 'UNKNOWN')}`",
        f"- 接收端：`{manifest.get('android_device', 'UNKNOWN')}` / API "
        f"`{manifest.get('android_api', 'UNKNOWN')}` / "
        f"`{manifest.get('android_abi', 'UNKNOWN')}`",
        f"- 单档运行时长：`{manifest.get('run_seconds', 'UNKNOWN')} s`",
        "- 路径：`relay/relay + UDP`（每档均由现有 E2E verifier 校验）",
        "",
        "## 数据",
        "",
        "| 请求 Max QP | 回读 Max QP | 实际 IDR QP | IDR bytes | generation | encoder session | VMAF（参考） |",
        "|---:|---:|---:|---:|---:|---|---:|",
    ]
    for qp in REQUESTED_QPS:
        case = cases[qp]
        evidence = case["evidence"]
        lines.append(
            f"| {qp} | {evidence['effective_max_qp']} | "
            f"{evidence['last_key_frame_qp']} | {evidence['last_key_frame_bytes']} | "
            f"{evidence.get('max_qp_generation', 'N/A')} | "
            f"`{evidence.get('encoder_session_id', 'UNKNOWN')}` | {case['vmaf']:.3f} |"
        )

    lines.extend([
        "",
        "VMAF 仅作为相对参考：reference 是接收截图前后同一静态桌面的本机主屏幕截图，"
        "按 ScreenCaptureKit 相同的 aspect-fit/letterbox 几何缩放到 1920×1080；它不是逐帧时间戳对齐的严格视频 VMAF，"
        "也不作为通过门槛。流中始终保留 cursor。",
        "",
        "## Android 实收画面",
        "",
    ])
    for qp in REQUESTED_QPS:
        relative = pathlib.Path(os.path.relpath(cases[qp]["image"], output.parent))
        lines.extend([
            f"### Max QP {qp}",
            "",
            f"![Android received final frame — Max QP {qp}]({relative.as_posix()})",
            "",
        ])
    output.write_text("\n".join(lines), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--experiment-root", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    render_report(args.experiment_root, args.output)


if __name__ == "__main__":
    main()
