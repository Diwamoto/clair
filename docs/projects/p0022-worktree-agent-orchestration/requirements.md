# Requirements

## Motivation

Clairが複数のcoding agentを扱うとき、repository単位だけではterminal cwd、Git index、editor state、review noteの所有範囲が曖昧になる。同じ依頼を比較するagent同士が変更を競合させず、結果を安全に採用できるlocal-first workflowが必要である。

## Goals

- repository、worktree、agent session、review collection、adoptionの関係を一意に管理する。
- 同じ依頼を複数の隔離worktreeへ展開し、Agentごとの実行と状態を比較できる。
- Claude Code等の会話を専用Agent paneへ移さず、各worktreeのterminalを実行面として維持する。
- diff commentとreview briefを、対象worktreeと送信先sessionを失わずにhandoffできる。
- adopt、merge、cleanupの危険操作で対象とdirty stateを明示する。

## Non-goals

- arbitrary TUIをscreen scrapingしてsemantic statusやapprovalの正本にしない。
- 複数人によるshared worktree、同時編集、hosted code reviewとの同期を導入しない。
- agentが確認なしにcommit、push、merge、worktree deleteを実行できるようにしない。
- #20のremote/mobile wire protocol、relay、E2EEをこのprojectで実装しない。

## User-visible behavior

- 利用者はrepository内のbase revisionを選び、名前とbranchを指定してworktreeを作成、切替、再開、削除できる。
- 利用者は一つの依頼とlaunch profileを複数worktreeへfan-outし、それぞれのterminalでAgentを観察、入力、interrupt、resumeできる。
- Activityはworking、needs input、review ready、doneの状態をworktreeごとに表示する。選択すると専用dashboardではなく対応terminalへ移動する。
- diffとreview panelは常に現在のworktreeを表示し、review briefは送信前に対象、notes、anchor、差分抜粋、destination sessionをpreviewする。
- 利用者は比較対象を選び、merge/adoptまたはcleanup前にbranch、base revision、dirty state、対象pathを確認できる。

## Requirements

### Functional

- `FR-01`: `RepositoryID`、`WorktreeID`、`AgentSessionID`、`ReviewCollectionID`を別のstable identityとして保持する。pathとbranch名をidentityとして使わない。
- `FR-02`: Project Groupはちょうど1つの`WorktreeID`を所有し、active file、terminal layout、breakpoint、Git state、review collectionをそのworktreeのIDでscopedする。
- `FR-03`: worktree createはbase revision、branch、target path、既存branch/worktree競合を検証し、成功したcanonical identityを返す。
- `FR-04`: fan-outは同じnormalized prompt、base revision、明示したlaunch profileから複数のisolated worktreeとsessionを作る。個別失敗は他のlaunchを停止させない。
- `FR-05`: agent sessionはlaunch時のworktreeにattachし、terminal cwd、session catalog、restart reattachでその関係を保持する。
- `FR-06`: Activityはworktreeごとのagent statusとunread/needs-inputを表示し、terminalへのresume、interrupt、review handoffを提供する。
- `FR-07`: Git diff、source anchor、review comment、review brief、AI destinationは同じ`WorktreeID`を参照する。異なるworktreeのstateを混在表示しない。
- `FR-08`: adoption候補はbase/head revision、変更概要、review collection、test/result statusを比較できる。merge、adopt、cleanupは個別のconfirmation operationに分ける。
- `FR-09`: worktree deletion/cleanupはuncommitted change、active session、unresolved review、未push branchを検知し、対象を明示して中止または確認を求める。
- `FR-10`: semantic agent operationは[ADR-0002](../../decisions/0002-layered-agent-remote-control.md)のcapability contractを使い、未対応agentはraw PTY workflowを維持する。

### Quality attributes

- `QR-01`: worktree切替はPTY/agent状態を再生成せず、保存済みlayoutとsession catalogから復帰する。
- `QR-02`: 同名file、同名branch、branch rename、detached HEADでもworktree間のeditor/breakpoint/review stateが混ざらない。
- `QR-03`: Git create/list/statusとsession catalog更新はUI threadをblockしない。
- `QR-04`: fan-out、adopt、cleanupの各operationはoperation ID、対象identity、結果、recovery actionを記録する。
- `QR-05`: review briefとagent handoffはユーザーがpreviewしたworktree-scoped payloadだけを送る。

## Constraints

- frontendは[ADR-0001](../../decisions/0001-adopt-swiftui-appkit-frontend.md)のSwiftUI/AppKit境界に従う。
- PTY ownershipとrestart reattachは#6の`clair-ptyhost`/session brokerを利用する。
- Git mutationとfilesystem操作はRust coreのservice境界の後ろに置き、UI stateを正本にしない。
- 初期scopeはlocal repository、single user、self-owned devicesである。

## Acceptance criteria

- `AC-01`: 同一repositoryから少なくとも2つのworktreeを作り、同じpromptを異なるagent/sessionへlaunchして各cwd、branch、layoutが分離される。
- `AC-02`: worktree切替とapp/PTY restart後、対応するeditor layout、session、Git state、breakpoint、review collectionだけが復元される。
- `AC-03`: working、needs-input、review-ready、doneのsessionをActivityで確認し、各行から正しいworktree terminalへ移動できる。
- `AC-04`: 異なるworktreeとfileを含むreview noteを作り、送信前briefで対象worktree、anchor、差分抜粋、destination sessionを確認できる。
- `AC-05`: dirty worktree、active session、unresolved review、未push branchのそれぞれでcleanup/adoptが安全に停止または確認される。
- `AC-06`: identity scoping、fan-out partial failure、restart reattach、review handoff、cleanup guardをautomated testで検証する。

## Out of scope

- GitHub/Linear/PR連携はreview projectの後続scopeとする。
- remote clientからのterminal controlは#20のlease/pairing/E2EE設計に従う。
- multi-repository taskやcloud/VM provisioningは、local modelのvalidation後に別projectで扱う。

## Assumptions

- Git worktreeがClairのlocal並列executionに必要なfilesystem隔離を提供する。
- 各agentはterminalまたは公式local interface経由で起動できる。

## Open questions

None.
