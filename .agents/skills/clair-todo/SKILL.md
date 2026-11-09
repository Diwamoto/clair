---
name: clair-todo
description: Clair's TODO list — one Markdown file per TODO in ~/.clair/todo, shown in Clair's sidebar. Use whenever the user asks to remember, defer, or add something as a TODO ("あとで", "todoに追加", "やること"), asks what is left to do, or asks to work on / finish a TODO.
---

# Clair TODO

Each TODO is one file `~/.clair/todo/<slug>.md` (slug: short, lowercase, `-`-joined). Clair's sidebar lists them.

```markdown
---
title: Fix login redirect
priority: 1          # 1 high, 2 normal, 3 low
due: 2026-10-30      # optional, YYYY-MM-DD
done: false
---

Free-form context: why, links, the project path, what was tried, next step.
```

Use the commands (`clair todo.list` … or the `mcp__clair__todo_*` tools) rather than writing the files; they check the values and keep extra keys such as `kr:`. Edit a file by hand only when Clair is not running.

```sh
clair todo.list done=false                     # JSON: path, title, priority, due, done, extra keys; priority → due order
clair todo.add title="Fix login" priority=1 due=2026-10-30 body="context"
clair todo.update path=<path> done=true appendBody="result: shipped"   # also title / priority / due ("" clears)
clair todo.update path=<path> stage=impl lane=code agent=<terminal key>          # workflow keys: stage, lane, retry, branch, pr, agent
clair todo.update path=<path> stage=impl appendBody="- impl <terminal key> <one-line note>"   # every stage change: one history line
```

Workflow artifacts live in the Project, not in `~/.clair`, so a sandboxed child can read them: `<project root>/.clair/todo/<TODO file name without .md>/plan.md` and `review.md`. Set `project:` (Project name or path) on a staged TODO so the board knows where to look.


## Add

When the user asks for a TODO, add it right away — do not ask for confirmation. Default `priority: 2`, omit `due` unless a date was given (resolve "明日", "金曜" to a date). Put everything a later session needs into the body: the current project path, related files, the request in the user's words.

## List

`todo.list done=false` gives the open ones, sorted by priority, then due date.

## Work on one

When asked to do a TODO (or "次のtodo"), pick the requested one or the open one with the best priority / earliest due, read its file for context, `cd` to the project it names, and do the work. Add progress notes with `appendBody` as you go. When finished, `todo.update path=… done=true appendBody="<short result>"`. Do not delete files unless the user asks.
