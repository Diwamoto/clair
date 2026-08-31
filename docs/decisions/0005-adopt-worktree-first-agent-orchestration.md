---
id: ADR-0005
title: "Agent orchestrationはworktreeを第一級の所有単位にする"
status: superseded
date: 2026-08-29
deciders:
  - Daiki Iwamoto
related_projects:
  - p0022-worktree-agent-orchestration
related_issues:
  - "https://github.com/Diwamoto/clair/issues/22"
supersedes: []
superseded_by:
  - "0006-adopt-project-owned-workspaces-and-optional-worktrees.md"
---

# ADR-0005: Agent orchestrationはworktreeを第一級の所有単位にする

## Context

ClairはClaude Code、Codex、OpenCodeなどのterminal-based agentを扱うnative macOS IDEを目指す。複数agentに同じ依頼を比較実行する場合、同じworking treeを共有すると変更、index、terminal cwd、review anchorが混ざる。単なるproject tabやbranch名だけでは、sessionの所有範囲と危険なGit操作の対象を一意にできない。

## Decision drivers

- 並列agentの変更を物理的に隔離すること
- terminal、editor layout、review collection、Git操作の対象を一意にすること
- Agent専用dashboardを作らず、terminal-firstの既存方針を保つこと
- restart、remote access、review handoffでも同じidentityを使えること

## Options considered

### Option A: repositoryごとに1つの共有working treeを使う

- Advantages: 初期実装と表示が簡単。
- Disadvantages: 並列agentが同じindexとfileを競合し、比較とcleanupの対象も曖昧になる。
- Evidence: parallel developmentでは個別checkoutが必要になる。

### Option B: branch名をproject groupのidentityとして扱う

- Advantages: Git UIへの追加が小さい。
- Disadvantages: branch rename、detached HEAD、同名branch、worktree reuseを安全に扱えず、sessionやreview anchorの安定IDにならない。
- Evidence: branchはworktreeの属性であって所有者IDではない。

### Option C: repository配下のworktreeを第一級の所有単位にする

- Advantages: filesystem root、Git state、terminal cwd、layout、agent session、review collectionを同じstable IDへ束ねられる。
- Disadvantages: worktree lifecycle、dirty cleanup、base revision固定を明示的に実装する必要がある。
- Evidence: 隔離、比較、採用の全段階で同じ対象を表示できる。

## Decision

Option Cを採用する。Clairは`Repository`、`Worktree`、`AgentSession`、`ReviewCollection`を別entityとして持ち、`Worktree`を各surfaceの所有単位にする。Project Groupは表示上のgroupであり、必ず1つのworktreeを指す。branch名とpathは属性であり、identityそのものにはしない。

## Rationale

worktreeはagentの並列実行を隔離するだけでなく、native editorの保存状態、PTYのcwd、Git diff、review handoff、後続のremote catalogを同じ対象に揃える最小の境界になる。Clairはagent conversationを専用paneへ移さず、worktreeごとのterminalを実行面として維持する。

## Consequences

### Positive

- 並列agentの結果を安全に比較し、採用対象を明示できる。
- editor breakpoint、review note、layout、sessionをworktree越しに混在させない。
- remote/mobile protocolはworktree catalogを共通のsession metadataとして利用できる。

### Negative

- worktree作成、dirty state、merge、cleanupのfailure/recoveryをfirst-classに扱う必要がある。
- 既存のproject group保存形式をworktree IDへmigrationする必要がある。

## Validation

- 1 repositoryから2つ以上のworktreeを作り、同じpromptを別agentへ送ってeditor、terminal、review stateが混ざらないことをtestする。
- branch rename、worktree delete、restart reattach、stale review anchorで安全に失敗または再解決できることを確認する。

## Revisit conditions

- Git worktreeが対象platformまたはagent workflowで必要な隔離を提供できない場合。
- single-repository local modelを超えるshared/team workspaceを導入し、別のownership modelが必要になった場合。

## References

- Issue: [#22](https://github.com/Diwamoto/clair/issues/22)
- Superseding decision: [ADR-0006](0006-adopt-project-owned-workspaces-and-optional-worktrees.md)
