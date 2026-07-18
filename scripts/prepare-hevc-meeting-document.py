#!/usr/bin/env python3
import argparse
import hashlib
import html
import json
import pathlib
import re
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_DIRECTORY = ROOT / "experiments" / "hevc-meeting"


def normalize_markdown(source: str) -> str:
    source = source.replace("\r\n", "\n")
    source = re.sub(r"\A---\n.*?\n---\n", "", source, count=1, flags=re.DOTALL)
    source = re.sub(r"<!--.*?-->", "", source, flags=re.DOTALL)

    def replace_shortcode(match: re.Match[str]) -> str:
        body = match.group(1)
        text_match = re.search(r'\btext=(?:"([^"]+)"|\'([^\']+)\')', body)
        if text_match:
            return text_match.group(1) or text_match.group(2)
        return ""

    source = re.sub(r"{{[<%]\s*(.*?)\s*[>%]}}", replace_shortcode, source)
    source = re.sub(r"\s+\{#[A-Za-z0-9_-]+}\s*$", "", source, flags=re.MULTILINE)
    source = re.sub(r"\n{3,}", "\n\n", source)
    return source.strip() + "\n"


def fetch_source(metadata: dict[str, str]) -> bytes:
    url = (
        "https://raw.githubusercontent.com/"
        f"{metadata['repository']}/{metadata['commit']}/{metadata['path']}"
    )
    request = urllib.request.Request(url, headers={"User-Agent": "hevc-meeting-fixture/1"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def render_markdown(markdown: str) -> str:
    payload = json.dumps({"text": markdown, "mode": "gfm"}).encode()
    request = urllib.request.Request(
        "https://api.github.com/markdown",
        data=payload,
        headers={
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "User-Agent": "hevc-meeting-fixture/1",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read().decode()


def sanitize_rendered_html(rendered: str) -> str:
    rendered = re.sub(
        r"<(?:picture|video|audio|iframe|object)\b.*?</(?:picture|video|audio|iframe|object)>",
        "",
        rendered,
        flags=re.DOTALL | re.IGNORECASE,
    )
    rendered = re.sub(
        r"<img\b[^>]*\balt=\"([^\"]*)\"[^>]*>",
        lambda match: (
            '<span class="remote-image-placeholder">远程图片已从固定实验内容中移除：'
            f"{html.escape(html.unescape(match.group(1)))}</span>"
        ),
        rendered,
        flags=re.IGNORECASE,
    )
    rendered = re.sub(r"<(?:img|source|embed|script|link)\b[^>]*>", "", rendered, flags=re.IGNORECASE)
    return rendered.strip()


def marker_script() -> str:
    return """<script>
(() => {
  const size = 12;
  const marker = document.getElementById("experiment-marker");
  const cells = Array.from({ length: size * size }, () => marker.appendChild(document.createElement("span")));
  const payloadCells = [];
  for (let y = 1; y < size - 1; y += 1) for (let x = 1; x < size - 1; x += 1) payloadCells.push([x, y]);
  const finder = (x, y) => y === 0 ? x % 2 === 0 : x === size - 1 ? y % 2 === 0 : y === size - 1 ? x % 2 !== 0 : y % 2 !== 0;
  const crc16 = bytes => {
    let crc = 0xffff;
    for (const byte of bytes) {
      crc ^= byte << 8;
      for (let bit = 0; bit < 8; bit += 1) crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
    }
    return crc;
  };
  const setSequence = sequence => {
    const values = Array(size * size).fill(false);
    for (let y = 0; y < size; y += 1) for (let x = 0; x < size; x += 1) if (x === 0 || y === 0 || x === size - 1 || y === size - 1) values[y * size + x] = finder(x, y);
    const payload = [1, sequence >>> 24, sequence >>> 16, sequence >>> 8, sequence].map(value => value & 0xff);
    const crc = crc16(payload);
    const bytes = [...payload, crc >>> 8, crc & 0xff];
    const bits = bytes.flatMap(byte => Array.from({ length: 8 }, (_, bit) => (byte & (1 << (7 - bit))) !== 0));
    payloadCells.forEach(([x, y], index) => { if (index < bits.length) values[y * size + x] = bits[index]; });
    cells.forEach((cell, index) => cell.classList.toggle("on", values[index]));
    marker.dataset.sequence = String(sequence >>> 0);
  };
  setSequence(1);
  window.__experimentMarker = { setSequence };
})();
</script>"""


def build_document(rendered: str) -> str:
    body = sanitize_rendered_html(rendered)
    return f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>固定会议投屏文档 · Kubernetes Deployment</title>
  <link rel="icon" href="data:,">
  <link rel="stylesheet" href="document.css">
</head>
<body>
  <div id="experiment-marker" aria-hidden="true"></div>
  <input id="experiment-input" type="text" aria-label="固定文字输入样本" autocomplete="off">
  <main id="document-content">
    <h1>Kubernetes Deployment</h1>
    <p class="source-note">固定实验内容：Kubernetes 中文文档 Deployment，来源版本和许可信息见 source.json。正式实验仅从 localhost 加载。</p>
    <section id="text-quality-targets" aria-label="文字与细线质量样本">
      <p class="text-12">12px 中文细字：Deployment 滚动更新、回滚与副本状态 AaBb 0123456789</p>
      <p class="text-16">16px 中英文：Kubernetes 会议投屏清晰度 / spec.replicas / maxUnavailable</p>
      <div class="fine-lines" aria-hidden="true"></div>
    </section>
{body}
  </main>
{marker_script()}
</body>
</html>
"""


def write_fixture(
    metadata: dict[str, str],
    output: pathlib.Path,
    *,
    fetch_source=fetch_source,
    render_markdown=render_markdown,
) -> None:
    source_bytes = fetch_source(metadata)
    actual_hash = hashlib.sha256(source_bytes).hexdigest()
    if actual_hash != metadata["sha256"]:
        raise RuntimeError(
            f"source SHA-256 mismatch: expected {metadata['sha256']}, got {actual_hash}"
        )
    normalized = normalize_markdown(source_bytes.decode())
    document = build_document(render_markdown(normalized))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(document, encoding="utf-8", newline="\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=pathlib.Path, default=DEFAULT_DIRECTORY)
    args = parser.parse_args()
    metadata = json.loads((args.directory / "source.json").read_text())
    write_fixture(metadata, args.directory / "document.html")


if __name__ == "__main__":
    main()
