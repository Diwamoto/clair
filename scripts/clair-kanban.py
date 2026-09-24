#!/usr/bin/env python3
"""Render docs/clair-kanban.html from docs/clair-tasks.md.

The task table is the source of truth; the board is a derived view. Run this
after editing the queue so the two can never drift.
"""

from __future__ import annotations

import html
import re
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
QUEUE = ROOT / "docs/clair-tasks.md"
BOARD = ROOT / "docs/clair-kanban.html"

ROW = re.compile(
    r"^\| `(?P<id>[BHNETUV]\d{2})` \| `(?P<status>\w+)` \| `(?P<diff>D[1-5])` "
    r"\| (?P<deps>.*?) \| (?P<outcome>.*?) \|$",
    re.MULTILINE,
)
COLUMNS = [
    ("next", "次に着手"),
    ("active", "進行中"),
    ("blocked", "ブロック"),
    ("queued", "待機"),
    ("done", "完了"),
]
CSS = """body{font:13px/1.6 -apple-system,sans-serif;background:#282c34;color:#c9cec8;margin:16px}
h1{font-size:15px;margin:0 0 4px}.meta{color:#9ba19b;font-size:12px;margin-bottom:12px}
.b{display:flex;gap:10px;align-items:flex-start}
.c{flex:1;background:#1e2227;border-radius:6px;padding:8px;min-width:0}
.c h2{font-size:12px;margin:0 0 8px;color:#f1f3ef}
.k{background:#31363f;border-radius:4px;padding:6px 8px;margin-bottom:6px}
.k b{color:#f1f3ef}.k i{color:#e5c07b;font-style:normal;font-size:11px}
.k p{margin:3px 0 0;color:#9ba19b;font-size:11px}
.done .k p{display:none}"""


def strip_markdown(text: str) -> str:
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    return text.replace("**", "").replace("`", "")


def priority(outcome: str) -> str:
    found = re.search(r"\bP[0-3]\b", outcome)
    return found.group(0) if found else ""


def main() -> int:
    if not QUEUE.exists():
        print(f"missing {QUEUE}", file=sys.stderr)
        return 1
    tasks = [m.groupdict() for m in ROW.finditer(QUEUE.read_text())]
    if not tasks:
        print("no task rows parsed", file=sys.stderr)
        return 1

    done = sum(1 for t in tasks if t["status"] == "done")
    parts = [
        "<!doctype html><meta charset=utf-8><title>Clair kanban</title>",
        f"<style>{CSS}</style>",
        f"<h1>Clair — {done}/{len(tasks)} done</h1>",
        f'<div class=meta>{date.today()} 生成 · 正本は docs/clair-tasks.md '
        "· 再生成は <code>python3 scripts/clair-kanban.py</code></div><div class=b>",
    ]
    for status, label in COLUMNS:
        rows = [t for t in tasks if t["status"] == status]
        if not rows:
            continue
        cls = "c done" if status == "done" else "c"
        parts.append(f"<div class='{cls}'><h2>{label} ({len(rows)})</h2>")
        for task in rows:
            outcome = strip_markdown(task["outcome"])
            tag = " · ".join(x for x in (priority(outcome), task["diff"]) if x)
            parts.append(
                f"<div class=k><b>{task['id']}</b> <i>{html.escape(tag)}</i>"
                f"<p>{html.escape(outcome[:400])}</p></div>"
            )
        parts.append("</div>")
    parts.append("</div>")
    BOARD.write_text("".join(parts) + "\n")
    print(f"wrote {BOARD.relative_to(ROOT)} ({done}/{len(tasks)} done)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
