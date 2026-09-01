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

- Status: `done`
- Depends on: P01。
- Outcome: native terminal surfaceで実際のzshへinputし、resize、scrollback、selectionできる。
- Scope: timeboxed libghostty embed feasibility、`clair-ptyhost` spawn/attach、raw bytes、IME/CJK/OSC smoke。
- Functional checks: shell command、resize、selection、CJK input、terminal floodのcrash smoke。
- Note: formal performance comparisonではない。libghostty integration blockerだけを早期発見する。
- Legacy issue coverage: #5、#6のlocal live-session subset。
- Validation (2026-08-31): `cargo fmt --all -- --check`、`cargo test --workspace --locked --offline`
  (clair-core 1、ptyhost unit 9、live-shell integration 4)、`cargo clippy --workspace --all-targets
  --locked --offline -- -D warnings` passed. `swift format lint --recursive --parallel --strict apple`、strict
  Swift 6 typecheck、Xcode project validation、Stable/Dev project-scoped build、Dev XCTest (19 tests)、Dev
  analyze、and `scripts/smoke-app-link.sh` passed. The live-shell tests cover shell command/resize, raw CJK and
  OSC bytes, output flood, malformed frame rejection, and child reaping; the AppKit fallback is selectable and
  scrollable in both linked app targets. The Computer Use inspector could launch and open the app shell, but
  macOS 26.6 dropped its accessibility pipe after the fixture project was opened, so click-level UI interaction
  was not completed; the exact manual checks remain in the local-development runbook.
- Durable detail: [development workspace architecture](../architecture/development-workspace.md) and
  [local development runbook](../runbooks/local-development.md) document the PTY host, versioned frame protocol,
  AppKit fallback, manual checks, and current limitations.
- Deferred: reproducible libghostty development headers/library and full terminal-grid behavior; durable
  SessionID/catalog/reattach/backpressure remains P07.

### P04 Native editor MVP

- Status: `done`
- Depends on: P02。
- Outcome: 複数fileをopen/edit/save/undoでき、agentのdisk変更を安全に反映できる。
- Scope: AppKit/TextKit-based reversible PoC、multi-file tabs、Unicode/IME、disk watcher、
  disk-wins reload、上書き前local-history recovery。
- Functional checks: save/undo、IME/emoji/combining text、external rewrite reload、unsaved buffer recovery。
- Note: up-front foundation比較benchmarkは行わず、usable PoCでblockerを観察する。
- Legacy issue coverage: #11、#12、#13のeditor vertical slice。
- Validation (2026-08-31): project-scoped `xcodebuild -project Clair.xcodeproj -scheme "Clair Dev" ... test`
  passed all 28 Swift tests, including explicit save/undo/redo, Unicode/IME, external rewrite and deletion
  recovery, save conflict refusal, per-file watcher refresh, multi-tab isolation, and non-UTF-8 rejection.
  `cargo test --workspace --locked` (14 tests), `cargo fmt --all -- --check`, `cargo clippy
  --workspace --all-targets --locked -- -D warnings`, `swift format lint --recursive --parallel --strict apple`,
  Xcode analyze, Stable/Dev project-scoped builds, Xcode project validation, FFI/app-link, bundle, and artifact
  smoke all passed. The existing `make build-*`/`make test-swift` workspace wrapper remains incompatible with
  this Xcode 26.6 environment (`Clair.xcworkspace` is not recognized as a workspace); the project-scoped
  commands are the verified equivalent.
- Durable detail: [development workspace architecture](../architecture/development-workspace.md) and
  [local development runbook](../runbooks/local-development.md) now document the native editor, disk safety,
  channel-separated recovery store, manual checks, and deferred boundaries.
- Deferred: syntax highlighting/LSP and multi-cursor editing, Git operations, and CLI/MCP adapters remain in
  downstream queue items.

### P05 Mixed panes and Project workspace persistence

- Status: `done`
- Depends on: P03、P04。
- Outcome: editor/terminal/diffを同じpane/tab modelへ置き、splitとrestart restoreが動く。
- Scope: nested split、focus/move/close/maximize/equalize、per-Project versioned snapshot、
  corrupt/missing surface fallback。Terminal transcript本文はsnapshotへ保存しない。
