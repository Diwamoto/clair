---
project_code: p0022-worktree-agent-orchestration
title: "Optional worktree agent workflow"
status: draft
source_issue: "https://github.com/Diwamoto/clair/issues/22"
suggested_branch: "project/p0022-worktree-agent-orchestration"
created: 2026-08-29
updated: 2026-08-30
owners: []
related_adrs:
  - "../../decisions/0006-adopt-project-owned-workspaces-and-optional-worktrees.md"
  - "../../decisions/0005-adopt-worktree-first-agent-orchestration.md"
  - "../../decisions/0002-layered-agent-remote-control.md"
related_investigations: []
---

# Optional worktree agent workflow

> **Redesign required:** ADR-0006 superseded the worktree-first ownership model
> used by this bundle. `requirements.md`, `design.md`, and `plan.md` remain as
> historical draft input and are not implementation-ready.

## Outcome

利用者はProject rootまたは任意のmanaged worktreeをagent起動時に選び、同じexecution rootへ複数terminal/agentをattachできる。Managed worktreeのbranch全体をreviewし、cleanなcommit状態からmerge commitで安全に採用できる。

## Documents

- [Requirements](requirements.md)
- [Design](design.md)
- [Implementation plan](plan.md)

## Context links

- Source issue: [#22](https://github.com/Diwamoto/clair/issues/22)
- Related issues: [#6](https://github.com/Diwamoto/clair/issues/6), [#14](https://github.com/Diwamoto/clair/issues/14), [#15](https://github.com/Diwamoto/clair/issues/15), [#20](https://github.com/Diwamoto/clair/issues/20)
- Related decisions: [ADR-0006](../../decisions/0006-adopt-project-owned-workspaces-and-optional-worktrees.md), [ADR-0005 (superseded)](../../decisions/0005-adopt-worktree-first-agent-orchestration.md), [ADR-0002](../../decisions/0002-layered-agent-remote-control.md), [ADR-0003](../../decisions/0003-versioned-session-broker-protocol.md)
- Related projects: [Git review workflow](../p0014-git-review-workflow/README.md), [Mobile agent remote control](../p0020-mobile-agent-remote-control/README.md)

## Readiness

- [ ] goalsとnon-goalsがADR-0006に沿っている
- [ ] 受け入れ条件が検証可能
- [ ] component境界と主要interfaceが決まっている
- [ ] accepted ADRと矛盾しない
- [ ] materialなblocking questionがない
- [ ] 各受け入れ条件がplanとvalidationへ対応している

## Blocking questions

1. `requirements.md`、`design.md`、`plan.md`から「Project Groupは必ず1つのworktreeを所有する」という前提を除き、Project、Repository、execution root、Worktree、AgentSessionの境界をADR-0006に合わせて再設計する。
2. direct Project rootとmanaged worktreeのlaunch、branch-wide review、merge commit、conflict解決、cleanupを新しい受け入れ条件へ反映する。

## Completion summary

Not started.

## Validation evidence

Interaction Labでworktree ownership、parallel launch、review brief previewのUXを確認済み。native implementationは未着手。
