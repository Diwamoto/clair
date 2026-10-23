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

## Add

When the user asks for a TODO, create the file right away — do not ask for confirmation. Default `priority: 2`, omit `due` unless a date was given (resolve "明日", "金曜" to a date). Put everything a later session needs into the body: the current project path, related files, the request in the user's words.

## List

Read the front matter of every file in `~/.clair/todo`, show open ones sorted by priority, then due date.

## Work on one

When asked to do a TODO (or "次のtodo"), pick the requested one or the open one with the best priority / earliest due, read its body for context, `cd` to the project it names, and do the work. Append progress notes to the body as you go. When finished, set `done: true` and add a short result line. Do not delete files unless the user asks.