- Functional checks: nested layout operations、3 Project isolation、normal/abnormal restart、corrupt snapshot recovery。
- Legacy issue coverage: #34、#35。
- Validation (2026-09-01): project-scoped `xcodebuild -project Clair.xcodeproj -scheme "Clair Dev"
  -configuration Debug -derivedDataPath .build/xcode/p05-staged-tests CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO test` passed. The expanded `ProjectKernelTests` cover nested
  split/focus/move/close/maximize/equalize, editor/terminal/diff descriptors without a
  terminal transcript in the snapshot, three-Project isolation across a fresh workspace
  model, and corrupt/missing workspace-store fallback. `swift format lint --recursive
  --parallel --strict apple`, `ruby scripts/validate-xcode-project.rb Clair.xcodeproj`,
  `scripts/smoke-app-link.sh` (Stable/Dev), and Dev `xcodebuild ... analyze`
  passed. The unit restart path recreates the workspace model from the same store; the
  runbook records the disposable-fixture abnormal-restart smoke check.
- Durable detail: [development workspace architecture](../architecture/development-workspace.md) and
  [local development runbook](../runbooks/local-development.md) document the recursive pane
  model, schema-1 `workspace-v1.json` boundary, recovery behavior, and manual checks.
- Deferred: durable PTY SessionID/catalog/reattach and transcript recovery remain P07;
  Git-backed diff content and operations remain P08.

### P06 Quick Open, search, replace, and file history

- Status: `done`
- Depends on: P04。
- Outcome: Project内のfileへ素早く到達し、全文検索・置換と履歴復元ができる。
- Scope: Quick Open、text search/replace、watcher refresh、local file history browser/restore。
- Functional checks: result navigation、replace preview/apply、external change refresh、history restore。
- Legacy issue coverage: #10、#13のnavigation/history subset。
- Validation (2026-09-01): project-scoped `xcodebuild -project Clair.xcodeproj -scheme "Clair Dev"
  -configuration Debug -derivedDataPath .build/xcode/p06-tests CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO test` passed all 40 Swift tests. The suite covers deterministic Quick
  Open ranking, Unicode search locations, result navigation into the native editor, replacement
  previews that leave disk bytes unchanged, buffer-only Apply with explicit Save, active-search
  refresh after external file changes, project-scoped/newest-first history, and history restore
  into a dirty buffer. `swift format lint --recursive --parallel --strict apple`,
  `ruby scripts/validate-xcode-project.rb`, the Clair Dev build, and the Stable build passed.
- Durable detail: [development workspace architecture](../architecture/development-workspace.md) and
  [local development runbook](../runbooks/local-development.md) now document the navigation service,
  watcher coverage, buffer-only replacement boundary, Project History browser, and manual checks.
- Deferred: syntax highlighting/LSP/multi-cursor editing, durable PTY SessionID/catalog/reattach,
  Git-backed diff content and operations, and CLI/MCP adapters remain in downstream queue items.

### P07 Local session lifecycle and reattach

- Status: `done`
- Depends on: P03。
- Outcome: window closeとapp restartをまたいでlocal PTYへ再接続できる。
- Scope: stable `SessionID`、same-user bounded/versioned local IPC、catalog、cursor/gap、backpressure、reattach。
- Functional checks: app crash/restart reattach、bounded malformed frame、slow consumer、missing session recovery。
- Deferred: mobile multi-client、semantic agent adapter、relay/E2EE。
- Legacy issue coverage: #6、#18のlocal lifecycle subset。
- Validation (2026-09-01): `cargo test -p clair-ptyhost --locked` passed all 22 Rust
  tests, including the broker Unix-socket integration checks for client disconnect/reconnect,
  malformed bounded frames, and missing sessions. `cargo clippy --workspace --all-targets
  --locked`, `swift format lint --recursive --parallel --strict apple`,
  `ruby scripts/validate-xcode-project.rb`, `scripts/smoke-app-link.sh` (Stable/Dev),
  the project-scoped Clair Dev XCTest suite, the Stable build, and Dev static analysis
  passed. The Swift suite covers broker frame bounds/decoding and stable terminal
  SessionID persistence.
- Durable detail: [development workspace architecture](../architecture/development-workspace.md) and
  [local development runbook](../runbooks/local-development.md) document the detached
  same-user broker, metadata-only catalog, bounded journal/queues, gap recovery, and
  disposable app restart smoke.
