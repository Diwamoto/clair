---
id: ADR-0027
title: "AI 向け command の承認カードを、オーナーが command ごとに外せるようにする"
status: accepted
date: 2026-11-12
deciders:
  - Daiki
related_projects: []
related_issues: []
supersedes: []
superseded_by: []
---

# ADR-0027: AI 向け command の承認カードを、オーナーが command ごとに外せるようにする

## Context

AI 向け command のうち risk が write 以上のもの（`agent.launch`、`agent.send`、`pane.close` など）は、
呼ぶたびに GUI の承認カードが必要だった。そのため、エージェントが pane を整理したり子エージェントを起動したりするたびに承認を求められ、
オーナーは負担が大きいと感じていた（2026-11-12 オーナー依頼）。

## Decision

- 設定の「連携」に「エージェントの操作を承認なしで許可」カードを置く。固定リストの command ごとにトグルを並べ、初期値はすべてオフにする。
  リストは `agent.launch`、`agent.send`、`pane.close`、`pane.move`、`pane.swap`、`tab.close`、`diff.close`、`notice.markRead`、`todo.update`。
- オンの command は、次の条件をすべて満たすときに承認カードを出さずに実行する。
  - 呼び出し元(`caller`)が Clair の terminal であること。Clair の外からの呼び出しは引き続きカードを出す。
  - runtime preflight の risk が、その command の固定 risk 以下であること。たとえば未保存の `tab.close` は destructive になるのでカードを出す。
- 設定値は `settings.set`(AI 不可)でしか変えられない。agent が自分の許可を広げることはできない。
- git 系、`file.save`、AI 不可の command は対象外。追加するときは、この ADR を改訂する。

## Consequences

- 承認なしで許可した agent は、子エージェントを起動できるし、他の pane へ入力することもできる。これはオーナーが自分で選んだ範囲のリスクとして受け入れる。
- 判定は `WorkbenchState.autoApproves` の一か所で行い、MCP と CLI の両方の gate がそこを通る。
