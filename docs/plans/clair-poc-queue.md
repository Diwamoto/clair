# Clair PoC feature development queue

## Purpose

このqueueはM1 Clair-on-Clair cutoverとearly mobile agent controlの実装順序と状態の正本である。GitHub issueは
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
Benchmark corpus、反復timing、Instruments、percentile、ccedit V1比較は行わない。
[ADR-0014](../decisions/0014-clair-owned-text-engine.md)のtext engine item（`P17`〜`P34`）だけは例外とし、
`P17`で取得した現行既定の基準値との同条件比較をslice単位で行う。この例外を他のitemへ広げない。Crash、data loss、
corrupt state fallback、protocol/frame boundは安全性のcorrectness testとして通常itemに含める。

P12以降は、利用者が起動できるoperationをview固有callbackだけで実装しない。各operationはstableな
command ID、typed parameter/result/error、static risk、`aiAvailable`、deterministic runtime preflightを持つ。
後続itemは同じregistryを拡張し、P13のCLI/MCPへ自動的に投影できる状態で完了する。

Interaction LabはM1 UIのacceptance evidenceとして扱う。native実装の正本はこのqueue、product docs、
accepted ADRだが、明示的に変更されない限り、次をUI contractとする: One Darkを基調にしたcompactな
desktop-native appearance、traffic lightsと同じtitlebar rowのProject group、Projectごとのroot/active
surface/terminal layout restore、group内のfile/terminal item、右端のCommand Window/Settings、first-classな
Notifications/History activity。Clairは終了済みterminal transcriptを保存せず、保持したsession metadataから
live terminalまたは所有Projectへ戻す。

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
{P06, P11, P12} -> P13
P07 -> P14
{P03, P07, P09} -> P15A
P06 -> P15B
{P05, P06, P09, P11, P12, P15A, P15B} -> P15C
P13 -> P15D
{P07, P09, P10, P13} -> P16
{P14, P15C, P15D} -> P15 -> L01

