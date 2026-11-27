---
name: clair-preview
description: Show locally generated HTML artifacts in Clair as HTML tools (or preview them in place) when running inside a Clair terminal. Use when an agent has made an HTML artifact for the user to view or use.
---

# Clair HTML tools

When `CLAIR_TERMINAL_KEY` is set and `clair` is on PATH, show a generated `.html` or `.htm` artifact as an HTML tool:

```bash
clair tool add path="/absolute/path/to/artifact.html"
```

Clair copies it into the user's HTML tools (`~/.clair/tools`; the same file name overwrites, so run it again after regenerating the file) and opens it in a pane of its own. An approval card may appear in Clair; if the user denies it, stop. Add `open=false` to only add it. `clair tool list --compact` lists the tools (Clair's own ones too) and `clair tool open name=<file name>` shows one again.

To preview a file where it is instead, beside its source in the editor, use `clair preview "/absolute/path/to/artifact.html"`.

Relative `<link>`, `<script>`, `fetch` and module paths load only from the HTML file's own folder (for a tool, `~/.clair/tools`), so prefer one self-contained file. JavaScript and remote resources can use the network.

Use the requested browser when the user explicitly asks for one, or when a running web app needs browser testing. If Clair or its CLI is unavailable, tell the user where the HTML file is instead of claiming it opened.
