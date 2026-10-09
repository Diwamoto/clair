---
id: ADR-0024
title: "agent の作業中・承認待ち・完了を公式 hooks の自己申告で示す"
status: accepted
date: 2026-10-10
deciders: [Diwamoto]
related_projects: []
related_issues: []
supersedes: []
superseded_by: []
---

# ADR-0024: Agent-reported state

## Context

Agents 一覧は `running` / `attention`(未読のベル)/ `exited` しか区別できず、承認待ちで止まっている agent と
返答を終えた agent が同じ「入力待ち」に見える。herdr は画面の読み取りで `blocked` / `done` / `idle` を出すが、
Clair は agent TUI の screen scraping を対象外にしている(仕様 §2-3、§14)。オーナーは公式 hooks を使う形での
導入を選んだ(2026-10-10)。

## Decision

- agent が自分で状態を報告する command `agent.report state=working|blocked|done` を registry に置く。
  報告元の pane は IPC 層が `CLAIR_TERMINAL_KEY` から `parent` に入れたものだけを使う(`callerAsParent`)。
  表示状態しか変えないので risk は `read`、AI 可、承認なし。
- Claude Code には公式 hooks を `~/.claude/settings.json` に入れる(`ClairClaudeHooks`、設定の「連携」と palette から
  install / uninstall、既存の hooks は残す)。`UserPromptSubmit` / `PostToolUse` → working、`Notification` の
  `permission_prompt|elicitation_dialog` → blocked、`Stop` → done。Clair の terminal の外では何もしない。
- 状態の優先順位は exit > 自己申告 > 未読のベル > running。done は pane に focus すると idle になる。
  `agent.list` の status に `blocked` / `done` / `idle` を足す(既存の値は変えない)。
- 状態の報告は workspace に保存しない。報告に付いた provider の session id(`session=`、hooks が stdin の
  `session_id` から渡す)は agent の launch に記録して保存する。起動時、daemon に shell が残っていない agent pane
  だけ、その id で `resume` コマンドを使って会話を開き直す。daemon は command が変わると live shell を作り直すため、
  shell が生きている pane の command は変えない(daemon が応答するのに問い合わせが失敗した pane も変えない)。

## Consequences

- hooks を入れていない agent(Codex、OpenCode など)はこれまでどおりベルだけで判断する。Codex の `notify` や
  OpenCode の plugin による報告は、同じ `agent.report` に後から足せる。
- `PostToolUse` ごとに `clair` が 1 回起動する。体感に効くようなら working の報告を間引く。
- 自己申告は検証できない。表示と待ち合わせにだけ使い、承認や権限の判断には使わない。
