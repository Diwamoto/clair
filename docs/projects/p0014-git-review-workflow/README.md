---
project_code: p0014-git-review-workflow
title: "Git diff / blame / review workflow"
status: draft
source_issue: "https://github.com/Diwamoto/clair/issues/14"
suggested_branch: "project/p0014-git-review-workflow"
created: 2026-08-28
updated: 2026-08-30
owners: []
related_adrs:
  - "../../decisions/0001-adopt-swiftui-appkit-frontend.md"
  - "../../decisions/0006-adopt-project-owned-workspaces-and-optional-worktrees.md"
related_investigations: []
---

# Git diff / blame / review workflow

> **Redesign required:** This bundle predates the accepted product scope and
> ADR-0006. Its worktree ownership, review-comment/AI-brief emphasis, and
> adoption flow are not implementation-ready.

## Outcome

Clairで、変更差分を安全に確認・操作し、ソース行またはファイル／ディレクトリ／プロジェクト範囲に紐付くレビューコメントを集約してAIへ渡せる。ccedit V1のGit/review作業を置き換えられるnative workflowの実装契約を残す。

## Documents

- [Requirements](requirements.md)
- [Design](design.md)
- [Implementation plan](plan.md)

## Context links

- Source issue: [#14](https://github.com/Diwamoto/clair/issues/14)
- Parent issue: [#1](https://github.com/Diwamoto/clair/issues/1)
- Related decisions: [ADR-0001](../../decisions/0001-adopt-swiftui-appkit-frontend.md), [ADR-0006](../../decisions/0006-adopt-project-owned-workspaces-and-optional-worktrees.md)
- Product scope: [Git and worktree workflow](../../product/scope.md#git-and-worktree-workflow)
- Design evidence: [Clair Interaction Lab review panel](../../../prototypes/clair-interaction-lab/app/page.tsx)

## Readiness

- [ ] goalsとnon-goalsがaccepted product scopeに沿っている
- [ ] 受け入れ条件が検証可能
- [ ] component境界と主要interfaceが決まっている
- [ ] accepted ADRと矛盾しない
- [ ] materialなblocking questionがない
- [ ] 各受け入れ条件がplanとvalidationへ対応している

## Blocking questions

1. `requirements.md`、`design.md`、`plan.md`をProject-owned workspaceとoptional managed worktreeへ合わせる。
2. MVPをbranch-wide diff、commit済み/未commitの分離、merge commit、native/agent conflict resolution、cleanup confirmationへ絞る。
3. Review comment、AI brief、blame等をcutover scopeへ残すか、後続projectへ分離する。

## Completion summary

Not started. Interaction Labで、行コメント、file/directory/project scope、コメント集約、AI handoffのUX仮説を検証済み。

## Validation evidence

Interaction Lab: `npm run build` successful on 2026-08-28. Native implementation validation not run.
