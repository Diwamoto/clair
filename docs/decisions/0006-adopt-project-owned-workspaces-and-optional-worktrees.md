---
id: ADR-0006
title: "Projectがworkspaceを所有しworktreeを任意のexecution contextにする"
status: accepted
date: 2026-08-30
deciders:
  - Daiki Iwamoto
related_projects:
  - p0022-worktree-agent-orchestration
related_issues:
  - "https://github.com/Diwamoto/clair/issues/22"
supersedes:
  - "0005-adopt-worktree-first-agent-orchestration.md"
superseded_by: []
---

# ADR-0006: Projectがworkspaceを所有しworktreeを任意のexecution contextにする

## Context

[ADR-0005](0005-adopt-worktree-first-agent-orchestration.md)はworktreeをeditor layout、terminal、agent session、review collectionの第一級所有単位とし、Project Groupが必ず一つのworktreeを指すと決定した。

Product directionの再検討により、ClairはGit agent orchestratorではなく、VS CodeとGhosttyを統合するpersonal IDEであることが明確になった。一つのProjectには複数editor、複数terminal、複数raw-terminal agentが存在する。askや調査のたびにworktreeを強制すると通常作業を妨げ、Git未初期化folderもProjectとして開けなくなる。一方、大きな変更や並列実装ではmanaged worktreeによる隔離が必要である。

## Decision drivers

- Gitの有無にかかわらずfolderをProjectとして開けること。
- Projectを切り替えるとeditor、terminal、agent、layout全体が切り替わること。
- 通常Project rootでのagent実行とmanaged worktree実行を同格に扱うこと。
- 同じworktreeで複数terminal/agentを意図的に動かせること。
- Isolated branchのreview/adoption/cleanupを安全に行えること。

## Options considered

### Option A: Worktree-first ownershipを維持する

- Advantages: Git isolationとidentity scopingが単純になる。
- Disadvantages: 非Git Projectとdirect agent workflowを不自然な例外にし、Project全体のworkspace modelと一致しない。

### Option B: Projectが全stateを所有しworktreeを意識しない

- Advantages: 通常IDEとして単純になる。
- Disadvantages: 並列agentの変更隔離、branch review、cleanup対象が曖昧になる。

### Option C: Projectがworkspaceを所有し、各terminal/agentが任意のexecution contextを参照する

- Advantages: 通常IDEとisolated agent workflowを同じProject内で扱える。Gitなしfolderも利用できる。
- Disadvantages: Project、repository、execution root、worktree、sessionのidentityを分けて管理する必要がある。

## Decision

Option Cを採用し、ADR-0005をsupersedeする。

- `Project`はlocal folderを表すstable identityであり、workspace、pane layout、sidebar state、notificationを所有する。
- `Project`は0または1つの`Repository` contextを持つ。Git未初期化folderも有効である。
- `Pane`のtabはeditor、terminal、diffを混在できる。
- `TerminalSession`と`AgentSession`は明示的なexecution rootを持つ。execution rootはProject rootまたはmanaged `Worktree`である。
- agent起動時にworktree使用有無を選ぶ。worktreeを既定または必須にしない。
- 一つのexecution rootへ複数terminal/agentをattachできる。
- Managed worktreeはProject folder外のClair local管理領域へ置く。
- GitなしProjectでは通常terminal/agentを利用できるが、worktree、branch、Git reviewは利用できない。
- Branch reviewはbaseに対する全差分を対象とし、commit済みと未commit/untrackedを分ける。
- Adoption前にcleanなcommit状態を要求し、merge commitで統合する。
- Conflictはnative merge editorまたは対象worktreeのagentで解決する。

## Rationale

Projectは利用者が「いま何を開発しているか」を表す単位であり、worktreeはそのProject内の一つのexecution choiceにすぎない。所有関係をこの順にすると、editor中心の通常開発、同じrootでの小さなagent task、worktreeを使うisolated taskを一つのworkspaceに統合できる。

Worktree identity自体は引き続きstable entityとして必要である。ただしlayout全体のroot ownershipではなく、cwd、Git state、branch review、cleanupの対象を安全に特定するために使う。

## Consequences

### Positive

- Gitなしfolderと通常Project rootでのagent利用がfirst-classになる。
- Projectを切り替えるだけで関連する全surfaceを復元できる。
- Worktreeを必要なtaskだけに使える。
- Multiple agentを同じworktreeへ意図的にattachできる。

### Negative

- Project-scoped stateとworktree-scoped stateの境界testが必要になる。
- 同じrootを共有するagent同士のfile競合をClairが防止しない。
- ADR-0005を前提にしたp0022とGit review/mobile文書を再設計する必要がある。

## Validation

- GitなしProjectを開き、複数editor/terminalを保存・復元できる。
- Git Project rootへ複数agentを直接起動できる。
- 同じProject内でmanaged worktreeを作り、複数agentをattachできる。
- Project切替中も各sessionが継続し、戻ったときに正しいlayout/cwdへ復元される。
- Branch review、merge、conflict、cleanupが別Project/worktreeへ誤適用されない。

## Revisit conditions

- Direct agent executionが実運用で許容できない頻度のdata lossや競合を起こす。
- Team/shared workspace導入によりsingle-user Project ownershipが成立しなくなる。
- Non-Git Projectの維持費が利用価値を上回る。

## References

- [Product vision](../clair-spec.md)
- [Product principles](../clair-spec.md)
- [Product scope](../clair-spec.md)
- [Superseded ADR-0005](0005-adopt-worktree-first-agent-orchestration.md)
- [PoC queue: managed worktrees and branch adoption](../clair-tasks.md#p10-managed-worktrees)
