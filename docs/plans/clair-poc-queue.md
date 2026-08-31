# Clair PoC feature development queue

## Purpose

このqueueはM1 Clair-on-Clair cutoverまでの実装順序と状態の正本である。GitHub issueは
discussionや外部共有が必要な場合だけ使い、通常のPoC実装では作成・更新・queryを要求しない。

一つのitemは「機能領域の文書」ではなく、利用者が確認できるvertical behaviorで終わる単位とする。
実装中に重大なproduct、security、compatibility、destructive-data、cross-component interfaceの
判断が見つかった場合だけproject bundleまたはADRへ昇格する。

## Status and working rules

- `done`: code、functional checks、durable docsが統合済み。
- `next`: dependency-readyで、次に着手するitem。
- `active`: 現在実装・検証中のitem。未完了のまま別itemへ進まない。
- `queued`: dependencyが揃えば着手できる。
- `blocked`: 追加のproduct/architecture決定または外部状態が必要なitem。
- `final-only`: dogfooding可能になるまで実行しない統合検証。

通常のitemではtargeted build、lint、unit、integration、manual functional smokeだけを行う。
Benchmark corpus、反復timing、Instruments、percentile、ccedit V1比較は行わない。Crash、data loss、
corrupt state fallback、protocol/frame boundは安全性のcorrectness testとして通常itemに含める。

## Dependency map

```text
P00 -> P01 -> {P02, P03}
P02 -> P04
{P03, P04} -> P05
P04 -> {P06, P08}
P03 -> P07
{P05, P07} -> P09
{P08, P09} -> P10 -> P11
P01 -> P12
{P04, P12} -> P13
P07 -> P14
{P06, P11, P13, P14} -> P15 -> L01
```

P02とP03、P06/P07/P08は独立agentまたは別worktreeで並列実装できる。P12のCommand Registryは
P01から最小kernelを育て、後から既存featureを別実装へ置き換えない。

## Active queue

### P00 Native Stable / Dev bootstrap

- Status: `done`
- Outcome: SwiftUI app、Rust core/ptyhost skeleton、Stable/Dev isolation、local/CI build pathがある。
- Functional checks: `make ci`とStable/Dev同時起動。
- Durable detail: [p0003](../projects/p0003-native-workspace-bootstrap/README.md)。

### P01 Project and command kernel

- Status: `done`
- Outcome: Git有無を問わずfolderをProjectとしてopen/reopenし、一つのprocessで切り替えられる。
- Scope: stable `ProjectID`、root dedupe、rename/color/reorder/close、versioned local store、
  minimal typed Command Registry、availability/error/preflight seam。
- Functional checks: Git/non-Git/temp folderを3つopen、重複rootを拒否、invalid/permission errorが他Projectを壊さない。
- Legacy issue coverage: #28、#33の最小kernel。
- Validation (2026-08-31): `make test` and `make smoke` passed (Rust 2 tests, Swift 11 tests, Stable/Dev
  FFI/link/build/bundle/artifact smoke); `make lint` passed (format, Clippy, Xcode analyze, workspace check).
  `ProjectKernelTests` also passed canonical `.`/`..` and symlink dedupe, metadata persistence, stable-ID
  reopen, and invalid/file/unreadable-root isolation.
- Durable detail: [development workspace architecture](../architecture/development-workspace.md) and
  [local development runbook](../runbooks/local-development.md) now document the Project store and recovery
  boundaries.
- Deferred: file tree/watcher, editor/terminal/pane state, Git operations, CLI/MCP adapters, and worktrees remain
  in their downstream queue items.

### P02 Workspace shell and file tree

- Status: `done`
- Depends on: P01。
- Outcome: active Projectにsidebar/file treeとeditor tab hostが表示され、folder変更が追従する。
- Scope: watcher-backed tree、expand/select/reveal、missing root state、fixture editor tab。
- Functional checks: nested tree open、external create/rename/delete refresh、Project切替でstateが混線しない。
- Legacy issue coverage: #10のfile navigation subset。
- Validation (2026-08-31): `xcodebuild -project Clair.xcodeproj -scheme "Clair Dev" -configuration Debug
  -derivedDataPath .build/xcode/tests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test` passed (15 Swift
  tests, including nested enumeration, external create/rename/delete watcher refresh, missing-root recovery,
  fixture tab selection, and Project surface isolation). `xcodebuild -project Clair.xcodeproj -scheme "Clair
  Stable" ... build`, the equivalent Dev build, and Dev `analyze` passed. `cargo test --workspace --locked`,
  `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings`, `swift format
  lint --recursive --parallel --strict apple`, Xcode project validation, FFI/app-link/bundle/artifact smoke all
  passed. The repository's `make test-swift` wrapper could not use the existing minimal `Clair.xcworkspace` with
  Xcode 26.6 (`not a workspace file`), so the equivalent project-scoped commands were used; the same wrapper
  limitation remains an existing P01 environment issue.
