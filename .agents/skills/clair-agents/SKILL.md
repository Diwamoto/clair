---
name: clair-agents
description: Fan work out to parallel child agents in split Clair terminal panes and collect their results with the `clair` CLI. Use when you run inside a Clair terminal (`CLAIR_TERMINAL_KEY` is set) and a task splits into independent parts worth running in parallel — optionally each on its own Git branch/worktree — then gather the results and close the panes before continuing the main flow.
---

# Clair agents (fan-out / fan-in)

Works only inside a Clair terminal: `echo $CLAIR_TERMINAL_KEY` must print `<root>#<pane>`, and `clair`
must be on PATH (Clair → 設定 → AIプロバイダー → `clair` コマンドをインストール).
Every `clair` call prints one JSON reply; exit 0 = ok, 1 = command error, 3 = Clair not running.

## 1. Launch children

```bash
clair agent.launch profile=claude prompt="<self-contained task>" [direction=right|down] [branch=<new-branch>]
# → {"result":{"text":{"_0":"/path/to/project#7"}}}   ← the child's key
```

- Children open as panes split from **your** pane; the user's focus does not move.
- `profile`: `claude`, `codex`, or `opencode`. With `prompt` the child runs non-interactively
  (`claude -p` / `codex exec` / `opencode run`) and exits when done.
- `branch=<name>` creates a Clair-managed worktree on a new branch and runs the child there.
  Use it when children edit files, so they cannot collide. The branch must not exist yet.
- The first launch shows an approval card in Clair; after the user approves, further launches
  from the same pane are allowed for 10 minutes. `denied` means the user said no — stop, don't retry.
- A prompt is the child's only context. Write it like a ticket: paths, commands, done criteria.

## 2. Wait and collect

```bash
clair agent.wait key="<key>" [timeout=1800]   # exit 0 when that child exited, 1 on timeout
clair agent.status key="<key>"                # "running" | "exited <code>"
clair agent.output key="<key>" [lines=200]     # the child's last output lines
```

Launch all children first, then wait on each key in turn.

## 3. Close and continue

```bash
clair agent.close key="<key>"
```

Closing your own finished child needs no approval. Worktree branches stay; merge or remove them
through the normal Git flow (the user can adopt them from Clair's Git panel).
