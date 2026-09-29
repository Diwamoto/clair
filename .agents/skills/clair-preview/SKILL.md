---
name: clair-preview
description: Open locally generated HTML artifacts in Clair's interactive preview when running inside a Clair terminal. Use when an agent has made an HTML artifact for the user to view.
---

# Clair HTML preview

When `CLAIR_TERMINAL_KEY` is set and `clair` is on PATH, show a generated `.html` or `.htm` artifact with:

```bash
clair preview "/absolute/path/to/artifact.html"
```

Clair opens the file and its JavaScript-enabled preview pane. An approval card may appear in Clair; if the user denies it, stop. The preview supports self-contained HTML; relative local assets do not load. JavaScript and remote resources can use the network.

Use the requested browser when the user explicitly asks for one, or when a running web app needs browser testing. If Clair or its CLI is unavailable, tell the user where the HTML file is instead of claiming it opened.