- Deferred: broker-process restart cannot restore live PTYs or transcript bytes; remote
  multi-client, semantic agent adapters, and relay/E2EE remain outside this local slice.

### P08 Git working-tree loop

- Status: `done`
- Depends on: P04。
- Outcome: Projectのstatus/diffを確認し、stage/unstage/commit/branch switchできる。
- Scope: staged/unstaged/untracked separation、safe error、editor/diff navigation。
- Functional checks: fixture repositoryで一連のworking-tree操作、external Git change refresh、invalid operation error。
- Validation (2026-09-01): project-scoped macOS XCTest `ProjectGitTests` passed the
  repository fixture checks for status separation, working-tree/staged diff boundaries,
  stage/unstage/commit, untracked/rename/delete parsing, typed invalid operations,
  non-Git availability, Project command dispatch, and external index refresh. Swift
  format lint, Xcode project validation, and Stable/Dev app-link smoke also passed.
- Durable detail: [development workspace architecture](../architecture/development-workspace.md)
  and [local development runbook](../runbooks/local-development.md) document the
  Project-scoped Git service, typed commands, metadata watcher, clean branch-switch
  guard, and manual checks.
- Deferred: discard, blame, review comments, AI brief, merge/conflict adoption, managed
  worktrees, and CLI/MCP adapters.
- Legacy issue coverage: #14のdaily Git subset。

### P09 Raw agent workflow and attention

- Status: `done`
- Depends on: P05、P07。
- Outcome: Claude Code、Codex、OpenCodeをProject rootで複数起動し、terminalへrevealできる。
- Scope: launch profiles、cwd、process lifecycle、bell/exit/official hook由来Activity、history、mute、macOS notification。
- Functional checks: multiple agents、background Project継続、reveal、mute、exit/attention notification。
- Validation (2026-09-01): project-scoped full Clair Dev XCTest, Clair Dev/Stable builds,
  `swift format lint --recursive --parallel --strict apple`, Xcode project validation,
  `sh -n scripts/agent-hook.sh`, and a mode-600 JSONL hook receiver smoke passed. Rust
  `cargo test --workspace --locked` passed all workspace tests, including broker and live-shell
  integration checks.
- Durable detail: [development workspace architecture](../architecture/development-workspace.md)
  and [local development runbook](../runbooks/local-development.md) document fixed launch profiles,
  Project-root execution, shell quoting, bounded Activity/history/mute/notification behavior,
  transient hook inbox handling, and manual checks.
- Deferred: vendor-specific semantic adapters/config rewriting, CLI/MCP adapters,
  transcript persistence, and remote/E2EE delivery remain outside this local slice.
- Legacy issue coverage: #15。

### P10 Managed worktrees

- Status: `done`
- Completed: `Codex agent — P10 managed worktrees (2026-09-01)`
- Depends on: P08、P09。
- Outcome: agent起動時だけ任意のmanaged worktreeをexecution rootとして選べる。
- Scope: repository外管理root、stable `WorktreeID`、create/list/inspect、dirty/active-session guard、cleanup confirmation。
- Functional checks: direct rootとmanaged rootの並行agent、restart discovery、wrong-target/dirty cleanup refusal。
- Validation (2026-09-01): project-scoped macOS XCTest `ManagedWorktreeTests` passed all 9
  cases, including external managed roots, stable identity and restart discovery,
  missing/detached states, direct-versus-managed agent launch roots and environment,
  terminal identity persistence, catalog path-boundary rejection, dirty/active/
  wrong-target cleanup refusal, and stale HEAD fingerprint rejection. The full
  `ClairTests` suite also passed. `swift format lint --recursive --parallel --strict apple`,
  `ruby scripts/validate-xcode-project.rb`, and `git diff --check` passed.
- Durable detail: [development workspace architecture](../architecture/development-workspace.md)
  and [local development runbook](../runbooks/local-development.md) document the
  repository-external catalog/managed-root layout, stable identity propagation,
  restart discovery, launch selection, and cleanup guards.
- Deferred: branch review/adoption, merge/conflict handling, and review comments remain P11;
  CLI/MCP command surfaces remain P12/P13. Catalog/Git crash journaling and semantic
  vendor adapters are outside this local vertical slice.
- Legacy issue coverage: #22のoptional worktree subset。

### P11 Branch review and adoption

- Status: `next`
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
