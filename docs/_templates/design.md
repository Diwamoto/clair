# Design

## Current state

現在の実装、制約、問題を、関連codeやarchitecture文書へのリンクとともに記述する。

## Proposed design

採用する構成と、requirementsをどう満たすか。

## Components and responsibilities

| Component | Responsibility | Changed interface |
|---|---|---|
| <name> | <responsibility> | <interface or none> |

## Data and control flow

順序や境界が重要な場合に記述する。単純な変更では省略可。

## Interfaces and contracts

公開API、process境界、threading、error、versioning、lifecycleなど、このproject後も守る契約。

## State, persistence, and migration

保存形式、既存dataとの互換性、migration、rollback。該当しなければ `Not applicable.` とする。

## Failure handling and recovery

想定failure、検知方法、安全な停止、retryまたはrecovery。

## Security and privacy

権限、secret、untrusted input、data exposure。該当しない場合も、その判断を短く記録する。

## Observability

diagnostic log、metric、trace、利用者向けerror。必要なものだけ記述する。

## Test strategy

unit、integration、UI、performance、manual verificationの責務分担。

## Options considered

### Option A: <name>

- Advantages:
- Disadvantages:
- Evidence:

### Option B: <name>

- Advantages:
- Disadvantages:
- Evidence:

## Decision and rationale

採用案と選定理由。不採用案を「劣る」とだけ書かず、今回のconstraintsに合わない理由を書く。独立した長期判断ならADRへリンクする。

## Risks and mitigations

| Risk | Impact | Mitigation or exit condition |
|---|---|---|
| <risk> | <impact> | <mitigation> |

## Rollout and rollback

段階導入、feature flag、migration順、rollback条件。該当しなければ `Not applicable.` とする。

## Documentation impact

- 更新するarchitecture、ADR、runbook、benchmark

## Open questions

None.
