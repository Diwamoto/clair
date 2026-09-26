---
name: session-commit
description: Commit only the changes made in the current session, leaving pre-existing user edits in the shared worktree unstaged — even when they share a file.
---

# Session commit

The clair main worktree is shared: other sessions and the user leave
uncommitted edits. Commit exactly what *this* session changed, nothing else.

1. List what this session edited (from the conversation: every Edit/Write/sed
   you ran). If nothing, say so and stop.
2. `git status --short` and `git diff --cached --stat`. If something is already
   staged that this session did not stage, stop and ask.
3. Per file:
   - **Untracked or otherwise untouched by others** → `git add -- <path>`.
   - **File also holds someone else's edits** → stage only your hunks without
     touching the worktree: take `git show HEAD:<path>` into the scratchpad,
     apply only your change to that copy (assert the old text matches once),
     then `git update-index --cacheinfo 100644,$(git hash-object -w <copy>),<path>`.
   Never `git add -A`, `git add .`, `git stash`, `git checkout`, or `git reset --hard`.
4. `git diff --cached` — verify it contains only this session's changes.
5. Commit with an English conventional message (`fix(app): …`,
   `docs(…): …`) and the attribution trailers from the system reminder.
   Use `git commit` (no paths — paths would re-stage whole files).
6. `git status --short` to confirm the others' edits are still unstaged.
   Report the SHA in Japanese. Do not push.