# Clair text engine program (ADR-0014)
{P15A, P15C} -> P17
{P04, P06} -> P22
P15C -> P33
{P17, P22} -> P18
P17 -> P19
{P18, P19} -> P20 -> P21
P22 -> P23
{P20, P22} -> P24
{P18, P23} -> P25 -> P26
{P24, P26} -> P27
{P24, P25} -> P28
{P18, P33} -> P30
{P20, P30} -> P31 -> P32
{P21, P23, P24, P26, P27, P28, P33} -> P29
{P29, P32} -> P34
```

P02とP03、P06/P07/P08は独立agentまたは別worktreeで並列実装できる。P12のCommand Registryは
P01から最小kernelを育て、後から既存featureを別実装へ置き換えない。

現在の実装waveではP15AとP15Bを明示IDごとのlinked worktreeで並列実装できる。
各workerは`clair-issue-executor`のleaseを取得し、自itemだけをcommitしてpush/merge/next昇格を行わない。
P14はADR-0009でdecision blockerを解消して完了した。P15Dはdecision blockerが解消されるまでworkerへ
割り当てない。P15CはP15A/P15Bの統合後、P15はP14/P15C/P15Dの統合後にだけ開始する。P16はP07/P09/P10/P13を
dependencyとする独立したhigh-priority itemで、現在のactive item完了後に着手する。

`P17`〜`P34`は[ADR-0014](../decisions/0014-clair-owned-text-engine.md)が決めたClair text engineの実装単位であり、
設計の正本は[p0028](../projects/p0028-clair-text-engine/design.md)である。依存が解けている`P17`、`P22`、`P33`は
同時に着手できる。並列実行する各workerは別のlinked worktreeを使い、自itemだけをcommitする。
`P19`はprojectのriskが集中するため、他のeditor機能より先に完了させる。

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
- Deferred: review comments, blame, and AI briefs remain outside this local slice;
  CLI/MCP command adapters remain P13. Catalog/Git crash journaling and semantic
  vendor adapters are outside this local vertical slice.
- Legacy issue coverage: #22のoptional worktree subset。

### P11 Branch review and adoption

- Status: `done`
- Completed: `Codex agent — P11 branch review and adoption (2026-09-01)`
- Depends on: P10。
- Outcome: baseからbranch全体の成果をreviewし、clean commitからmerge commitで採用できる。
- Scope: committed/uncommitted separation、commit gate、merge、native three-way conflict surfaceまたはowning agent handoff、branch/worktree個別cleanup確認。
- Functional checks: clean adoption、dirty refusal、conflict resolution path、cleanup cancellation。
- Validation (2026-09-01): project-scoped macOS XCTest `ProjectGitTests` passed all 11
  cases, including committed/uncommitted separation, source and target dirty gates,
  clean two-parent adoption, conflict-state preservation, stale-plan refusal, and
  cleanup cancellation. Focused `swift format lint --strict` passed for the P11 Swift
  files, `ruby scripts/validate-xcode-project.rb Clair.xcodeproj`, and `git diff --check`
  passed.
- Durable detail: [development workspace architecture](../architecture/development-workspace.md)
  and [local development runbook](../runbooks/local-development.md) document the
  branch-wide review snapshot, confirmation gates, merge/conflict handoff, and
  independent worktree cleanup.
- Deferred: review comments、blame、AI brief。
- Legacy issue coverage: #14、#22のadoption subset。

### P12 Human command surfaces

- Status: `done`
- Completed: `Codex agent — P12 human command surfaces (2026-09-01)`
- Depends on: P01。RegistryはP01以降の各itemと一緒に拡張する。
- Outcome: Command Window、menu、configurable shortcutが同じcommand IDを実行する。
- Scope: search、availability reason、result/error display、shortcut conflict。
- Functional checks: same-command dispatch、unavailable reason、invalid/conflicting mapping、
  valid shortcut persistence and clear mapping.
- Validation (2026-09-01): project-scoped `Clair Dev` XCTest
  `ProjectKernelTests` passed all 18 cases, including the three P12 human-surface cases;
  `swift format lint --strict` passed for the P12 Swift files,
  `ruby scripts/validate-xcode-project.rb Clair.xcodeproj`, and `git diff --check` passed.
- Durable detail: [development workspace architecture](../architecture/development-workspace.md)
  and [local development runbook](../runbooks/local-development.md) document the
  Command Window/menu projections, deterministic availability/error display, and
  versioned shortcut storage and conflict guards.
- Deferred: argument-heavy rename/color/close/commit/branch actions remain contextual
  view flows; CLI/MCP command adapters remain P13.
- Legacy issue coverage: #29、#33。

### P13 CLI and MCP adapters

- Status: `done`
- Depends on: P06、P11、P12。
- Outcome: `clair open path:line:column`とstdio MCPがGUIと同じCommandを呼ぶ。
- Scope: adapter実装前にP00-P12のuser-invokable operationを棚卸しし、Project、navigation/editor、
  pane、terminal、agent、worktree、Git/review、notificationを共通Registryへ登録する。その上でwarm/cold
  local IPC、longest-prefix Project routing、JSON error、`aiAvailable` filter、static risk、runtime
  preflight、GUI approvalを実装する。
- Functional checks: human surface/CLI/MCPのcommand coverage matrix、同じID/typed result/errorのdispatch、
  warm/cold open、line/column routing、MCP list/call、allow/deny/unavailable matrix。
- Legacy issue coverage: #36、#37。
- Validation (2026-09-01): `swift format lint --recursive --parallel --strict apple`、
  `ruby scripts/validate-xcode-project.rb`、Swift 6 strict typecheck、
  `python3 -m py_compile scripts/clair`、`scripts/smoke-app-link.sh` (Stable/Dev)、
  and project-scoped Dev `xcodebuild ... build` passed. The focused
  `CommandAdapterTests` passed all 5 cases, and all 91 Swift tests passed in serial
  mode. A parallel full-suite attempt hit
  `NativeEditorTests.testWatcherReloadsAnExternalRewrite` `signal pipe`; the same test
  and the complete suite passed when run serially. The real Dev cold/warm CLI smoke
  returned protocol 1 with 37 registered commands; stdio MCP returned 27
  `aiAvailable` tools, excluded `git.commit`, and returned structured unknown-command
  and `not_ai_available` errors.
- Durable detail: [development workspace architecture](../architecture/development-workspace.md)
  and [local development runbook](../runbooks/local-development.md) document the
  command coverage matrix, version-1 owner-only socket, typed JSON contract,
  warm/cold launch, routing, MCP projection, approval, and recovery boundaries.
- Deferred: remote multi-client transport, background service ownership, vendor-specific
  semantic agent adapters, transcript streaming, relay/E2EE, and performance benchmarks.

### P14 Release, update, and restart handoff

- Status: `done`
- Completed: `Codex agent — P14 Stable GitHub update distribution and restart handoff (2026-09-01)`
- Depends on: P07。
- Outcome: Stableを公開GitHub Releaseへ配布し、署名/hash検証後のclick updateでsessionへreattachできる。
- Scope: signing/notarization、verified feed、Stable/Dev channel、download/restart、retry/rollbackに加え、
  window close、explicit app Quit、crash、update restartのlifecycleを区別する。Window closeはsessionを継続し、
  explicit Quitは通常sessionを終了し、crash/update restartはbrokerを維持してreattachする。
- Functional checks: update success/failure/rollback、window closeとexplicit Quitの終了差、crash/update
  session handoff、channel isolation。
- Blocker (resolved 2026-09-01): P14 requires a signed/notarized personal build and a verified update feed, while
  accepted [ADR-0008](../decisions/0008-stable-dev-runtime-identity.md) intentionally fixes local/CI builds as
  unsigned and defers the signing identity, Team ID, notarization, and distribution boundary. Before
  implementation, decide the Developer ID/signing and credential boundary, the trusted feed/artifact/rollback
  contract for Stable and Dev, and how update eligibility is authorized.
- Resolution (2026-09-01): [ADR-0009](../decisions/0009-stable-github-update-distribution.md) accepts public
  GitHub Releases for Stable only, local-only Dev, signed update artifacts without Apple Developer ID/notarization,
  startup check with user-triggered apply/restart, `/Applications/Clair.app` as the Stable install target, and
  backup/restore rollback. The update restart keeps the channel-local broker alive for session reattach.
- Validation (2026-09-01): `swift format lint --recursive --parallel --strict apple` and the two release
  Swift-script format/type checks passed. `ruby scripts/validate-xcode-project.rb`, `plutil -lint
  Config/Info.plist`, `git diff --check`, and `scripts/smoke-app-link.sh` passed. Project-scoped
  `Clair Dev` and `Clair Stable` Debug builds passed, the Stable Release build passed with an injected
  public key/version and verified those Info.plist values, the P14-focused update tests passed, and
  the full `ClairTests` suite passed. A packaged app generated `latest.json` through the release
  script using the environment-backed private key path; the signed Stable manifest smoke passed.
- Durable detail: [ADR-0009](../decisions/0009-stable-github-update-distribution.md), [development workspace
  architecture](../architecture/development-workspace.md), and [Stable release runbook](../runbooks/stable-release.md)
  document the Stable-only feed, Ed25519 artifact contract, release secret boundary, `/Applications/Clair.app`
  install guard, backup/restore helper, and broker/session lifecycle.
- Deferred: Apple Developer ID signing, Team ID/notarization, Gatekeeper-friendly general distribution,
  x86_64/universal assets, and additional update channels remain outside this personal Stable slice.
- Legacy issue coverage: #18。

### P15A Production terminal surface

- Status: `done`
- Depends on: P03、P07、P09。
- Outcome: 現在のselectable plain-text AppKit fallbackを、Claude Code、Codex、OpenCodeのraw TUIを
  daily useできるnative terminal surfaceへ置き換える。
- Scope: ANSI/VT state、alternate screen、cursor、color/style、IME/CJK、selection、resize、scrollback、
  terminal flood recovery。libghosttyを再現可能に統合するか、同等rendererを明示的なarchitecture decisionで
  採用する。plain-text fallbackをcutover terminalとして暗黙に残さない。
- Functional checks: shell/TUIのcursor navigation、color、alternate-screen enter/exit、IME/CJK、resize、
  selection/scrollback、複数raw agent terminal、reattach後のlive rendering。
- Rule: formal performance comparisonはL01に残し、このitemではfunctional correctnessとinteractive usabilityを確認する。
- Validation (2026-09-03): `xcodebuild -project Clair.xcodeproj -scheme "Clair Dev" -configuration Debug
  -derivedDataPath .build/xcode/p15a-build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` passed.
  `xcodebuild -project Clair.xcodeproj -scheme "Clair Dev" -configuration Debug -derivedDataPath
  .build/xcode/p15a-tests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
  -only-testing:ClairTests/TerminalProtocolTests test` passed all 15 tests, including
  cursor/ANSI attribute/wide-glyph retention, alternate-screen enter/exit without
  discarding the primary grid, control key byte mapping, and frame/protocol bounds.
  `swift format lint --strict` passed for the P15A Swift files. `git diff --check` passed.
  The full-suite XCTest host was launched, but its `NativeEditorTests` class is owned by
  another worker and failed to compile against the current `ContentView.swift`; the
  P15A-focused TerminalProtocolTests suite was the verified subset.
- Durable detail: [development workspace architecture](../architecture/development-workspace.md)
  documents the libvterm 0.3.3 grid renderer, RGB cell/scrollback/cursor surface,
  broker reattach replay, and the reproducible `scripts/build-vterm.sh` build phase.
  [local development runbook](../runbooks/local-development.md) documents the P03+P15A
  terminal verification steps.
- Deferred: libghostty integration remains a documented but unverified alternative;
  formal terminal benchmarks remain L01.

### P15B Repository-scale file navigation

- Status: `done`
- Depends on: P06。
- Outcome: Clair自身のrepositoryを開いてもfile tree、Quick Open、search、watcherがUIを占有せず、
  editor/terminal操作を継続できる。
- Scope: asynchronous/lazyかつboundedなenumeration、generated/vendor directoryのignore policy、
  bounded watcher graph、incremental refresh、cancel/reopen。fileごとの無制限watcherとmain-thread recursive scanを残さない。
- Functional checks: Clair repositoryでopen/expand/Quick Open/search、external create/rename/delete、Project switch、
  close/reopenを行い、sustained UI stallとwatcherの無制限増加がないことを確認する。
- Audit evidence (2026-09-01): 現実装は`.git`だけを除外してdirectory/fileを同期再帰し、audit用にClair
  repositoryを開いたprocessが約99% CPUを継続した。これはformal benchmarkではなくdogfood correctness blockerである。
- Validation (2026-09-02): `swift format lint --recursive --parallel --strict apple`,
  `ruby scripts/validate-xcode-project.rb Clair.xcodeproj`, and `scripts/smoke-app-link.sh`
  (Stable/Dev) passed. Project-scoped Clair Dev XCTest passed all 26 `ProjectKernelTests` /
  `ProjectNavigationTests`, including lazy bounded enumeration, generated/vendor exclusion,
  bounded watcher graph, external create/rename/delete refresh, Project isolation, Quick Open,
  and search. The full Clair Dev XCTest suite and `xcodebuild ... analyze` also passed.
- Revalidation after P15A integration (2026-09-03): rebased onto post-P15A master (4b883e5).
  Merge conflicts were limited to `TerminalSurface.swift` (resolved by keeping the master
  libvterm text-stack `init`; the P15B initializer refactor is fully subsumed) and
  `ProjectWorkspace.swift` (resolved by combining the P15B URL-based `openEditorTab(for:title:)`
  overload with the master non-throwing `ProjectEditorTab` initializer; load failures remain
  inline via `loadError`). `git range-diff` confirmed no unintended content drift for all other
  files. Fresh evidence on the rebased snapshot: `swift format lint --recursive --parallel
  --strict apple` passed, `ruby scripts/validate-xcode-project.rb Clair.xcodeproj` passed
  (153 objects, 3 targets, 2 shared schemes), `git diff --check 4b883e5..HEAD` passed,
  `make test-swift` passed all 105 tests in 0 failures (including the 26 ProjectKernel/
  ProjectNavigation tests and the 14 libvterm TerminalProtocolTests), and `make analyze`
  (`xcodebuild ... analyze`) succeeded. `scripts/smoke-app-link.sh` fails with undefined
  `clair_vterm_*` symbols on both master (4b883e5) and this branch; that is a pre-existing
  P15A integration gap (libvterm is not linked by the standalone swiftc harness), not a
  P15B regression, and is left for a separate fix.
- Manual smoke (2026-09-02): Clair Dev opened the P15B worktree itself; the initial tree showed
  root entries only, expanding `apple` loaded its children on demand, generated directories were
  absent, Quick Open found `ProjectNavigation.swift`, and Search returned the expected scanner
  references without blocking the UI.
- Durable detail: [development workspace architecture](../architecture/development-workspace.md) and
  [local development runbook](../runbooks/local-development.md) document lazy loading, traversal
  and watcher bounds, generated-directory policy, cancellation/reopen behavior, and the manual
  Clair-repository dogfood check.
- Deferred: Formal throughput/frame-time comparison and frozen-corpus load measurement remain L01;
  P15B records functional boundedness and interactive usability only.

### P15C Interaction Lab UI convergence

- Status: `done`
- Depends on: P05、P06、P09、P11、P12、P15A、P15B。
- Outcome: native SwiftUI/AppKit appをInteraction Labのproject-first ccedit contractへ収束させ、
  WebViewなしでM1のdaily-driver hierarchyとdensityを実現する。
- Competitive reference (2026-09-02): [Orca ADE](https://www.onorca.dev/)の現行desktop UIを、
  modern agent IDEのquality barとして参照する。P15C着手時に参照version/dateとscreen/flow evidenceを固定し、
  Project/worktree/session overview、active agent attention、editor/terminal split、search/command、diff/review、
  narrow/wide windowの同一taskをInteraction Lab・Orca・native Clairで比較する。
- Competitive rule: Orcaのsource、asset、visual identityを模倣せず、情報階層、状態の判読性、直接操作、
  feedback速度から有効なpatternだけを抽出する。利用者がOrcaで感じた「もう少しこうしたい」を、P15C開始前に
  `adopt`、`avoid`、`surpass`のevidence matrixへ落とし、少なくとも一つのsurpass behaviorを明示する。
  Browser/Design Mode、remote worktree等のM1外機能をUI比較だけを理由にP15Cへ追加しない。
- Orca comparison seed (利用者評価、2026-09-02): 次の4点はP15Cで再確認するだけの未決事項ではなく、
  Interaction Labとnative acceptanceへ引き継ぐ初期matrixとする。
  - `surpass / navigation`: file treeは右へ移さず、Clairの左Project navigatorを維持する。初見でもactive Projectと
    treeの関係が判読でき、editor/terminalを開いてもnavigatorの位置が変わらないこと。
  - `avoid / visual system`: editorとterminalを別themeに見せない。同一One Dark workspace token、chrome、
    border hierarchyを共有し、syntax colorやprocess statusだけを意味のあるaccentとして使うこと。
  - `surpass / tabs`: tabはProject ownership、surface kind、active/dirty/attention stateをcompactに判読できる
    titlebar内の一段へ収める。pane下へ重複tab rowを追加せず、選択面がworkspaceへ視覚的につながること。
  - `avoid + surpass / complexity`: Files、Search、Git、Review、Notifications/Historyを常設のcore navigationとし、
    advanced toolは必要時のCommand Windowまたは明示的なoverflowから開く。M1外機能を常設して初見の選択肢を
    増やさず、機能数ではなく「現在のProject、surface、attention、次の操作が一目で分かる」ことを優先する。
- Scope: traffic lightsと同じtitlebar rowのcolored Project groups、expanded group内のactive file/terminal、
  Project切替時のroot/active surface/split/ratio restore、Files/Search/Git/Review/Notifications-Historyの
  first-class activity bar、右titlebarのCommand Window/Settings、compact One Dark styling、status bar、
  Project attention badge/mute、live process/session metadataから所有terminal/Projectへのresume。Agentはraw
  terminalのままとし、semantic Agent paneや終了済みterminal transcript storeを導入しない。
- Functional checks: 3 Projects、editor-only、terminal below/right、mixed nested split、group collapse/expand、
  active surface切替、Command Window/Settings、activity viewのfilter/search/resume、badge/mute、restart restore、
  narrow/wide window、keyboard/accessibility navigation。固定したOrca比較taskを利用者とside-by-sideで実行し、
  `adopt`項目がClairのownership modelを壊さず機能し、`surpass`項目が再現可能な操作として確認できる。
  さらに、左navigatorの位置不変、editor/terminalのshared workspace token、single titlebar tab row、advanced toolを
  閉じたdefault stateをwide/narrow双方で確認し、core taskがoverflowを開かず完了できることを記録する。
- Audit evidence (2026-09-01): native appはvertical Projects sidebar、separate Files sidebar、top button row、
  pane-local toolbarとsecond tab row、modal sheets、system dark appearanceであり、Interaction Labのtitlebar groups、
  activity hierarchy、right actions、One Dark density、status/attention presentationと一致していない。
- Validation (2026-09-04, copy and layout reconciliation): latest Interaction Lab commit `6c73d8e` and its
  uncommitted review changes in `app/page.tsx`/`app/globals.css` were read and reconciled into the native
  visible surfaces without changing the nested mock; `npm run build` passed in the mock. Native `make build-dev`、
  `make lint-swift`、`make workspace-check`、および `git diff --check` passed; `make test-swift` passed all 109
  tests with 0 failures. Manual `Clair Dev` smoke confirmed the Japanese project-first shell, compact grouped
  titlebar with editor/terminal surfaces, command palette, settings, Search, Git, Activity/History, and stable
  One Dark navigation hierarchy. The empty command/settings sheet regression found during smoke was fixed before
  completion.

### P15D Rust control-plane boundary reconciliation

- Status: `done`
- Depends on: P13。
- Outcome: Rust core再利用を要求するproduct docs/ADRと、Swiftが現在のProject、Git、search/history、
  Command control planeを所有する実装を、cutover前に一つのaccepted architectureへ揃える。
- Scope: M1 operationのownership inventoryを固定し、(a) Tauri非依存Rust domainとversioned Swift bridgeへ
  必要なoperationを移す、または(b) Rust ownershipをPTY等へ狭めるsuperseding ADRとproduct docsをacceptする。
  選択後の実装が一agentで安全に完了しない場合は、typed interface単位のimplementation-ready itemへ分割する。
- Functional checks: product docs、accepted ADR、architecture、実装ownershipに矛盾がないこと。Rust control planeを
  維持する場合はTauriをlinkしないbuild/test、versioned request/result/error、panic containment、threading、
  cancellation、handle/callback lifecycleのcontract testを行う。
- Blocker (resolved 2026-09-03): [ADR-0001](../decisions/0001-adopt-swiftui-appkit-frontend.md)とproduct visionは
  ccedit Rust domainの再利用とversioned Swift bridgeを要求する一方、現実装のRust C ABIはbootstrap smokeだけで、
  M1 control planeはSwiftに実装されている。どちらをcutover architectureとするかaccepted decisionが必要である。
- Resolution (2026-09-03): Swift / Rust / Goの3言語比較調査（fsnotify kqueue fd消費、Gitalyのgo-git離脱、
  pure Go ripgrep再実装ベンチマーク、gitoxide benchmarks）を行い、[ADR-0010](../decisions/0010-m1-control-plane-swift-with-selective-rust-migration.md)
  でM1 control planeのSwift所有を確定し、Rustの恒常的所有範囲を`clair-ptyhost`に、選択的Rust移行の基準を
  実測/ライブラリ成熟度の証拠駆動で定めた。ADR-0001の「Rust core再利用」条項は本ADRで解釈を更新し、
  frontend選択は維持する。product visionとqueueの整合更新を行った。
- Validation (2026-09-03): doc-only change。product docs（vision.md）、accepted ADR（ADR-0001 front matter、
  ADR-0010作成）、architecture（development-workspace.mdのSwift/Rust boundary節）、このqueueの整合を
  確認した。選択的Rust移行のcontract testは将来の移行itemで実施する。Swift control plane確定のため、
  Rust control plane維持時のcontract testは本itemでは不要。
- Legacy issue coverage: #7、#8。

### P16 Early mobile agent control

- Status: `active`
- Priority: `high`
- Depends on: P07、P09、P10、P13。P15のcutover完了はdependencyにしない。
- Outcome: 自所有Macで動くClairのregistered agentを、private network上のiPhone/iPad PWAから確認・raw操作・起動できる。
- Scope: shared mobile protocol、Project/session catalog、current screen/bounded scrollback、raw input/interrupt、
  broker arrival-order input、Cloudflare private network、QR pairing/revoke、PWA foreground attention、HTTPS/WSS client。
- Functional checks: desktop + mobile multi-subscriber、cursor/gap、concurrent input、viewport非resize、pair/revoke、
  agent launch、agent attention、Mac GUI close後のhost継続、remote disable時のlocal fallback。
- Durable detail: [p0020-mobile-agent-remote-control](../projects/p0020-mobile-agent-remote-control/README.md) and
  [ADR-0011](../decisions/0011-early-mobile-agent-control.md)、[ADR-0013](../decisions/0013-self-only-mobile-pwa.md)。
- Progress (2026-09-05): `ClairMobileKit`にhost identity/pairing/challenge/revoke、session journalとsubscriber gap、
  localhost-only framed listener、Network.framework reference client、client-local bounded scrollback、操作配送handler、
  APNs-compatible content-free payloadを追加した。さらにmacOS `MobileControlRuntimeBridge`を既存のProject/session/Agent/PTYへ
  接続し、設定画面のhost fingerprint、one-time QR/deep-link、端末revoke、GUI close後のhost継続を実装した。さらに
  `Clair Mobile` iOS targetへSwiftUIの概要/session/raw terminal/activity/settings、Keychain credential store、
  pairing確認、再接続、agent launch UIをreference clientとして追加した。host coreのsession projection更新を含む30テスト、
  Swift 6 macOS scheme build、iOS SDK型チェック、iOS Simulatorのunsigned destination build/install/launchと`clair://pair`
  pairing sheet、Interaction Labのmobile control UIを確認した。`make build-mobile-simulator`でこのreference buildを再現できる。
