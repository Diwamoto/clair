import Foundation

// V16: the `clair-agents` skill, shipped inside the app so Settings can install it for agents outside this repo.
// Kept byte-identical to `.agents/skills/clair-agents/SKILL.md` by `ClairAgentSkillTests`.
public enum ClairAgentSkill {
  public static let name = "clair-agents"
  public static let markdown = #"""
---
name: clair-agents
description: Work through Clair's own panes — launch child agents in split terminal panes, open files/diffs/reviews in the editor for the user to see — with the `clair` CLI and the `mcp__clair__*` tools. Use by default whenever you run inside a Clair terminal (`CLAIR_TERMINAL_KEY` is set) — not only for parallel work: any side task (investigation, test run, long build, a second opinion, an isolated fix on its own branch) goes to a child pane, and anything the user should look at is opened in Clair instead of pasted into chat.
---

# Clair agents (fan-out / fan-in)

## Default reflexes — act, don't ask

Inside Clair, use its panes proactively; the user wants this without being asked.

- Side work that doesn't need your context (research, reproduction, test/build runs, a review of
  your own diff, an independent fix) → launch a child pane (§1) and keep going on the main flow.
  Even a single child is fine; don't wait for "parallelizable" work.
- Changes that edit files → give the child `branch=` so it works in its own worktree.
- Files, diffs, or review points the user should see → open them in Clair
  (`mcp__clair__file_open`, `mcp__clair__diff_open`, `mcp__clair__review_comment`) rather than
  quoting them in chat.
- Clean up: close finished child panes (§3) before you report back.

Works only inside a Clair terminal: `echo $CLAIR_TERMINAL_KEY` must print `<root>#<pane>`, and `clair`
must be on PATH (Clair → 設定 → AIプロバイダー → `clair` コマンドをインストール).
Add `--compact` to every `clair` call: it prints one line of JSON, `{"ok":true,"result":…}` or `{"ok":false,"error":{"code":…,"message":…}}`
(without it the reply is indented for people). Exit 0 = ok, 1 = command error, 2 = usage, 3 = Clair not running.
Branch on `error.code`: `error.message` follows Clair's language.

## 1. Launch children

```bash
clair agent launch profile=claude prompt="<self-contained task>" [direction=right|down] [branch=<new-branch>]
# → {"ok":true,"result":"/path/to/project#7"}   ← the child's key
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
clair agent wait key="<key>" [timeout=1800]   # exit 0 when that child exited, 1 on timeout
clair agent status key="<key>"                # "running" | "exited <code>"
clair agent output key="<key>" [lines=200]     # last output lines — works on any terminal pane in the
                                               # active Project (find keys with `clair agent list`), not only your children
```

Launch all children first, then wait on each key in turn.

## 3. Close and continue

```bash
clair agent close key="<key>"
```

Closing your own finished child needs no approval. Worktree branches stay; merge or remove them
through the normal Git flow (the user can adopt them from Clair's Git panel).

"""#

  /// Skill roots of the agents Clair launches: Claude Code reads `~/.claude/skills`, Codex/OpenCode the shared `~/.agents/skills`.
  // ponytail: fixed pair; add a root when a profile's agent reads skills elsewhere.
  public static func targets(home: URL = .homeDirectory) -> [URL] {
    [".claude/skills", ".agents/skills"].map { home.appending(path: $0).appending(path: name).appending(path: "SKILL.md") }
  }

  public static func isInstalled(home: URL = .homeDirectory) -> Bool {
    targets(home: home).allSatisfy { (try? String(contentsOf: $0, encoding: .utf8)) == markdown }
  }

  public static func install(home: URL = .homeDirectory) throws {
    for url in targets(home: home) {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try markdown.write(to: url, atomically: true, encoding: .utf8)
    }
  }

  /// Removes each skill folder Clair installed; a SKILL.md the user edited is left alone.
  public static func uninstall(home: URL = .homeDirectory) throws {
    for url in targets(home: home) where (try? String(contentsOf: url, encoding: .utf8)) == markdown {
      try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
  }
}
