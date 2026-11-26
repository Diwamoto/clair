---
name: clair-todo
description: Clair's TODO list — one Markdown file per TODO in ~/.clair/todo, shown as cards on Clair's board. Use whenever the user asks to remember, defer, or add something as a TODO ("あとで", "todoに追加", "やること"), asks what is left to do, or asks to work on / finish a TODO.
---

# Clair TODO

Each TODO is one file `~/.clair/todo/<slug>.md` (slug: short, lowercase, `-`-joined). Clair's board shows them as cards.

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
clair todo.update path=<path> project=<Project name | none>      # the Project a card belongs to ("none" = no Project, "" clears)
clair todo.update path=<path> result=ok note="<one line>"       # the card's agent reports when it finishes (result ok|failed)
```

A TODO is a card on Clair's board, and one card is one agent (#82). The owner runs a card from the board; Clair starts one interactive agent in the card's Project that takes it from investigation to a verified result and reports `result` and `note`. The board's columns are states, not stages: Inbox (no agent), running, waiting on the owner (a decision sheet or a permission prompt), done (`result=ok`) and not done (`result=failed`, or the agent stopped without reporting). Agents do not start other agents through cards. Other keys: `branch`, `pr`, `agent` (the card's terminal key), `session` (its conversation, resumed when the card is run again).


## Add

When the user asks for a TODO, add it right away — do not ask for confirmation. Default `priority: 2`, omit `due` unless a date was given (resolve "明日", "金曜" to a date). Put everything a later session needs into the body: the current project path, related files, the request in the user's words.

## List

`todo.list done=false` gives the open ones, sorted by priority, then due date.

## Work on one

When asked to do a TODO (or "次のtodo"), pick the requested one or the open one with the best priority / earliest due, read its file for context, `cd` to the project it names, and do the work. Add progress notes with `appendBody` as you go. When finished, `todo.update path=… done=true appendBody="<short result>"`. Do not delete files unless the user asks.
