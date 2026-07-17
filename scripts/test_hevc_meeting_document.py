#!/usr/bin/env python3
import hashlib
import importlib.util
import json
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "prepare-hevc-meeting-document.py"


def load_module():
    spec = importlib.util.spec_from_file_location("hevc_meeting_document", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class HEVCMeetingDocumentTests(unittest.TestCase):
    def test_source_identity_is_pinned(self):
        source = json.loads(
            (ROOT / "experiments" / "hevc-meeting" / "source.json").read_text()
        )
        self.assertEqual(
            source,
            {
                "repository": "kubernetes/website",
                "commit": "be897babb9149b808e2ab8ed5367e5d0651b3dca",
                "path": "content/zh-cn/docs/concepts/workloads/controllers/deployment.md",
                "git_blob": "817964c16c50546a73820e762446ca3e126d67a3",
                "sha256": "04ad31b16459a5a6f4d56868967b9d35303d9b7e1ea20300bfc826082fc2292f",
                "license": "CC-BY-4.0",
            },
        )

    def test_normalization_removes_site_syntax_but_preserves_screen_content(self):
        module = load_module()
        source = """---
title: Deployments
---
<!-- English duplicate -->
一个 Deployment 为 {{< glossary_tooltip text="Pod" term_id="pod" >}} 提供更新。
{{< note >}}
不要手工管理 ReplicaSet。
{{< /note >}}

| 字段 | 值 |
| --- | --- |
| replicas | 3 |

```yaml
kind: Deployment
```
"""
        normalized = module.normalize_markdown(source)
        self.assertNotIn("title: Deployments", normalized)
        self.assertNotIn("<!--", normalized)
        self.assertNotIn("{{<", normalized)
        self.assertIn("Pod", normalized)
        self.assertIn("不要手工管理", normalized)
        self.assertIn("| 字段 | 值 |", normalized)
        self.assertIn("```yaml", normalized)

    def test_fixture_is_local_deterministic_and_contains_quality_targets(self):
        module = load_module()
        rendered = """
<h1>Deployment</h1>
<p>中文正文与 <a href="https://kubernetes.io/">链接</a></p>
<img src="https://example.test/remote.png" alt="远程图">
<table><tr><th>字段</th><th>值</th></tr><tr><td>replicas</td><td>3</td></tr></table>
<pre><code class="language-yaml">kind: Deployment</code></pre>
"""
        first = module.build_document(rendered)
        second = module.build_document(rendered)
        self.assertEqual(first, second)
        self.assertNotRegex(first, r'<(?:img|script|link)[^>]+(?:src|href)="https?://')
        self.assertIn('href="document.css"', first)
        self.assertIn('id="experiment-marker"', first)
        self.assertIn("window.__experimentMarker = { setSequence }", first)
        self.assertNotIn("setInterval", first)
        self.assertIn('id="text-quality-targets"', first)
        self.assertIn('class="text-12"', first)
        self.assertIn('class="text-16"', first)
        self.assertIn("中文正文", first)
        self.assertIn("<table>", first)
        self.assertIn("<pre>", first)

    def test_write_fixture_verifies_source_hash_and_repeats_byte_for_byte(self):
        module = load_module()
        source = "---\ntitle: x\n---\n# 标题\n"
        source_bytes = source.encode()
        metadata = {
            "repository": "example/docs",
            "commit": "a" * 40,
            "path": "doc.md",
            "git_blob": "b" * 40,
            "sha256": hashlib.sha256(source_bytes).hexdigest(),
            "license": "CC-BY-4.0",
        }
        with tempfile.TemporaryDirectory() as temporary:
            output = pathlib.Path(temporary) / "document.html"
            module.write_fixture(
                metadata,
                output,
                fetch_source=lambda _: source_bytes,
                render_markdown=lambda _: "<h1>标题</h1>",
            )
            first = output.read_bytes()
            module.write_fixture(
                metadata,
                output,
                fetch_source=lambda _: source_bytes,
                render_markdown=lambda _: "<h1>标题</h1>",
            )
            self.assertEqual(first, output.read_bytes())

            bad = dict(metadata, sha256="0" * 64)
            with self.assertRaisesRegex(RuntimeError, "SHA-256"):
                module.write_fixture(
                    bad,
                    output,
                    fetch_source=lambda _: source_bytes,
                    render_markdown=lambda _: "<h1>标题</h1>",
                )


if __name__ == "__main__":
    unittest.main()