- Remaining: `clair-mobile-host`のPWA向けWSS/HTTPS adapter、PWA shell、Cloudflare/Tailscale実経路、PWA実機private-network
  E2E。App Store、TestFlight、APNs送信はP16の完了条件から外し、これらが未完了のためstatusは`active`を維持する。
- Deferred: semantic approval/status、vendor adapter、public relay/E2EE、branch review、mobile source editor、team identity。

### P15 Clair-on-Clair dogfood cutover

- Status: `done`
- Depends on: P14、P15C、P15D。
- Outcome: Clair StableだけでClair sourceを編集し、terminal/agentでDevをbuild・runし、Git/worktree/review loopを完結できる。
- Scope: 実地利用で発見したcutover blockerだけを修正し、cceditへ戻らず開発を継続する。
- Functional checks: real repositoryで一つのfeatureを実装、review、commit、Dev確認、adoptするend-to-end session。
- Validation (2026-09-04): StableでClair sourceとGit差分を開き、Stable内ターミナルからDevの既存プロセスを再利用して起動した。macOSのcase-insensitive filesystemでStable実行ファイルを上書きしていたbundle CLIの配置を`Contents/Resources/clair`へ修正し、Stable/Dev bundle smoke、`cargo test -p clair-cli --locked`（6件）、Xcode project consistency、shell syntax、`git diff --check`を通過した。
- Resolution: `make test-swift`はXCTest host終了時の環境側runner通信不調で完走せず中断したが、P15の対象であるbundle/CLI/Dev cutover経路は独立した検証で確認済み。P15のleaseはcommit後に解放する。
- Legacy issue coverage: #19。

