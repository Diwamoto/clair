#!/usr/bin/env python3
"""Read and rewrite a Claude Design canvas artifact.

A canvas artifact keeps its entire editable state as JSON in the
`<script id="appifact-doc">` block: `content.files` maps one
`<Artboard>.dc.html` source per artboard, plus `canvas.json` for the layout
and annotations. Everything else in the file is the editor itself and must
survive a round trip untouched.

    extract  artifact.html  outdir/          # one file per artboard
    pack     artifact.html  outdir/  new.html

Edit the extracted `.dc.html` files as ordinary HTML, then pack them back.
Pack only rewrites the JSON payload; the editor bytes around it are copied
verbatim, so the result stays a working canvas.
"""

from __future__ import annotations

import json
import pathlib
import sys


def _payload_bounds(html: str) -> tuple[int, int]:
    marker = html.index('id="appifact-doc"')
    start = html.index(">", marker) + 1
    return start, html.index("</script>", start)


def load(path: pathlib.Path) -> tuple[str, dict, int, int]:
    html = path.read_text()
    start, end = _payload_bounds(html)
    return html, json.loads(html[start:end]), start, end


def extract(artifact: pathlib.Path, outdir: pathlib.Path) -> None:
    _, doc, _, _ = load(artifact)
    outdir.mkdir(parents=True, exist_ok=True)
    for name, body in doc["content"]["files"].items():
        (outdir / name).write_text(body)
        print(f"{name}\t{len(body)} bytes")


def pack(artifact: pathlib.Path, indir: pathlib.Path, out: pathlib.Path) -> None:
    html, doc, start, end = load(artifact)
    files = doc["content"]["files"]

    changed = []
    for name in list(files):
        source = indir / name
        if not source.exists():
            raise SystemExit(f"missing {source} — pack needs every file extract produced")
        body = source.read_text()
        if body != files[name]:
            changed.append(name)
        files[name] = body

    # `<` is escaped so a literal `</script>` inside an artboard cannot end the
    # block early. JSON has no structural `<`, so replacing every one is safe.
    payload = json.dumps(doc, ensure_ascii=False).replace("<", "\\u003c")
    out.write_text(html[:start] + payload + html[end:])

    print("changed: " + (", ".join(changed) if changed else "(nothing)"))
    print(f"wrote {out} ({len(out.read_text())} bytes)")


def main(argv: list[str]) -> None:
    if len(argv) < 4:
        raise SystemExit(__doc__)
    command, artifact, target = argv[1], pathlib.Path(argv[2]), pathlib.Path(argv[3])
    if command == "extract":
        extract(artifact, target)
    elif command == "pack":
        if len(argv) < 5:
            raise SystemExit(__doc__)
        pack(artifact, target, pathlib.Path(argv[4]))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
