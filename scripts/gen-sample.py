#!/usr/bin/env python3
"""Writes a large synthetic Markdown document for benchmarks: gen-sample.py <megabytes> > big.md"""
import sys

target = float(sys.argv[1] if len(sys.argv) > 1 else 5) * 1024 * 1024
para_zh = "这是一段用于压力测试的中文段落，包含**粗体**、*斜体*、`行内代码`和[链接](https://example.com)。渲染器需要在大文件下依然保持流畅滚动。"
para_en = "The quick brown fox jumps over the lazy dog. Markdown should open *instantly*, even when the file is huge and full of `code`."
code = "```python\ndef handler(event, context):\n    items = [x * 2 for x in range(100)]\n    return {'status': 200, 'items': items}\n```\n"
table = "| Name | Value | Note |\n|---|---:|---|\n" + "".join(f"| item{i} | {i * 37} | 说明 {i} |\n" for i in range(6))

out, size, n = [], 0, 0
while size < target:
    n += 1
    block = f"## 第 {n} 节 Section {n}\n\n{para_zh}\n\n{para_en}\n\n- 列表项 one\n- 列表项 two\n  - nested\n\n"
    if n % 3 == 0:
        block += code + "\n"
    if n % 5 == 0:
        block += table + "\n"
    if n % 10 == 0:
        block = f"# 第 {n // 10} 章\n\n" + block
    out.append(block)
    size += len(block.encode())
sys.stdout.write("# Large benchmark document\n\n" + "".join(out))