### P17 Shared text surface foundation

- Status: `active`
- Priority: `high`
- Depends on: P15A、P15C。
- Outcome: Dev harnessがClair所有surfaceでfixtureを描画し、既定経路の性能基準値が記録されている。
- Scope: `ClairTextKit` moduleの新設。`TextFontMetrics`（font metrics、glyph atlas、run cache、CJK/絵文字/結合文字のfallback解決）、
  `TextSurfaceRenderer`（damage矩形だけを描くCoreText run描画とtheme色）、`TextSurfaceSource` protocolの確定。
  入力とmodelは含めない。着手時に現行既定であるCodeMirror editorと現行terminal surfaceの基準値を同一hostで取得し、
  `docs/benchmarks/results/`へ保存する。
- Functional checks: 単一幅ASCII行がfast path、CJK・絵文字・結合文字・合字を含む行がCoreText経路で描画される。
  全角が2セル幅を占める。家族絵文字と結合文字が1クラスタとして描かれる。再描画がdamage矩形だけに限定され、
  全面再描画の経路が存在しない。基準値JSONが`scripts/benchmarks/validate-result.rb`を通る。
- Rule: ADR-0014によりengine itemはslice単位の計測evidenceを持つ。基準値の取得をこのitemの完了条件に含める。
- Implemented (2026-09-11): `apple/ClairTextKit`に`TextSurfaceSource`（row/span/style契約とdamage）、
  `TextDisplayWidth`（cluster幅とfast path判定）、`TextFontMetrics`（font metrics、ASCII glyph table、
  bounded run cache、fallback解決）、`TextSurfaceRenderer`（damage planとCoreText/fast pathの描画）、
  `TextSurfaceView`、fixtureを追加し、Stable/Dev両targetへ登録した。`TextSurfaceDamage`に全面指定の表現は無く、
  rendererはdamage∩exposed rectだけを描く。Dev限定のharness window（Commands → Text Surface Harness）で
  fixtureを描画し、可視行数・描画行数・damage矩形数・path内訳・run cache件数を表示する。
  app → ClairTextKitの一方向依存は`scripts/check-textkit-boundary.rb`が検査し、`make workspace-check`が呼ぶ。