- Durable detail: [development workspace architecture](../architecture/development-workspace.md) and
  [local development runbook](../runbooks/local-development.md) now document the Project surface, watcher,
  fixture tab, and P02 manual checks.
- Deferred: editable editor behavior, save/undo, disk-wins reload, durable workspace persistence, and search/history
  remain in P04-P06; terminal, pane, Git, and CLI/MCP behavior remains in its downstream queue items.

### P03 Native terminal feasibility and live shell

- Status: `next`
- Depends on: P01。
- Outcome: native terminal surfaceで実際のzshへinputし、resize、scrollback、selectionできる。
- Scope: timeboxed libghostty embed feasibility、`clair-ptyhost` spawn/attach、raw bytes、IME/CJK/OSC smoke。
- Functional checks: shell command、resize、selection、CJK input、terminal floodのcrash smoke。
- Note: formal performance comparisonではない。libghostty integration blockerだけを早期発見する。
- Legacy issue coverage: #5、#6のlocal live-session subset。

### P04 Native editor MVP

- Status: `queued`
- Depends on: P02。
- Outcome: 複数fileをopen/edit/save/undoでき、agentのdisk変更を安全に反映できる。
- Scope: AppKit/TextKit-based reversible PoC、multi-file tabs、Unicode/IME、disk watcher、
  disk-wins reload、上書き前local-history recovery。
- Functional checks: save/undo、IME/emoji/combining text、external rewrite reload、unsaved buffer recovery。
- Note: up-front foundation比較benchmarkは行わず、usable PoCでblockerを観察する。
- Legacy issue coverage: #11、#12、#13のeditor vertical slice。

### P05 Mixed panes and Project workspace persistence

- Status: `queued`
- Depends on: P03、P04。
- Outcome: editor/terminal/diffを同じpane/tab modelへ置き、splitとrestart restoreが動く。
- Scope: nested split、focus/move/close/maximize/equalize、per-Project versioned snapshot、
  corrupt/missing surface fallback。Terminal transcript本文はsnapshotへ保存しない。
- Functional checks: nested layout operations、3 Project isolation、normal/abnormal restart、corrupt snapshot recovery。
- Legacy issue coverage: #34、#35。

### P06 Quick Open, search, replace, and file history

- Status: `queued`
- Depends on: P04。
- Outcome: Project内のfileへ素早く到達し、全文検索・置換と履歴復元ができる。
- Scope: Quick Open、text search/replace、watcher refresh、local file history browser/restore。
- Functional checks: result navigation、replace preview/apply、external change refresh、history restore。
- Legacy issue coverage: #10、#13のnavigation/history subset。

### P07 Local session lifecycle and reattach

- Status: `queued`
- Depends on: P03。
- Outcome: window closeとapp restartをまたいでlocal PTYへ再接続できる。
- Scope: stable `SessionID`、same-user bounded/versioned local IPC、catalog、cursor/gap、backpressure、reattach。
- Functional checks: app crash/restart reattach、bounded malformed frame、slow consumer、missing session recovery。
- Deferred: mobile multi-client、semantic agent adapter、relay/E2EE。
- Legacy issue coverage: #6、#18のlocal lifecycle subset。

### P08 Git working-tree loop

- Status: `queued`
- Depends on: P04。
- Outcome: Projectのstatus/diffを確認し、stage/unstage/commit/branch switchできる。
- Scope: staged/unstaged/untracked separation、safe error、editor/diff navigation。
- Functional checks: fixture repositoryで一連のworking-tree操作、external Git change refresh、invalid operation error。
- Deferred: blame、review comments、AI brief。
- Legacy issue coverage: #14のdaily Git subset。

### P09 Raw agent workflow and attention

