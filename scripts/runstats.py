#!/usr/bin/env python3
"""Summarize CPU run logs (~/Library/Logs/CPU/runs) into one table.

    scripts/runstats.py            # the last 10 runs
    scripts/runstats.py 30         # the last 30 runs
    scripts/runstats.py FILE...    # these logs

Runs logged before the summary line existed are measured from their model lines.
"""
import json
import os
import re
import sys

RUNS = os.path.expanduser("~/Library/Logs/CPU/runs")


def measure(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    title = text.split("\n", 1)[0].lstrip("# ").strip()
    summary = re.search(r"^## summary\n\n(\{.*\})$", text, re.M)
    if summary:
        stats = json.loads(summary.group(1))
    else:
        models = re.findall(r"first token (\d+)ms · total (\d+)ms · in (\d+) \(cached (\d+)\) · out (\d+)", text)
        total = re.search(r"^## result \((\d+)ms\)", text, re.M)
        thinking = sum(len(t) for t in re.findall(r"\[thinking\](.*?)(?=\n\[tool_use|\n\[text\]|\n-- first token)", text, re.S))
        waits = sum(float(s) for s in re.findall(r'"do":"wait","seconds":(\d+(?:\.\d+)?)', text))
        stats = {
            "total_ms": int(total.group(1)) if total else 0,
            "model_steps": len(models),
            "model_ms": sum(int(m[1]) for m in models),
            "first_token_ms": sum(int(m[0]) for m in models),
            "output_tokens": sum(int(m[4]) for m in models),
            "input_tokens": sum(int(m[2]) for m in models),
            "cached_tokens": sum(int(m[3]) for m in models),
            "thinking_chars": thinking,
            "tool_parts_ms": {"wait": int(waits * 1000)},
            "errors": len(re.findall(r"^## step \d+ · \w+ \(error\)", text, re.M)),
            "unchanged": text.count("No visible change:"),
            "outcome": "?",
        }
    stats["title"] = title
    stats["file"] = os.path.basename(path)
    return stats


def seconds(ms):
    return f"{ms / 1000:.1f}"


def main(args):
    if args and not args[0].isdigit():
        paths = args
    else:
        count = int(args[0]) if args else 10
        names = sorted(n for n in os.listdir(RUNS) if n.endswith(".md"))
        paths = [os.path.join(RUNS, n) for n in names[-count:]]
    rows = [measure(p) for p in paths]
    header = ["run", "request", "total", "steps", "model", "gen", "tools", "wait", "err", "same", "out tok", "think"]
    table = []
    for r in rows:
        parts = r.get("tool_parts_ms", {})
        tools = sum(r.get("tool_ms", {}).values()) if "tool_ms" in r else r["total_ms"] - r["model_ms"]
        table.append([
            r["file"][:17],
            r["title"][:24],
            seconds(r["total_ms"]),
            str(r["model_steps"]),
            seconds(r["model_ms"]),
            seconds(r["model_ms"] - r["first_token_ms"]),
            seconds(tools),
            seconds(parts.get("wait", 0)),
            str(r["errors"]),
            str(r["unchanged"]),
            str(r["output_tokens"]),
            str(r["thinking_chars"]),
        ])
    widths = [max(len(header[i]), *(len(row[i]) for row in table)) if table else len(header[i]) for i in range(len(header))]
    print("  ".join(h.ljust(w) for h, w in zip(header, widths)))
    for row in table:
        print("  ".join(c.ljust(w) for c, w in zip(row, widths)))
    if not rows:
        return
    total = sum(r["total_ms"] for r in rows)
    model = sum(r["model_ms"] for r in rows)
    wait = sum(r.get("tool_parts_ms", {}).get("wait", 0) for r in rows)
    print(f"\n{len(rows)} runs, {seconds(total)}s: model {model * 100 // max(total, 1)}%, waiting {wait * 100 // max(total, 1)}%, "
          f"{sum(r['model_steps'] for r in rows)} model steps, {sum(r['errors'] for r in rows)} errors, "
          f"{sum(r['thinking_chars'] for r in rows)} thinking chars")
    parts = {}
    for r in rows:
        for key, ms in r.get("tool_parts_ms", {}).items():
            parts[key] = parts.get(key, 0) + ms
    if len(parts) > 1:
        print("tool time by part: " + " · ".join(f"{k} {seconds(v)}s" for k, v in sorted(parts.items(), key=lambda kv: -kv[1])))


if __name__ == "__main__":
    main(sys.argv[1:])