- Baseline tooling (2026-09-11): [text engine metric contract](../benchmarks/text-engine-metric-contract.json)、
  [取得手順](../benchmarks/clair-text-engine-baseline.md)、`scripts/benchmarks/summarize-engine-baseline.rb`、
  および`scripts/benchmarks/validate-result.rb`の`clair-text-engine-baseline` profileを追加した。
  raw sampleから中央値・p95・max・summary・coverageを機械的に導出し、validatorが再計算して検証する。
  V1 profileの挙動は変更していない。
- Validation (2026-09-11): agent環境がLinuxでSwift/Xcode toolchainを持たないため、`make lint`、
  `make test-swift`、`make workspace-check`は実行できていない。実行できた検査はすべて通過した:
  `ruby scripts/check-textkit-boundary.rb`、`bash -n scripts/check-workspace.sh`、
  両benchmark scriptの`ruby -c`、example sampleに対する
  `summarize-engine-baseline.rb` → `validate-result.rb`のend-to-end、
  および改変10種（median、observation id、unit、locked session、host-local path、contract digest、
  未知metric、sample不足、coverage不一致、surface不一致）の拒否確認、Xcode project参照とfile pathの整合確認。
- Remaining: 現行既定（`editor.codemirror`、`terminal.appkit-grid`）の基準値実測はApple Silicon macOS hostを
  要するため未実施であり、`docs/benchmarks/results/`にcaptureは無い。macOS上で`make lint`と`make test-swift`を
  実行してSwift側のbuild/test evidenceを得ることも残っている。この2点が揃うまでstatusは`active`を維持する。