- Status: `queued`
- Depends on: P05、P07。
- Outcome: Claude Code、Codex、OpenCodeをProject rootで複数起動し、terminalへrevealできる。
- Scope: launch profiles、cwd、process lifecycle、bell/exit/official hook由来Activity、history、mute、macOS notification。
- Functional checks: multiple agents、background Project継続、reveal、mute、exit/attention notification。
- Legacy issue coverage: #15。

### P10 Managed worktrees

- Status: `queued`
- Depends on: P08、P09。
- Outcome: agent起動時だけ任意のmanaged worktreeをexecution rootとして選べる。
- Scope: repository外管理root、stable `WorktreeID`、create/list/inspect、dirty/active-session guard、cleanup confirmation。
- Functional checks: direct rootとmanaged rootの並行agent、restart discovery、wrong-target/dirty cleanup refusal。
- Legacy issue coverage: #22のoptional worktree subset。

### P11 Branch review and adoption

- Status: `queued`
- Depends on: P10。
- Outcome: baseからbranch全体の成果をreviewし、clean commitからmerge commitで採用できる。
- Scope: committed/uncommitted separation、commit gate、merge、native three-way conflict surfaceまたはowning agent handoff、branch/worktree個別cleanup確認。
- Functional checks: clean adoption、dirty refusal、conflict resolution path、cleanup cancellation。
- Deferred: review comments、blame、AI brief。
- Legacy issue coverage: #14、#22のadoption subset。

### P12 Human command surfaces

- Status: `queued`
- Depends on: P01。RegistryはP01以降の各itemと一緒に拡張する。
- Outcome: Command Window、menu、configurable shortcutが同じcommand IDを実行する。
- Scope: search、availability reason、result/error display、shortcut conflict。
- Functional checks: same-command dispatch、unavailable reason、invalid/conflicting mapping。
- Legacy issue coverage: #29、#33。

### P13 CLI and MCP adapters

- Status: `queued`
- Depends on: P04、P12。
- Outcome: `clair open path:line:column`とstdio MCPがGUIと同じCommandを呼ぶ。
- Scope: warm/cold local IPC、longest-prefix Project routing、JSON error、`aiAvailable` filter、static risk、runtime preflight、GUI approval。
- Functional checks: warm/cold open、line/column routing、MCP list/call、allow/deny/unavailable matrix。
- Legacy issue coverage: #36、#37。

### P14 Release, update, and restart handoff

- Status: `queued`
- Depends on: P07。
- Outcome: signed personal buildを配布し、click update後にsessionへreattachできる。
- Scope: signing/notarization、verified feed、Stable/Dev channel、download/restart、retry/rollback。
- Functional checks: update success/failure/rollback、session handoff、channel isolation。
- Legacy issue coverage: #18。

### P15 Clair-on-Clair dogfood cutover

- Status: `queued`
- Depends on: P06、P11、P13、P14。
- Outcome: Clair StableだけでClair sourceを編集し、terminal/agentでDevをbuild・runし、Git/worktree/review loopを完結できる。
- Scope: 実地利用で発見したcutover blockerだけを修正し、cceditへ戻らず開発を継続する。
- Functional checks: real repositoryで一つのfeatureを実装、review、commit、Dev確認、adoptするend-to-end session。
- Legacy issue coverage: #19。

### L01 Final load and performance

- Status: `final-only`
- Depends on: P15。
- Outcome: 利用者と一緒にfrozen corpusで統合済みClairの負荷試験を行い、cutover blockerだけを最適化する。
- Scope: unlocked ccedit V1 capture、launch/resource、large file/tree/Git、terminal flood/input/frame、reattach/backpressure、recovery soak。
- Checks: fixed identity/environment、raw samples、summary、regression thresholds、accepted/deferred limitation list。
- Rule: P15以前のfeature itemをbenchmark不足で止めない。
- Legacy issue coverage: #4、#17。

## Deferred beyond M1

Go LSP、mobile terminal、DAP/Delve、mobile review、Dev Container、API Testerは
[roadmap](clair-v2-roadmap.md)のM2以降で扱う。Semantic agent adapters、remote multi-client protocol、
relay/E2EEもlocal terminal/session実装をblockしない。

## Quarantined legacy bundles

`p0014-git-review-workflow`、`p0020-mobile-agent-remote-control`、
`p0022-worktree-agent-orchestration`は旧ownershipまたは旧remote設計を含むdraftであり、active queueの
入力にしない。必要な機能へ到達した時に、このqueueとaccepted ADRから新しいdesignを作る。