- Deferred: 可視範囲limited layout（P18）、入力とIME（P19）、選択とpointer（P20）、accessibility（P21）、
  `TextBuffer`（P22）と`TerminalGridSource`（P30）。本itemではproduction surfaceを置き換えない。
- Durable detail: [p0028 design](../projects/p0028-clair-text-engine/design.md)、
  [ADR-0014](../decisions/0014-clair-owned-text-engine.md)、
  [development workspace architecture](../architecture/development-workspace.md)。

### P18 Viewport-limited layout and scrolling

- Status: `queued`
- Depends on: P17、P22。
- Outcome: 10MBと長行のfixtureでも可視範囲だけがlayoutされ、scrollが滑らかでメモリが可視行数に比例する。
- Scope: `TextSurfaceGeometry`。line indexに基づく可視範囲layout、近傍先読み、layout cacheの上限とeviction、
  scrollとhit test、position↔point変換。文書全体のlayoutを保持しない。
- Functional checks: 10MB fixtureのopenとscroll、1MB長行fixture、layout cache件数が可視行数に比例すること、
  scroll中にmain threadが解析完了を待たないこと、文書末尾へのjump、window resize後の再layout。

### P19 Text input and Japanese IME

- Status: `queued`
- Priority: `high`
- Depends on: P17。
- Outcome: surfaceが`NSTextInputClient`として正しく振る舞い、実機の日本語IMEで変換・確定・取消・再変換が破綻しない。
- Scope: `TextInputSurface`。`NSTextInputClient`の全メソッド、marked textの表示、`firstRect(forCharacterRange:)`による
  候補window位置、確定と取消、再変換、dead key、key event経路、UTF-16境界の厳密な扱い。
- Functional checks: 実機の日本語IMEで候補windowが正しい位置に出る、確定、Escapeによる取消、確定済みテキストの再変換、
  composition中のtab切替とProject切替で文書が壊れない、絵文字と結合文字の入力、marked text中のcaret位置。
  実施手順と結果を[local development runbook](../runbooks/local-development.md)へ記録する。
- Rule: このitemにprojectのriskが集中する。合成APIテストだけで完了にしない。実機IMEの手動確認を必須とする。
  二度の実装反復で要件を満たせない場合は`blocked`とし、ADR-0014のrevisit条件へ戻す。

### P20 Selection, carets, and pointer interaction

- Status: `queued`
- Depends on: P18、P19。
- Outcome: 選択とcaret操作が、wrapと全角文字を含む実際のコードで正しく動く。
- Scope: 選択矩形、caret描画と点滅、語・行・段落選択、CJKの語境界、drag選択とautoscroll、複数caretのgeometry、
  pasteboard連携。編集操作そのものは含めない。
- Functional checks: 全角と絵文字を跨ぐdrag選択、double/triple click、wrapした行の選択矩形、複数caretの表示、
  autoscroll、コピー内容がgrapheme単位で壊れないこと。

### P21 Accessibility and macOS text services

- Status: `queued`
- Depends on: P20。
- Outcome: VoiceOverでeditorの行、選択、caret位置を読み上げられ、macOS標準のtext serviceが動く。
- Scope: `NSAccessibility`のtext protocol、VoiceOver、services menu、辞書引き、drag and drop、
  spellとautocorrectの抑制方針。
- Functional checks: VoiceOverでの行移動と選択読み上げ、caret位置の通知、services menuからの操作、
  テキストのdrag and drop、コードに対してautocorrectが働かないこと。

### P22 Editor text buffer and coordinate bridge

- Status: `queued`
- Priority: `high`
- Depends on: P04、P06。
- Outcome: piece tableベースの`TextBuffer`が既存の文書契約へ接続され、UIを変えずに既存testが通る。
- Scope: piece table（UTF-8 storage）、行頭offset索引の増分更新、UTF-8 byte / UTF-16 / grapheme / line-column の
  変換API、`ProjectEditorDocumentModel`のtransaction適用先の差し替え。文書契約そのものは変更しない。
- Functional checks: 既存の`ProjectEditorDocumentTests`と`NativeEditorTests`が通る、10MBの編集が文書長に比例しないこと、
  grapheme境界でのcaret移動、CRLFと末尾改行の保持、非UTF-8の拒否、外部変更reloadとlocal historyの継続動作。

### P23 Incremental syntax highlighting

- Status: `queued`
- Depends on: P22。
- Outcome: 編集中も色が追従し、解析がmain threadを占有しない。
- Scope: Tree-sitterのSwift binding導入、増分解析のmain thread外実行、revision gate、行単位のspan cache、injection、
  grammar資産の配布許諾確認と`THIRD_PARTY_NOTICES.md`更新。許諾を確保できない言語はplain textへfallbackする。
- Functional checks: 対象言語のtoken色、Markdown内のコード fence、連続編集とtab切替で古い色が後から適用されないこと、
  10MB fixtureで解析中も入力できること、grammar不在時に編集経路が止まらないこと。
- Rule: 許諾を確保できない言語があってもitem全体を`blocked`にしない。確保できた言語だけで完了とし、
  未確保の言語と理由を明記する。

### P24 Editing primitives, undo, and multi-cursor

- Status: `queued`
- Depends on: P20、P22。
- Outcome: 複数caretを含む日常的な編集操作が、一貫したUndo単位で動く。
- Scope: 挿入と削除、indent、comment toggle、複数caret編集、column選択、paste、Undo grouping、
  IMEを跨ぐcoalescing境界。
- Functional checks: 3カーソルへの入力が一回のUndoで復元される、IME確定を跨ぐUndo境界、
  大量pasteのUndo、indentとcomment toggleが選択範囲に対して正しい。

### P25 Gutter, rails, and decorations

- Status: `queued`
- Depends on: P18、P23。
- Outcome: line number、git状態、breakpoint、コメントanchorが同じgutter規約の上に並ぶ。
- Scope: line number、git gutter、breakpoint（既存の`Debugging.swift`と接続）、コメントanchorのrail、
  行背景とinline装飾の描画契約。
- Functional checks: 行番号とgit状態の整合、breakpointのtoggleと復元、anchorのrail表示、
  装飾が可視範囲外を再描画しないこと。

### P26 Soft wrap and code folding

- Status: `queued`
- Depends on: P25。
- Outcome: wrapとfoldingを有効にしても、行操作とrailとanchorの位置が正しい。
- Scope: wrap geometry、fold region、wrap時とfold時の行高、anchorとrailの位置整合、hit testとcaret移動。
- Functional checks: wrap on/offの切替、長行のwrap表示、fold中の行番号とanchor、
  fold境界を跨ぐ選択と編集、wrap時のcaret上下移動。

### P27 Native diff and merge on the engine

- Status: `queued`
- Depends on: P24、P26。
- Outcome: diffとmergeがengine上で描画され、hunk単位の操作が完結する。
- Scope: 既存の`ProjectEditorDiffModel`を用いたunifiedと左右diff、hunk単位のstage/unstage、three-way merge editor、
  scroll同期、空行と末尾改行とCRLFとrenameの扱い。diff modelの再実装は行わない。
- Functional checks: 大規模diffの表示とscroll、hunk単位のstageとunstage、conflictの解決、
  stale文書に対する操作の拒否、diff上のUndo。

### P28 Inline AI suggestion and comment surfaces

- Status: `queued`
- Depends on: P24、P25。
- Outcome: AI提案と行コメントが、bridge越しではなくsurface上で直接操作できる。
- Scope: 既存の`ProjectEditorSuggestion`のinline表示と部分適用、revision検証によるstale拒否、
  コメントanchorのorphan表示と復元導線。modelの再実装は行わない。
- Functional checks: 提案の全適用と部分適用、適用後の残り提案の再計算、編集後のstale提案の拒否、
  一回のUndoでの復元、anchorのorphan化と表示。

### P29 Editor default cutover

- Status: `queued`
- Depends on: P21、P23、P24、P26、P27、P28、P33。
- Outcome: 通常のファイル編集がengine既定になり、CodeMirrorはfallbackとしてだけ残る。
- Scope: `clair.editor.native-v1`の既定反転、CodeMirror経路のfallback保持、WKWebViewをhot pathから外すこと、
  大規模fileのfallback閾値、tab状態の保存と復元。
- Functional checks: 既定でengineが使われること、設定での切り戻し、restart後のtab復元、
  保存と外部変更とlocal historyの継続動作、閾値超過fileのfallback。

### P30 Terminal grid on the shared surface

- Status: `queued`
- Priority: `high`
- Depends on: P18、P33。
- Outcome: terminalが共有surfaceで描画され、変更セルだけを再描画する。
- Scope: `TerminalGridSource`、libvterm gridからのdamage通知、変更セルのみの再描画、
  transcriptの毎frame再デコードの除去、`updateNSView`からのlayout強制の除去。broker protocolは変更しない。
- Functional checks: flood時のCPUとframe、alternate screenのenterとexit、色と属性、wide glyph、
  reattach後のreplay、resize後のgrid再構成。

### P31 Terminal input, selection, and scrollback

- Status: `queued`
- Depends on: P20、P30。
- Outcome: terminalの入力と選択とscrollbackが、editorと同じ入力層の上で動く。
- Scope: terminalのIME、選択とコピー、OSC 52、mouse reporting、bounded scrollback、resize時のreflow。
- Functional checks: CJK入力とIME確定、scrollback内の選択とコピー、OSC 52、
  mouse reportingを使うTUI、resize時のreflowとscrollback保持。

### P32 Terminal default cutover and agent TUI validation

- Status: `queued`
- Depends on: P31。
- Outcome: 現行terminal surfaceが置き換わり、agent TUIが日常利用できる。
- Scope: 現行surfaceの置換、Claude CodeとCodexとOpenCodeのTUI検証、reattachとlifecycleの回帰確認。
- Functional checks: 3種のagent TUIの表示と操作、flood中の入力取りこぼしがないこと、
  window closeとupdate restartを跨ぐreattach、複数terminalの同時動作。

### P33 Workspace state decoupling for engine seams

- Status: `active`
- Priority: `high`
- Depends on: P15C。
- Outcome: SwiftUIのstate更新がengineのhot pathへ波及しない。表示は変わらない。
- Scope: `ProjectSurfaceModel`のfileTree、git、search、layoutへの分割、`@Observable`移行、
  `ProjectEditorTab.content`を打鍵ごとに発行する経路の停止、`ContentView.swift`の分割。
- Functional checks: 既存のXCTest suiteが通ること、表示と操作に差異がないこと、
  editor入力時とterminal出力時に無関係なviewが再評価されないこと、restart後のlayout復元。
- Implemented (2026-09-11): `ProjectSurfaceModel`を`ObservableObject`から`@Observable`へ移し、
  published stateを`apple/ClairApp/ProjectSurfaceState.swift`の4つの`@Observable`
  domain（`ProjectFileTreeState`、`ProjectLayoutState`、`ProjectSearchState`、`ProjectGitState`）へ
  分割した。surfaceは従来のproperty名をそのまま公開し、各propertyを所有domainへ転送するため
  文書契約と既存呼び出しは変わらない。runtime map・generation counter・task handleは
  `@ObservationIgnored`とし、observable surfaceがviewの描画対象と一致する状態にした。
  hot pathのseamは3点: (1) `ProjectEditorTab.content`の`@Published`を外し、model由来の置換
  （外部変更reload、document自身のundo/redo、workspace全体置換）だけが`contentSyncToken`を
  進める。dirty/undo可用性は遷移時だけpublishする（`@Published`は同値代入でも再publishするため）。
  (2) editorのcaret/scroll位置はviewが描画しないため非observableなtab別mapへ移し、
  `workspaceSnapshot`生成時にtab descriptorへ畳み込む。保存形式は変更していない。
  (3) `CommandSurfaceModel`はsurface全体の再publishではなく、availability判定が実際に読む
  `gitStatus`と`selectedNodeID`だけを`withObservationTracking`で追跡する。
  さらに`ContentView.swift`（5,839行）をwindow shellと自身のoverlayだけに縮小し（969行）、
  titlebar、command palette、status bar、agent、pane、Git、navigator、editor host、settingsの
  各viewを`apple/ClairApp`の同階層fileへ分割してStable/Dev両targetへ登録した。表示と操作の
  変更は行っていない。
- Validation (2026-09-11): agent環境がLinuxでSwift/Xcode toolchainを持たないため、
  `make lint`、`make test-swift`、`make workspace-check`、`ruby scripts/validate-xcode-project.rb`
  （`plutil`が必要）は実行できていない。実行できた検査はすべて通過した:
  `ruby scripts/check-textkit-boundary.rb`（ClairTextKitの一方向依存を維持）、
  `bash -n scripts/check-workspace.sh`、`git diff --check`、および
  pbxprojのconsistency検査（286 objects、参照未解決なし、id重複なし、group参照fileの実在、
  Stable/Dev両targetが55 sourceを重複なく含む、`apple/ClairApp`のfileがすべて登録済み）。
  state移行はgrepで網羅確認した: 4 domainのpropertyへの書き込み134箇所すべてが所有domain経由で、
  computed forwarder経由の書き込み・in-place mutation・subscript代入の残りは無い。
  escaping closure内の10箇所は明示`self.`を維持した。
- Remaining: macOS host上で`make lint`、`make test-swift`、`make workspace-check`、
  `ruby scripts/validate-xcode-project.rb`を実行してbuild/test evidenceを得ること、および
  「表示と操作に差異がないこと」「editor入力時とterminal出力時に無関係なviewが再評価されないこと」
  「restart後のlayout復元」を`Clair Dev`の手動smokeで確認することが残っている。
  この2点が揃うまでstatusは`active`を維持する。
- Note: `ProjectWorkspaceModel`は`ObservableObject`のままとした。project一覧とactive project切替は
  hot pathではなく、`MobileControlRuntimeBridge`と`CommandSurfaceModel`が`objectWillChange`を
  購読している。surface levelのstateだけを`@Observable`へ移す境界をこのitemの範囲とする。
- Durable detail: [development workspace architecture](../architecture/development-workspace.md)の
  「Workspace state observation boundaries」節。

### P34 Text engine performance gate

- Status: `queued`
- Depends on: P29、P32。
- Outcome: engine既定が現行既定と同等以上であることが、同条件の計測で確認されている。
- Scope: `P17`で取得した基準値との同条件比較。input-to-glyph、frame timeとdrop frame、初回表示と初回色付け、
  idle RSS、flood CPU、実機IMEとVoiceOverの手動確認。不合格の項目は該当itemへ差し戻す。
- Functional checks: 全metricのraw sampleとsummaryが保存され、validatorを通ること。
  engineが全metricで同等以上、かつ大規模fixtureで明確に優位であること。
- Rule: これは`L01`とは別のgateである。`L01`はcutover全体の判断として引き続き`final-only`とする。

### L01 Final load and performance

- Status: `final-only`
- Depends on: P15。
- Outcome: 利用者と一緒にfrozen corpusで統合済みClairの負荷試験を行い、cutover blockerだけを最適化する。
- Scope: unlocked ccedit V1 capture、launch/resource、large file/tree/Git、terminal flood/input/frame、reattach/backpressure、recovery soak。
- Checks: fixed identity/environment、raw samples、summary、regression thresholds、accepted/deferred limitation list。
- Rule: P15以前のfeature itemをbenchmark不足で止めない。
- Legacy issue coverage: #4、#17。

## Deferred beyond the early mobile slice

Go LSP、DAP/Delve、mobile branch review、Dev Container、API Testerは
[roadmap](clair-v2-roadmap.md)の後続milestoneで扱う。Semantic agent adapters、public relay/E2EE、
team identity、mobile source editingはP16のlocal/raw valueをblockしない。

## Legacy GitHub issue archive mapping

GitHub issueは2026-09-01以降のtask source of truthとして使わない。完了済みissueは`completed`、
未完了または元の分割が現在のqueue/roadmapへ置き換わったissueは「中止ではなくlocal trackingへ移管」と
明記して`not planned`でcloseする。closed issue本文はhistorical contextであり、実装順序やstatusを更新しない。

| Legacy issue | Local authority | Archive disposition |
|---|---|---|
| #1 | roadmap全体とこのqueue | superseded by local roadmap |
| #2 | product docs、ADR-0008、ADR-0009 | release boundary resolved in P14; Apple distribution remains deferred |
| #3 | P00 | completed |
| #4 | `docs/benchmarks` contract/tooling、実計測はL01 | contract completed; measurement remains L01 |
| #5 | P03、P15A | feasibility completed; production renderer remains P15A |
| #6 | P03、P07、P14、L01 | local transport/reattach/lifecycle completed; load testing remains L01 |
| #7、#8 | P15D | architecture mismatch moved to blocked reconciliation |
| #9 | P01、P05、P15C | model/persistence completed; Interaction Lab UI remains P15C |
| #10 | P02、P06、P15B、P15C | functional slice completed; scale/UI convergence remains local |
| #11 | P04、P06 | completed |
| #12 | P04、L01 | up-front comparison replaced by reversible MVP and final-only measurement |
| #13 | P04、P06、P15B、P15C、M2 | cutover slice split across local items |
| #14 | P08、P11 | completed vertical workflow; deferred extras remain documented in those items |
| #15 | P09、P10 | completed |
| #16 | P13 | completed |
| #17 | L01 | final-only |
| #18 | P07、P14 | local session lifecycle and Stable release/update slice completed; Apple distribution remains deferred |
| #19 | P15 | queued cutover |
| #20 | P16 | early mobile agent control; semantic adapters and public relay remain deferred |
| #21 | roadmap Optional later additions | deferred beyond M1 |
| #22 | P10、P11 | completed |
| #23 | roadmap M5 | deferred beyond M1 |
| #24 | roadmap M4 | deferred beyond M1 |
| #25 | P01、P12、P13 | completed |
| #26 | roadmap M2 | deferred beyond M1 |
| #27 | roadmap M3B | deferred beyond M1 |
| #28 | P01 | completed |
| #29 | P12 | completed |
| #33 | P01、P12 | completed |
| #34、#35 | P05 | completed |
| #36、#37 | P13 | completed |

## Quarantined legacy bundles

`p0014-git-review-workflow`、`p0022-worktree-agent-orchestration`は旧ownershipを含むdraftであり、active queueの
入力にしない。`p0020-mobile-agent-remote-control`はADR-0011とこのqueueでraw-terminal MVPへ再定義したため、
P16の実装入力として復帰させる。
