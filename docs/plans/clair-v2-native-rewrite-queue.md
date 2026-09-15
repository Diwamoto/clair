# Clair v2 native rewrite task queue

Status: active execution queue
Date: 2026-09-13
Parent plan: [Clair v2 native rewrite](clair-v2-native-rewrite.md)

## Purpose

この queue は Clair v2 の実装順、依存関係、難易度、完了条件の正本である。

最初のゴールは、フルエディタや完成 UI より先に、iPhone / iPad から自宅 Mac の Clair を使って Clair 自身を開発できる状態を作ることとする。Mac 側 server、OpenCode integration、ネイティブ mobile app を最優先し、G1 の実機検証に必要な daemon-owned terminal/session backend は editor や terminal surface より先行する。その後に editor と Ghostty surface、最後に Design canvas / Clair Workbench に忠実な UI を完成させる。

旧 [Clair v2 roadmap](clair-v2-roadmap.md) と旧 [PoC queue](clair-poc-queue.md) は v1 の履歴・evidence としてだけ参照し、この queue と競合する実装順や PWA 方針は採用しない。

## Priority contract

| Priority | Goal | Product gate |
|---|---|---|
| `P0` | Mac server + native iOS/iPadOS app | スマホから Clair を開発できる |
| `P1` | Native editor + libghostty terminal | スマホと Mac の双方で IDE の主要機能を使える |
| `P2` | Mock-faithful product UI | Design canvas / Workbench と見た目・操作が一致する |

P0 の native app には、接続や承認を検証するための最小限の機能 UI を含める。ただし独自の visual design は加えない。P2 でその場しのぎの別 UI を作り直すのではなく、P0 から同じ state、command、navigation model を使い、最後に正本の tokens、layout、motion、interaction を載せる。

## Difficulty and model routing

| Difficulty | Meaning | Recommended model class |
|---|---|---|
| `D1` | 小さな機械的変更。境界や判断を増やさない | fast |
| `D2` | 一つの module に閉じた定型作業 | fast / standard |
| `D3` | 通常の実装。既存契約に沿った複数ファイル変更 | standard |
| `D4` | 並行処理、platform API、複数 component の統合 | high-performance |
| `D5` | security、protocol、editor correctness、session recovery など失敗コストが高い中核 | highest-performance |

`D4` と `D5` は高性能モデルへ割り当てる。`D5` は実装者と別の高性能モデルによる設計・差分レビューを必須とし、security-sensitive な項目は threat test を完了条件に含める。

## Working rules

- 一つの task は一つの isolated worktree、一つの focused commit で完了させる。
- 一つの agent に複数 task をまとめて渡さない。依存 task が完了してから次を開始する。
- task の status は `next`、`queued`、`active`、`blocked`、`done` のいずれかとする。
- `D5` task はコード着手前に invariants、failure modes、test matrix を task 文書または ADR に残す。
- 旧 CodeMirror、CodeEdit、libvterm、PWA を runtime fallback として残さない。
- 旧実装は fixture、test、失敗事例、protocol evidence の回収元としてだけ使う。
- user content、prompt、terminal bytes、credential を log、push payload、crash report に入れない。
- UI 上の不足を native 側で発明しない。正本にない状態は Design canvas と Workbench mock を先に更新する。

## Milestone gates

### G0: Rewrite baseline

現在状態が archive され、新しい build graph と protocol invariants が旧 runtime から独立している。

### G1: Mobile-on-Clair

iPhone / iPad から以下を一続きで行える。

1. Mac と secure pairing する。
2. Clair repository / worktree を選ぶ。
3. OpenCode session を開始または再開する。
4. prompt を送り、streaming response と factual status を読む。
5. approval / interrupt を明示的に実行する。
6. 変更ファイルと diff を確認して follow-up を送る。
7. agent の入力待ち・完了通知を受け、deep link から同じ session へ戻る。
8. background、network 切替、Mac GUI 終了後も revision を検証して再接続する。

この gate が完了するまで editor / terminal surface の本実装を priority lane に入れない。ただし、実際の agent PTY/process/session を検証するための daemon backend `T02` は G1 の前提として先行する。

### G2: Native IDE engine

独自 native editor と libghostty terminal が Mac / mobile session model に統合され、WebView、CodeEdit、libvterm へ戻らず日常操作できる。

### G3: Product UI cutover

Design canvas と Clair Workbench の全対象画面について visual / interaction / accessibility の照合が通り、仮 UI と旧 runtime が削除されている。

## Dependency overview

```text
B00 -> B01 -> B03 -> H01
B00 -> B02

H01 -> {H02, H03}
H02 -> {H04, H07}
H04 -> H05
{H03, H05} -> H06
{H03, H05, H06} -> H08
{B02, H03} -> H09
{H06, H07, H08, H09} -> H10

{B01, B02} -> N01
{B03, H03, N01} -> N02 -> N03
{H02, N03} -> N04
{H05, H06, N04} -> N05
{H07, N05} -> N06
{H08, H09, N03} -> N07
{H10, N06, N07, T02} -> N08 -> G1

G1 -> {E01, T01}
E01 -> E02 -> E03
E03 -> E04
E02 -> E05
{E02, E05} -> E06
{E03, E06} -> E07
{E03, E05} -> E08
{E03, E05, N06} -> E09
{E04, E07, E08, E09} -> E10

{H01, H04, H05, H06, H08} -> T02
{T01, T02} -> T03
{T02, H08} -> T04
{T01, T04, N01} -> T05
{T03, T05} -> T06
{T04, T06} -> T07
{E10, T07} -> G2

G2 -> U01 -> U02
{U02, N08} -> U03
{U02, E10, T07} -> U04
{U03, U04, E10} -> U05
{U03, U04, T07} -> U06
{U05, U06} -> U07 -> U08 -> G3
```

## P0-A: Rewrite foundation

| ID | Status | Difficulty | Depends on | Task and completion evidence |
|---|---|---:|---|---|
| `B00` | `done` | `D2` | — | 現在の dirty worktree を整理して pre-v2 checkpoint commit と archive tag を作る。plan/queue を含む状態を Git から復元でき、旧ファイルを物理コピーしていないこと。 |
| `B01` | `done` | `D3` | `B00` | v2 の Swift packages、macOS app、iOS/iPadOS app、daemon executable の空 target と build/test lane を作る。旧 runtime module を link せず全 target が build すること。 |
| `B02` | `done` | `D3` | `B00` | native mobile + APNs 方針の ADR を作り、PWA 優先の ADR/P0020/roadmap を superseded として接続する。bundle ID、signing、TestFlight、push entitlement の ownership を記録すること。 |
| `B03` | `done` | `D5` | `B01` | `ProjectID`、`WorktreeID`、`SessionID`、revision、operation ID、capability、error、event envelope の共有 protocol と invariants を定義する。version negotiation、unknown field、frame bound、replay の golden tests が通ること。 |

## P0-B: Mac host and server

| ID | Status | Difficulty | Depends on | Task and completion evidence |
|---|---|---:|---|---|
| `H01` | `done` | `D4` | `B03` | GUI から独立して動く `ClairDaemon` lifecycle、single-instance ownership、local control channel、health/version endpoint を実装する。GUI を閉じても daemon が生存し、二重起動せず、安全に停止・再起動できること。 |
| `H02` | `done` | `D3` | `H01` | project/worktree catalog、file tree、bounded file read、changed-file summary を read-only API として提供する。symlink、permission、missing root、巨大 file の境界 test が通ること。 |
| `H03` | `done` | `D5` | `B02`, `B03`, `H01` | native client transport、one-time pairing、device key、host fingerprint、grant scope、revoke を実装する。default-deny、expiry、replay、stolen token、revoked active connection の threat tests が通ること。 |
| `H04` | `done` | `D5` | `H02` | OpenCode を provider adapter の第一実装として起動・再開・停止し、project/worktree/session identity に関連付ける。provider upgrade、abnormal exit、duplicate launch、cwd mismatch を型付きで扱うこと。 |
| `H05` | `done` | `D5` | `H04` | OpenCode の streaming event を provider-independent な conversation、tool call、attention、completion、usage event に正規化する。順序、重複、partial event、unknown event を deterministic に処理すること。 |
| `H06` | `done` | `D5` | `H03`, `H05` | prompt、approval、deny、interrupt、stop を scoped command として実装する。operation ID による exactly-once effect、stale approval rejection、audit metadata、disconnect race の tests が通ること。 |
| `H07` | `done` | `D4` | `H02` | Git status、changed-file list、text/binary diff、hunk metadata を mobile API に追加する。untracked、rename、large diff、invalid encoding、worktree race を壊さず表示できること。 |
| `H08` | `done` | `D5` | `H03`, `H05`, `H06` | session journal、subscriber cursor、gap/resync、revision snapshot、idempotency window を実装する。network switch、slow client、daemon restart、out-of-range cursor で silent data loss がないこと。 |
| `H09` | `done` | `D4` | `B02`, `H03` | 最小 `ClairPushRelay` と APNs provider boundary を実装する。opaque event だけを送り、credential rotation、device token replacement、revoke、TTL、sandbox/production 分離を検証すること。 |
| `H10` | `done` | `D5` | `H06`, `H07`, `H08`, `H09` | daemon の crash recovery、resource limits、structured diagnostics と server integration suite を完成させる。Mac GUI なしで G1 の全 server operation を fixture client から再現できること。 |

## P0-C: Native iPhone / iPad app

| ID | Status | Difficulty | Depends on | Task and completion evidence |
|---|---|---:|---|---|
| `N01` | `done` | `D3` | `B01`, `B02` | SwiftUI native app、composition root、environment、shared package、unit/UI test target を作る。signed physical-device build と TestFlight smoke の手順を確立すること。旧 `ClairMobileApp` は reference に留める。 |
| `N02` | `done` | `D4` | `B03`, `H03`, `N01` | typed client、Keychain device identity、pairing handshake、certificate/host pin、capability negotiation を実装する。credential を log/UI stateへ漏らさず、再起動後に安全に reconnect できること。 |
| `N03` | `done` | `D3` | `N02` | host list、pair/re-pair、connection state、device scope、revoke UI を最小 native UI で実装する。offline、expired QR、fingerprint change、revoked device を区別できること。 |
| `N04` | `done` | `D3` | `H02`, `N03` | project/worktree/session browser と recent destination を実装する。複数 project を混線せず、missing root と permission error を明示すること。 |
| `N05` | `done` | `D4` | `H05`, `H06`, `N04` | OpenCode conversation stream、prompt composer、attention、approval/deny/interrupt を native app へ接続する。重複 tap、background 中の response、stale approval が安全であること。 |
| `N06` | `done` | `D4` | `H07`, `N05` | changed-file list、native diff、hunk navigation と review follow-up を実装する。binary/large/truncated diff を明示し、表示だけで working tree を変更しないこと。 |
| `N07` | `done` | `D4` | `H08`, `H09`, `N03` | APNs registration、notification category、deep link、scene lifecycle、background reconnect を実装する。foreground/background/terminated から正しい host/session/revision へ戻る実機 smoke が通ること。 |
| `N08` | `queued` | `D5` | `H10`, `N06`, `N07`, `T02` | G1 Mobile-on-Clair dogfood gate。iPhone だけを操作して Clair repo の実際の raw terminal session 上で OpenCode process を起動し、依頼、承認、diff確認、follow-up、完了通知、再接続までを行い、fixture と実機 evidence を残すこと。 |

Apple Developer membership、Team ID、APNs key は `N01`、`H09`、`N07` の実機完了に必要な外部依存である。入会待ちの間も code、simulator、mock APNs provider、protocol tests は進めるが、G1 は実機通知を確認するまで完了にしない。

## P1-A: Clair-owned native editor

Editor track と Terminal surface track は G1 完了後、別 worktree で並列に進めてよい。daemon-owned PTY/process/session backend と raw agent I/O bridge の `T02` だけは、G1 の実際の agent session を成立させるため G1 前に先行する。

| ID | Status | Difficulty | Depends on | Task and completion evidence |
|---|---|---:|---|---|
| `E01` | `queued` | `D4` | `N08` | editor invariants、Unicode corpus、10MB/long-line fixture、latency/memory benchmark harness を確定する。旧 CodeEdit PoC の失敗値を baseline evidence として保存すること。 |
| `E02` | `queued` | `D5` | `E01` | Swift の text storage、line index、stable line ID、UTF-8/UTF-16/grapheme coordinate、immutable revision を実装する。randomized edit と differential tests が通ること。 |
| `E03` | `queued` | `D5` | `E02` | transaction、SelectionSet、multi-cursor、rectangular selection、Undo/Redo、external/agent edit merge を実装する。複数 cursor の一操作が一つの undo unit になること。 |
| `E04` | `queued` | `D3` | `E03` | literal/regex search、replace preview、replace one/all、selection scope を core transaction に統合する。zero-length regex、Unicode、stale result を安全に扱うこと。 |
| `E05` | `queued` | `D4` | `E02` | Tree-sitter incremental parse と LSP coordinate/lifecycle を実装する。edit delta だけで parse を更新し、stale diagnostic/completion を revision で拒否すること。 |
| `E06` | `queued` | `D5` | `E02`, `E05` | macOS custom `NSView`、CoreText visible-line layout、scroll、hit test、caret、selection、syntax/diagnostic layers を実装する。全行 eager layout や一行一 View を作らないこと。 |
| `E07` | `queued` | `D5` | `E03`, `E06` | `NSTextInputClient`、日本語 IME、marked text、clipboard、drag/drop、accessibility、system cursor を実装する。実機 IME/VoiceOver と Unicode matrix が通ること。 |
| `E08` | `queued` | `D5` | `E03`, `E05`, `N08` | iOS/iPadOS native editor surface、touch selection、hardware keyboard、IME、viewport virtualization を同じ editor core 上へ実装する。Mac と同じ transaction fixture が通ること。 |
| `E09` | `queued` | `D5` | `E03`, `E05`, `N06` | revision-aware review anchor、line comment、thread、stale/orphaned/resolved、AI suggestion apply/reject/partial/undo を実装する。編集後の誤った再配置や二重適用がないこと。 |
| `E10` | `queued` | `D5` | `E04`, `E07`, `E08`, `E09` | editor integration gate。Mac/mobile で edit、multi-cursor、search/replace、review、save、external agent edit を通し、10MB/long-line/IME の performance threshold を満たすこと。 |

## P1-B: libghostty terminal

| ID | Status | Difficulty | Depends on | Task and completion evidence |
|---|---|---:|---|---|
| `T01` | `queued` | `D5` | `N08` | libghostty/GhosttyKit の pinned build、license、resource bundle、C ABI、Swift concurrency boundary を確立する。macOS/iOS の reproducible build と minimal surface smoke が通ること。 |
| `T02` | `done` | `D5` | `H01`, `H04`, `H05`, `H06`, `H08` | raw input/output を含む daemon-owned PTY/process/session ownership と agent I/O bridge を `ClairDaemon` に実装し、surface から分離する。stable SessionID、bounded binary stream、resize owner、bounded journal、attach/detach、child reaping を検証し、N08 が実際の OpenCode process を mobile control 経路から操作できる backend を完成させること。 |
| `T03` | `queued` | `D4` | `T01`, `T02` | macOS Ghostty surface を native workspace に接続する。local shell、selection、copy/paste、scrollback、font/DPI、window resize が動くこと。 |
| `T04` | `queued` | `D5` | `T02`, `H08` | remote terminal binary stream、epoch/cursor、snapshot/gap、backpressure、input ordering を実装する。alternate screen 中の reconnect と slow subscriber で破損しないこと。 |
| `T05` | `queued` | `D5` | `T01`, `T04`, `N01` | iOS/iPadOS Ghostty surface と remote session attach を実装する。touch scroll/selection、hardware keyboard、safe-area/rotation、background detach が動くこと。 |
| `T06` | `queued` | `D4` | `T03`, `T05` | IME/CJK、paste guard、mouse reporting、focus、desktop-owned PTY geometry、mobile local viewport を統合する。mobile attach が desktop rows/columns を暗黙に変えないこと。 |
| `T07` | `queued` | `D5` | `T04`, `T06` | terminal integration gate。OpenCode TUI、shell、resize、alternate screen、flood、sleep/wake、network switch、Mac/mobile 同時入力、reattach の実機 tests と resource limits が通ること。 |

## P2: Mock-faithful UI

UI の正本は [Clair UI Design canvas と Workbench](../../prototypes/clair-workbench/README.md) とする。Interaction Lab は静的な acceptance evidence として参照できるが、Workbench と競合する場合は canvas / Workbench を優先する。

| ID | Status | Difficulty | Depends on | Task and completion evidence |
|---|---|---:|---|---|
| `U01` | `queued` | `D2` | `E10`, `T07` | Design canvas と Workbench を同期し、対象 screen/state、tokens、layout、interaction、motion の native implementation checklist を freeze する。未定義状態を一覧化し、native 側で発明していないこと。 |
| `U02` | `queued` | `D3` | `U01` | canvas tokens を Swift の color/type/spacing/radius/motion primitives と reusable native controls に写す。値と semantic name の照合 test を持つこと。 |
| `U03` | `queued` | `D3` | `U02`, `N08` | mobile の host/project/session/activity/review/notification navigation を mock contract に合わせる。compact/regular size class と safe area を native に適応しつつ情報階層を変えないこと。 |
| `U04` | `queued` | `D3` | `U02`, `E10`, `T07` | macOS AppShell、titlebar project groups、sidebar、pane/tab、status bar、command/settings surfaces を Workbench に合わせる。native window chrome を含む screenshot comparison が通ること。 |
| `U05` | `queued` | `D4` | `U03`, `U04`, `E10` | editor、diff、AI review comment/thread/suggestion、context menu の visual/interaction を mock に合わせる。keyboard navigation、focus、stale state、empty/error state を照合すること。 |
| `U06` | `queued` | `D3` | `U03`, `U04`, `T07` | terminal、agent activity、session list、attention/approval surfaces を mock に合わせる。terminal content の描画性能を UI overlay が悪化させないこと。 |
| `U07` | `queued` | `D4` | `U05`, `U06` | screenshot/interaction regression、VoiceOver、Dynamic Type、keyboard-only、reduced motion、contrast の final QA を Mac/iPhone/iPad で行う。差分は canvas 変更か native bug のどちらかへ分類すること。 |
| `U08` | `queued` | `D3` | `U07` | final cutover。仮 UI、旧 CodeMirror/CodeEdit/libvterm/PWA assets、不要 dependency/build path を削除し、docs/runbook を v2 だけに更新する。archive tag からのみ旧実装を復元できる状態にすること。 |

## Initial dispatch order

着手順は次で固定する。

1. `B00`
2. `B01` と `B02` を並列
3. `B03`
4. `H01` と `N01` を並列
5. `H02` と `H03` を並列
6. `H04` と `N02` を依存解消順に開始
7. `H05`、`H07`、`N03`、`N04`
8. `H06`、`H08`、`H09`、`N05`、`N06`、`N07`
9. `H10`
10. Terminal backend `T02` を G1 前に開始
11. `N08` で G1 を実機判定
12. G1 後に Editor track `E01` と Terminal surface `T01` を並列開始
13. G2 後にだけ `U01` から UI track を開始

依存が未完了の task を、並列数を埋める目的で先行実装しない。

## Execution evidence

`clair-v2-orchestrator` の controller だけが、統合済み task の status と実行記録を更新する。各記録には task ID、統合日、integration commit、検証結果、明示的な残課題を含める。worker branch の完了だけでは記録しない。

### B00 — 2026-09-14

- integration commit: `882505339461471a20b647d05a5e57dc6dc313cf`
- archive tag: `archive/clair-v1-2026-09-14`
- verification: `git diff --cached --check` passed; `python3 .agents/skills/clair-v2-orchestrator/scripts/test_task_lease.py` passed (3 tests); queue validation passed before checkpoint
- restored scope: current tracked changes and 9 explicitly listed untracked repository files, including the v2 plan, queue, and orchestrator skill; ignored build/machine output was excluded
- remaining: no v2 implementation task is integrated yet; no push or publication performed

### B01 — 2026-09-14

- integration commit (worker source): `2e9d4d5af35d5287084377fa5a7e2d29fc82e94b` (integrated into `rewrite/clair-v2` by the controller)
- source range: `7585c0246f2f4735455d704230d169437ba7959a..2e9d4d5af35d5287084377fa5a7e2d29fc82e94b`
- verification: `git diff --check` passed; `bash -n scripts/v2-foundation.sh` passed; `make -C /Users/daiki/.codex/worktrees/6385/clair v2-foundation` passed (8 core targets, 3 executable targets, iOS Simulator cross-build, and 3 package tests)
- result: independent `ClairV2Core` / `ClairV2Apps` package graph and foundation lane added; v1 runtime modules are not linked; ignored package `.build` output was not integrated
- remaining: targets are intentional placeholders; daemon lifecycle, protocol, UI, signing, and device/TestFlight work remain in later queue tasks; no push/publication

### B02 — 2026-09-14

- integration commit (worker source): `4dea97bc5a7a49abe4acf17dff481e208aac10a9` (integrated into `rewrite/clair-v2` by the controller)
- source range: `99814f6c0e2c63b118bfbe8335f61f5561f51a53..4dea97bc5a7a49abe4acf17dff481e208aac10a9`
- verification: worker and controller `git diff --check` passed; changed document references and supersession links were reviewed; the worker diff contains documentation only
- result: accepted ADR-0015 records native iPhone/iPad, APNs, bundle ID, signing, entitlement, device-token, credential, and TestFlight ownership; ADR-0013, P0020, product scope, and roadmap are connected as superseded or historical inputs
- remaining: native APNs relay, entitlements, signed device build, TestFlight smoke, and runtime implementation remain in later queue tasks; no push/publication

### B03 — 2026-09-14

- integration commits (worker source): `1ff70b6663a0ae1bba012d40e594dc4854cf0fb7`, `cd88610e98b986ce82772ba20f15e1d55f34e79c`, `7b3010faef421633f34c1143da847d698da273fb` (integrated into `rewrite/clair-v2` by the controller)
- source range: `c299561bdd8da5fcb18b83a33e8a51cd5d892fd0..7b3010faef421633f34c1143da847d698da273fb`
- independent D5 review: first review found and required fixes for capability mismatch and decoder chunk bounds; repair review found and required fixes for terminal grant mapping and non-exact session scopes; final fresh review approved with no P0/P1/P2 findings
- verification: worker and independent reviewer protocol tests passed (final worker 12 tests, reviewer focused 10 tests); `make v2-foundation` passed with all v2 targets, macOS/iOS cross-build, Core 12 tests, and Apps 1 test; strict Swift format lint passed; `git diff --check` passed; v1 boundary check passed
- result: `ClairV2Shared` now owns typed identity, scope, capability, version, error, event, replay, and operation contracts; unknown fields/codes remain forward-compatible; frame decoding is fail-closed before allocation; operation capability mapping is authoritative; session scope containment is exact across optional worktree presence
- remaining: transport, daemon, pairing, APNs, UI, provider runtime, and device/TestFlight work remain in later queue tasks; repo-wide pre-existing Swift lint findings outside B03 were not changed; no push/publication

### H01 — 2026-09-14

- integration commit (worker source): `81be339ea3c7b546bca229b73ec5e6248ba2609b` (integrated into `rewrite/clair-v2` by the controller)
- source range: `29e3335a58446b7fb261cd5c1e39398818d95025..81be339ea3c7b546bca229b73ec5e6248ba2609b`
- verification: `make v2-foundation` passed; Core 18 tests passed; Apps package tests and separate-process daemon lifecycle fixture passed; strict Swift format lint passed; `git diff --check` passed; v1 dependency/runtime boundary passed
- result: `ClairV2DaemonKit` provides GUI-independent lifecycle, single-instance ownership, owner-only runtime directory and Unix control socket, typed health/version/shutdown control, bounded request framing, restart and signal cleanup; bind-failure cleanup is ownership-aware
- remaining: project/worktree catalog, transport/pairing, provider runtime, journal/reconnect, APNs relay, native client UI, and device/TestFlight work remain in later queue tasks; no push/publication

### N01 — 2026-09-14

- integration commit (worker source): `c3646d67802b38d7f274df29736eb0033c177ea3` (integrated into `rewrite/clair-v2` by the controller; shared app README conflict resolved by retaining both H01 and N01 seams)
- source range: `29e3335a58446b7fb261cd5c1e39398818d95025..c3646d67802b38d7f274df29736eb0033c177ea3`
- verification: `make v2-foundation` passed with all targets, iOS cross-build, and 17 package tests; `ClairV2Mobile.xcodeproj` app build and unit/UI build-for-testing passed; strict Swift format lint passed; `git diff --check` passed; old `ClairMobileApp` runtime import boundary passed
- result: native SwiftUI composition root and environment/state foundation added in `ClairV2MobileKit`, with transport-neutral lifecycle, connection state, command reducer, navigation destinations, separated app/unit/UI smoke targets, and signed-device/TestFlight runbook
- external dependency: physical signing and TestFlight smoke remain unexecuted pending Apple Developer/App Store Connect access, certificates, provisioning profile, and a registered device; APNs, Keychain, and transport remain in later N02/N07 tasks
- remaining: typed client, pairing, host/project/session browsing, conversation UI, APNs/deep links, and production visual design remain in later queue tasks; no push/publication

### H02 — 2026-09-14

- integration commit (worker source): `8c6d3d87fb55889cfd1d786ca9cd555dbe0c8615` (integrated into `rewrite/clair-v2` by the controller)
- source range: `3e7f310bb63843f70df79f0477b85bbaaf93061b..8c6d3d87fb55889cfd1d786ca9cd555dbe0c8615`
- verification: `make v2-foundation` passed with all v2 targets, iOS Simulator cross-build, Core 29 tests, and Apps 1 test; strict Swift format lint passed; staged and commit `git diff --check` passed; symlink, permission, missing root, path escape, large/binary/invalid UTF-8, tree/read bounds, and Git catalog/status boundary tests passed
- result: `ClairV2Workspace` provides typed project/worktree catalog, bounded lazy file-tree enumeration, fail-closed path/symlink-safe file reads, and bounded Git changed-file summaries; Codable decode revalidates root and limits, and outputs remain read-only
- remaining: provider runtime, secure transport/pairing, journal/reconnect, APNs relay, native client UI, and device/TestFlight work remain in later queue tasks; no push/publication

### H03 — 2026-09-14

- integration commits (worker source): `f3eb18e08fb2b599e412c2e8069688c7fcaf31b0`, `6556d9803d2c06cfa68181cfe36f89bc9ab637c3` (integrated into `rewrite/clair-v2` by the controller)
- source range: `3e7f310bb63843f70df79f0477b85bbaaf93061b..6556d9803d2c06cfa68181cfe36f89bc9ab637c3`
- independent D5 review: first review required fixes for timestamp conversion overflow, token-backed challenge exhaustion, reconnect connection leakage, forgeable connection handles, and missing token expiry; the repair commit also added scope binding, bounded Codable paths, H06 generation tickets, client invalidation, and regression coverage; a fresh review approved with no P0/P1 findings and recorded only follow-up P2 hardening
- verification: worker H03 tests 25 passed and Core 47 tests passed; v2 foundation all targets, Apps, iOS Simulator, and v1 dependency boundary passed; strict Swift format and `git diff --check` passed; fresh reviewer independently confirmed the same tests/build/boundary checks and a clean read-only worktree
- result: `ClairV2Transport` provides CryptoKit P-256 device/host identity, SHA-256 host fingerprints, one-time pairing, challenge proofs, expiring token digests, bounded per-device challenge admission, typed exact scopes/capabilities, generation-checked H06 tickets, reconnect replacement, internal connection handles, actor-serialized revocation, bounded frames/Codable inputs, and client invalidation
- remaining: Network.framework/TLS connection plumbing, Keychain/Secure Enclave persistence, APNs/relay production credentials, durable storage, and H06 dispatch/revoke atomicity remain external or later boundaries; per-device connection quotas, refresh/re-pair cleanup, and generic B03 `ProtocolOffer` decode bounds remain P2 hardening follow-ups; no push/publication

### N02 — 2026-09-14

- integration commit (worker source): `478ce8e271502af77c706ee1ee7fabbed1f67c79` (integrated into `rewrite/clair-v2` by the controller as `d582e9a`)
- source range: `aefe0b92d96595fb10d3e305f4d6571af7c653c5..478ce8e271502af77c706ee1ee7fabbed1f67c79`
- verification: N02 focused tests 10/10 passed; Core 64/64 and Apps 1/1 passed; iOS Simulator cross-build passed; strict Swift format lint, `git diff --check`, v1 boundary check, and source redaction scan passed; no `print`/`debugPrint` in N02 source
- result: `ClairV2MobileKit` now provides typed disconnected/connecting/pairing/authenticated/reconnecting/failed client state, injectable Keychain/Secure Enclave identity storage with in-memory test fake, H03/B03 pairing and capability reuse, base64 persistence envelope, certificate/host pin fail-closed validation, restart reconnect, cancellation/race/idempotency handling, and credential/private-key redaction
- external dependency: production Network.framework/TLS channel and Secure Enclave signer remain explicit fail-closed boundaries pending later transport integration; no push/publication
- remaining: conversation UI, APNs/deep links, and production visual design remain in later queue tasks

### H04 — 2026-09-14

- integration commit (controller): `930f10dedce01bd67b36447d0681f549d64ccb3c`
- source range (worker): `aefe0b92d96595fb10d3e305f4d6571af7c653c5..388ad232d112a8491e7905c16b61033c220740bd`
- independent D5 review: fresh review approved with no P1/P2 findings after checking the earlier lifecycle fixes and the review-7 repair scope; cold-cache parallel timing failures did not reproduce in the warm-cache parallel rerun
- verification: H04 focused 31/31 passed; full Core 88/88 passed serially and in the warm-cache parallel rerun; Apps passed; `make v2-foundation` warm rerun passed; strict H04 format, `git diff --check`, v1 boundary, iOS Simulator build, descriptor/FD inheritance, PGID reuse, claim/cleanup race, waitid recovery, closed-stdin, invalid-callback, and no-residual-process checks passed
- result: OpenCode provider lifecycle now has typed identity and launch bounds, descriptor-held cwd validation, keeper-backed process-group ownership, bounded waitid recovery without actor blocking, CLOEXEC fd normalization for stdin/stdout/stderr collisions, exactly-once kill/reap tracking, upgrade/duplicate/abnormal-exit handling, shutdown fencing, and cleanup-pending retention for unproven callbacks
- known limitation: repository-wide Apple strict format still reports pre-existing violations in unchanged `apple/ClairApp` and `apple/ClairMobileApp`; no H04 files are implicated
- remaining: scoped commands/approvals, session journal/reconnect, APNs relay, and native client UI remain in later queue tasks

### N03 — 2026-09-14

- integration commit (controller): `4cd2880a76c8184e46caab4acc8cd749cce58509`
- integration commit (worker source): `274c8ad618be90fbd86a7935cd4ac79e5c7f588e`
- verification: N03 focused tests, ClairV2Apps tests, and ClairV2MobileApp build passed; strict Swift format and `git diff --check` passed; worker worktree was clean
- result: `ClairV2MobileApp` now exposes a minimal native host-management surface for host list, pair/re-pair, connection state, device scope, and local pairing revoke; offline, QR expiry, fingerprint change, and revoked states are distinct, with credential/private-key redaction tests
- boundary: remote revoke RPC remains outside the existing H03 transport contract, so N03 keeps revoke local to protected pairing state; physical iOS signing and TestFlight smoke remain external
- remaining: conversation UI, APNs/deep links, and production visual design remain in later queue tasks

### H07 — 2026-09-14

- integration commit (controller): `87d2c99a58284614fdce28f72cc321816e427cbc`
- integration commit (worker source): `dd4acf167e921c96c55951344bd2f416ffe47b76`
- verification: H07 focused tests 13/13 passed; ClairV2Apps 1/1 and `make v2-check` passed; strict Swift format, `git diff --check`, redaction scan, and worker-contract checks passed; worker worktree was clean
- result: `ClairV2Workspace` now exposes bounded read-only Git status, changed-file records, text/binary unified diff results, and deterministic hunk metadata; untracked/rename/binary/large/invalid-encoding cases, root identity races, missing roots, permission failures, and output bounds fail closed
- known limitation: the worker's full Core rerun retained one unrelated pre-existing H04 waitid fixture failure; all H07 tests and affected Apps checks passed, and H07 did not alter H04 runtime code
- remaining: scoped commands/approvals, session journal/reconnect, APNs relay, and native client UI remain in later queue tasks

### H05 — 2026-09-14

- integration commits (worker source): `f1192d4bdf779b0ff2218360343b6f7f80c0f44f`, `c7c4bc166223173cf4397f4bd9aea7835b338da2` (integrated into `rewrite/clair-v2` as `70d710d` and `d989e72`)
- independent D5 review: the first fresh review required fixes for unknown-provider substring classification, limits `Codable` validation bypass, and semantic reordering; the repair commit added exact allowlist/drop behavior, decode-time hard bounds, and non-terminal input-order preservation; a second fresh review approved with no P1/P2 findings
- verification: worker and reviewer H05 focused tests 18/18, full ClairV2Core 116/116, and ClairV2Apps 1/1 passed; `make v2-foundation` passed after controller integration with all v2 targets, macOS/iOS builds, package tests, and the H04 closed-stdin fixture; strict Swift format, `git diff --check`, v1 boundary, redaction/logging, and worker-contract checks passed
- result: `ClairV2Agent` now normalizes bounded OpenCode NDJSON/SSE conversation, tool-call, attention, completion, and usage events while preserving project/worktree/session scope and epoch/revision; deterministic identity/dedupe/conflict handling, partial UTF-8 chunks, completion/usage ordering, exact unknown-event drop, Codable limits validation, and provider-payload privacy are covered
- known limitation: SwiftPM global cache paths required temporary redirection to `/private/tmp`; all reruns succeeded; no push/publication
- remaining: scoped commands/approvals, session journal/reconnect, APNs relay, and native client UI remain in later queue tasks

### N04 — 2026-09-14

- integration commit (controller): `5294c5d53cb2fe8c61765bc9bae2684e68557713`
- integration commit (worker source): `431bd925f422b050c0000a34840037e752590297`
- verification: N04 focused tests 6/6 passed; ClairV2Core 127 tests passed in the worker's single-worker run; ClairV2Apps 1/1 passed; `make v2-check` and `make v2-build` including iOS Simulator passed; strict Swift format, `git diff --check`, v1 boundary, and print/debugPrint/redaction scans passed
- result: `ClairV2MobileKit` and `ClairV2MobileApp` now provide a read-only project/worktree/session destination browser using typed identity and `ResourceScope`, recent destination restore/clear, multi-project isolation, stale-selection filtering, explicit missing/permission states, and zero transport side effects
- known limitation: controller `make v2-foundation` full parallel test reruns reproduced unrelated pre-existing H04 process-group/daemon timing failures; all N04 tests and the affected build/package checks passed, and no N04 source is implicated
- remaining: conversation stream UI, scoped commands/approvals, APNs/deep links, and production visual design remain in later queue tasks

### H09 — 2026-09-14

- integration commit (controller): `6583a93` (`feat(v2-h09): add push relay boundary`)
- integration commit (recovered worker source): `e50a36e194d63a69febb79b360a283055452120b`
- verification: H09 focused tests 10/10 passed in the worker and controller; full ClairV2Core 137/137 and ClairV2Apps 1/1 passed; `make v2-check` and `make v2-build` including all v2 targets and iOS Simulator passed; strict Swift format lint and `git diff --check` passed
- result: `ClairV2Push` defines bounded opaque wake events with strict decoding; `ClairDaemonPushRegistry` binds token generations and scope admission to H03 authority, expiry, replacement, revoke, environment isolation, and H05 attention/completion projection; `ClairPushRelay` provides bounded digest idempotency; APNs request and protected credential-store seams classify provider failures without secret echo
- external dependency: no Apple credential, durable protected store, APNs JWT/HTTP2 transport, or real notification was used; N07 owns mobile registration/actions/deep links and physical-device/TestFlight smoke remains pending Apple Developer access
- remaining: scoped commands/approvals, session journal/reconnect, native conversation UI, and production APNs/device integration remain in later queue tasks; no push/publication

### H06 — 2026-09-14

- integration commits (controller): `f3e49c7d4673f963f6d2e34bb13afb9e1df8bba2`, `4a9c1c5d751ca1459e58404643ad1ca028536a8d`, `67aa937a260cef3e1a5d9fb0d194880e0ea24523`
- integration commits (worker source): `824385ac3cfd1876288e0e38010092bd30466797`, `08ab3db6f00aa0e2dbd7604546fe9b8455462482`, `2731b1e787c9909a1733d65930b35a81c332fe42`
- independent D5 review: first fresh review required fixes for missing/uncorrelated approval IDs, attention-kind replacement, and command description redaction; the repair added explicit optional correlation, OpenCode `properties.id` / `properties.requestID` extraction, fail-closed approval-window invalidation, and whole-command redaction; a final fresh review approved with no P0/P1/P2 findings
- verification: H06 focused tests 24/24 and full ClairV2Core 152/152 passed in the worker/reviewer; controller H06 focused tests passed; controller serial rerun passed all 162 tests except one unrelated pre-existing H04 process-group fixture timing failure, which passed when rerun alone; ClairV2Apps 1/1, `make v2-check`, `make v2-build` including all v2 targets and iOS Simulator, strict Swift format, `git diff --check`, and v1 boundary checks passed
- result: `ClairV2Agent` and `ClairV2DaemonKit` now provide exact scoped prompt/approval/deny/interrupt/stop commands with H03 authorization-before-effect, generation/epoch/session binding, H05 event replay and attention lifecycle, B03 digest-only exactly-once ledger, bounded audit, and provider/prompt/raw-ID redaction; missing or uncorrelated attention cannot leave an executable stale approval
- external dependency: concrete provider effect wiring and durable command recovery remain later integration; no external credential or push publication was introduced by H06
- remaining: session journal/reconnect, native conversation UI, and H10 server integration remain in later queue tasks; no push/publication

### H08 — 2026-09-14

- integration commit (controller): `33abd5178cb8867b5b8ba64d95c3fcaf3e30ba7d`
- integration commits (worker source): `523556b088da771592d0f8cfdb97f477bdc1f154`, `0889dc0f2fd8954e5de8d4b9087d477361055fe6`
- independent D5 review: first fresh review found one blocking finding — `JournalState.open` constructed B03 `ReplayState` without passing `maximumEventHistory`, so it defaulted to 256 while the journal's actual retention (`ClairV2SessionJournalLimits.defaultEventRetention`, 512) was larger; a legitimate retransmission of an event beyond the 256-window but within the 512 retention window was misclassified as `replayRegression`, fail-closed-faulting the whole generation and starving unrelated subscribers too; the repair passed `maximumEventHistory: limits.eventRetention` explicitly and added a regression test proving the failure mode is fixed without weakening genuine gap/regression fail-closed behavior; a second fresh review approved with no remaining blocking findings
- verification: worker H08 focused tests 21/21 then 22/22 after repair passed; reviewer independently re-ran the same suite read-only and reproduced both the pre-fix failure and the post-fix pass; controller `make v2-foundation` passed with `v2-check` (v1 boundary), all v2 targets built, full `ClairV2Core` 184/184 and `ClairV2Apps` 1/1 tests passed; strict Swift format lint, `git diff --check`, and print/debugPrint/v1-reference scans passed in worker, reviewer, and controller
- result: `ClairV2DaemonKit` gains `ClairV2SessionJournal`, a bounded per-session event log with named subscriber cursors, revision snapshots, explicit gap/resync, and append/acknowledge idempotency built on B03's real `ReplayState.apply`; network-switch reconnect, a slow subscriber beyond the retention window, daemon restart (fresh in-memory journal explicitly rejecting a stale pre-restart cursor rather than silently treating it as caught up), and an out-of-range/invalid cursor are all covered by dedicated tests that fail if the corresponding guard is removed; a detected gap/regression/reuse faults only that session's generation and fails closed rather than silently continuing
- known limitation: durable/disk persistence across a real daemon restart is out of scope (no queue task before H08 introduced disk persistence); `snapshot()`/lifecycle observers do not yet surface a faulted-generation flag for pure pollers (noted as a pre-H10 observability follow-up, not a blocker); H06's independent `ReplayState` construction in `ClairV2AgentCommandBoundary` has no analogous dual-window structure and was out of this task's scope
- remaining: native conversation UI (`N05`) and H10 daemon crash-recovery/resource-limit/integration-suite work remain in later queue tasks; no push/publication

### N05 — 2026-09-14

- integration commit (controller): `aa1323ec2cb7ee9dc8cddb9c53b40a5aef14aad5`
- integration commit (worker source): `1703cec0de8f9da5cfa1bdc4b98022ef89785002`
- verification: N05 focused tests 18/18 passed in the worker and independently rerun by the controller; controller `make v2-foundation` passed (`v2-check` v1 boundary, all v2 targets including iOS Simulator, `ClairV2Apps` 1/1); a full serial `ClairV2Core` rerun first showed 6 issues confined to pre-existing H04 process-group/waitid fixtures (`h04LongLivedWaitIDFailureDoesNotBlockStartAndStopCompletesThroughRetry`, `h04CleansProcessGroupBeforeReapingLeader`, `h04LateProcessGroupClaimCannotReassertPendingCleanupAfterExit`), all three of which passed when rerun alone and a subsequent full rerun passed all 202 tests cleanly — the same non-deterministic pre-existing H04 timing flake already recorded against H06/H07/N04, not caused by N05; strict Swift format lint, `git diff --check`, and v1-boundary/print-debugPrint scans passed
- result: `ClairV2MobileKit` gains `ClairV2MobileConversationController` (an actor) and `ClairV2MobileConversationState`, folding H05 normalized conversation/tool-call/attention/completion/usage events idempotently and monotonically (safe regardless of scene lifecycle) and dispatching H06 scoped prompt/approve/deny/interrupt/stop commands through a new `ClairV2MobileAgentTransport` seam; per-action-key in-flight command de-duplication makes a duplicate/rapid-repeat tap join the same in-flight command instead of double-dispatching; pending-approval folding mirrors `ClairV2AgentCommandBoundary.ingest`'s fail-closed invariants (uncorrelated attention invalidates the whole window, an approval already resolved or superseded is rejected locally) with a self-heal path if the host still returns a stale-approval rejection; `ClairV2MobileRootView` gained a minimal transcript/approve-deny/composer/interrupt-stop section wired to it, consistent with the P0 minimal-functional-UI rule
- external dependency: the live session-start handshake that supplies a real `epoch`/`processGeneration`/`connection` attachment does not exist yet (no prior queue task introduced it), so production wiring remains the explicit fail-closed `ClairV2MobileUnavailableAgentTransport` boundary, mirroring N02's Network.framework/TLS boundary; physical-device/TestFlight smoke remains external pending Apple Developer access
- remaining: `N06` changed-file/diff UI, `N07` APNs/deep-link/background reconnect, and `N08` G1 dogfood gate remain in later queue tasks; no push/publication

### N06 — 2026-09-15

- integration commit (controller): `5832f6068c0d1c3f2a10e5d40bc48fb774c8e9c7`
- integration commit (worker source): `62e869a6a03730a9b9d7aace463c8fab61c03ba2`
- verification: N06 focused tests 12/12 passed in the worker and independently rerun by the controller; controller `make v2-foundation` passed cleanly (`v2-check` v1 boundary, all v2 targets including iOS Simulator, full `ClairV2Core` 214/214, `ClairV2Apps` 1/1) with no H04 flake this run; strict Swift format lint, `git diff --check`, and v1-boundary/print-debugPrint scans passed
- result: `ClairV2MobileKit` gains `ClairV2MobileDiffReviewController`/`ClairV2MobileDiffReviewState`/`ClairV2MobileWorkspaceReading`, a display-only surface that folds H07's changed-file/diff/hunk data with a pure client-side hunk-navigation cursor; binary diffs and truncated/large diffs (both file-level and changed-file-list-level) are surfaced as explicit flags rather than rendered as partial or garbled text; duplicate/rapid-repeat selection and navigation input is safely de-duplicated or clamped, matching N05's precedent; a dedicated test drives a full render/navigation session against the real H07 `ClairV2WorkspaceRuntime` and H03 `authorizeRead` and asserts the Git repository is byte-identical before and after, proving the surface never stages/commits/mutates the working tree; `ClairV2MobileRootView` gained a minimal Changed-files/diff/hunk section that seeds review follow-up into N05's existing prompt composer rather than adding a second command path
- known limitation: the worker's first test run deadlocked because its mock reader shared one gate pair across both `changedFileSummary` and `diff` calls; giving each method its own gate pair fixed it, verified with 12/12 passing afterward — noted here since this class of test-harness-only bug is easy to reintroduce if a future task copies this mock pattern; the P0 mock/canvas has no diff-review screen state yet (`Review.tsx` is Mac-oriented and includes working-tree-mutating actions out of scope for this read-only surface), so this task followed N05's established precedent of a minimal functional SwiftUI section without inventing production visual design, consistent with the Priority contract; live transport wiring remains the same external boundary as N05 (`ClairV2MobileUnavailableWorkspaceReading`, pending the session-start handshake)
- remaining: `N07` APNs/deep-link/background reconnect and `N08` G1 dogfood gate remain in later queue tasks; no push/publication

### N07 — 2026-09-15

- integration commit (controller): `001536830ab39fa4356ce0a7f9f620e58d360dfb`
- integration commit (worker source): `6f955343e907ca6138b2e54362332221cba7a86a`
- verification: N07 focused tests 24/24 passed in the worker and independently rerun by the controller; controller `make v2-foundation` passed (`v2-check` v1 boundary, all v2 targets including iOS Simulator, `ClairV2Apps` 1/1 with `ClairV2MobilePushDelegate`'s `#if canImport(UIKit)` guard confirmed inert on the macOS build); a full serial `ClairV2Core` rerun showed 5 issues confined to the pre-existing H04 process-group fixtures (`h04ProcessGroupClaimFailureRetainsRealDescendantCleanupState`, `h04LateProcessGroupClaimCannotReassertPendingCleanupAfterExit`), both of which passed when rerun alone — the same non-deterministic pre-existing H04 timing flake already recorded against H06/H07/N04/N05/N06, not caused by N07; strict Swift format lint, `git diff --check`, and v1-boundary/print-debugPrint scans passed
- result: `ClairV2MobileKit` gains `ClairV2MobileReconnectController`, a typed deterministic state machine for scene lifecycle (launched/foregrounded/backgrounded/pushWake), deep links (`clair://open?project=&session=...`, parsed only into the existing `ResourceScope`/`ClairHostID` types, session-scope only — project/worktree-only links are rejected as an undefined destination rather than inventing native-only navigation), and background reconnect; every transition is independently re-verified against the host through a `ClairV2MobileSessionVerifying` boundary before being trusted (a cached or deep-link-claimed host/session/revision is never treated as current without verification), reusing `ReplayCursor` for H08 gap/resync semantics without linking daemon-only `ClairV2DaemonKit`; `ClairV2MobileRootView` gained a third minimal section (alongside N05/N06) wired to `onAppear`/`onOpenURL`/`scenePhase`; a thin `#if canImport(UIKit)` `ClairV2MobilePushDelegate` bridges APNs registration/notification categories/remote-notification payloads to the tested actor with no logic of its own
- known limitation: the physical-device APNs smoke test required by this task's acceptance text remains an explicit external dependency pending Apple Developer/APNs production access (same boundary already recorded for `N01`/`H09`); entitlements/Info.plist/background-mode capabilities were not added (out of this task's owned paths and reserved signing/shared-asset territory); the worker acquired its task lease after implementing and committing rather than before (a procedural deviation from the worker contract's ordering) — the lease was confirmed valid and uniquely held with no other claimant, so no correction was needed, but this ordering slip is recorded for visibility
- remaining: `N08` G1 dogfood gate (requires `H10`, `N06`, `N07` all done) remains; no push/publication

### H10 — 2026-09-15

- integration commits (controller): `154b23a`, `c658df6`, `9c0791b`, `8656a01`, `f8a923a`, `b53c3ac`, `2a96ba3`
- integration commits (worker source): `37f8c1a0d2b965f12fa396cd9f2e4f1c022b0980`, `16da9df42568585e55ed9f6033652ce4d4b74851`, `832b81d4034742fd7e389183219b5958aa8421a4`, `4f4d9a8840158c1f6de29253b674ab9b3c04a8f4`, `ee4be8796b8bf5719e6c6a6962d7616c276d29dd`, `3435ea2695c0b2bb0ac74664a5879655be8e12f5`, `9177385e384b110f5886ee7f28eb8837d479e966`
- independent D5 review: the first review found lifecycle, cleanup-pending, generation-accounting, terminal-journal, and scope-oracle blockers; the worker repaired them with fail-closed resource retention, H04 lifecycle observation, provider-process-group ownership, and explicit resume authorization; the final fresh review of clean `84d94c6..9177385` approved with no P0/P1/P2 findings
- verification: worker H10 focused tests 18/18 passed and controller H10 focused tests 18/18 passed; `./scripts/v2-foundation.sh check` and `./scripts/v2-foundation.sh build` passed on the controller, including the `ClairDaemon` executable composition; `ClairV2Apps` 1/1 passed; strict Swift format lint and `git diff --check` passed after integration cleanup
- result: `ClairDaemonHost` now composes H03-H09 with daemon-wide agent/journal/subscriber limits, structured redacted diagnostics, scoped resume authorization, race-safe slot and generation accounting, attach rollback, terminal journal closure, and fail-closed cleanup-pending propagation across H04/H06/H08; H04's daemon-owned process-group keeper reaps provider descendants after abnormal daemon termination; the H10 fixture client drives the complete G1 server operation set without a GUI
- known limitation: the production executable intentionally uses an empty project/provider catalog and an unavailable push relay until later product configuration supplies real projects, provider credentials, and APNs transport; no Apple credential, physical device, push publication, or deployment was used; a full ClairV2Core run remains subject to the repository's known H04 process-group/waitID fixture timing flake, while the focused H10 and Apps gates are green
- remaining: `T02` daemon terminal backend must complete before `N08` G1 Mobile-on-Clair dogfood; the external iPhone/iPad, Apple signing, and APNs gate remain required after that; no push/publication

### Execution-order correction — 2026-09-15

- rationale: 製品 README と ADR-0011 は coding agent を raw terminal/PTY 上で扱うことを正本としている。一方、H10 の fixture は `/bin/sh` を起動し、H06 の effect を fixture endpoint に記録するだけで、実 provider process への input/output wiring を検証していなかった。
- decision: `T02` の daemon-owned PTY/process/session backend と raw agent I/O bridge を `N08` の前提へ前倒しする。`T01` の Ghostty rendering surface と full terminal integration は G1 後に残し、editor track は引き続き G1 後に開始する。
- status: controller が `T02` を `active` に変更した。統合前の queue/lease state を再検証し、worker は queue correction 後に記録した clean integration HEAD から開始する。no push/publication

### T02 — 2026-09-15

- integration commit (controller): 本コミット
- integration commit (worker source): `3fb2642a72b0214e0d72b47ff38af3d9dd88df34`(worker branch `codex/v2-t02-daemon-pty`, base `59883ea0bb879677149f8b8831ff41af868c17db`)
- 独立 D5 review: `create_thread` 相当の別 Codex レビュアーを起動できるツールがこのコントローラーセッションに存在しなかったため、ユーザーに確認のうえ D5 ダウングレード(コントローラー自身によるレビュー)として実施した。native PTY supervisor(C)、`ClairV2PTYAgentProcess`、`ClairV2TerminalBoundary`/journal/frame 実装、`ClairDaemonHost`/`main.swift` の配線を含む全差分を精査し、特に retry 時の入力二重コミット懸念(`commitAuthorizedOperation` が `authorize` の結果を破棄する箇所)を追跡したが、実際の冪等性保証はセッション単位の `OperationLedger`(`ClairV2TerminalBoundary.commitLocked`)にあり、`t02InputOrderingDedupeScopeAndCapacity` が `duplicate` 時に write が増えないことを直接検証済みであることを確認した。blocking finding なし、approved。
- verification: worker 報告どおり T02 focused 20/20、`t02|h10` フィルタ 38/38 を独立して再実行し成功。C strict syntax check (`clang -Wall -Wextra -Werror -fsyntax-only`)、`swift format lint --strict`(変更ファイル)、`git diff --check` はいずれも exit 0。`./scripts/v2-foundation.sh check` を実行したところ、このマシンに `ripgrep` 実体が無く v1 境界スキャンが `set -e` の `if` 例外規則で無音スキップされることが判明したため、同等の `grep -rnE` を手動実行し v1 依存混入が無いことを確認した(この欠落はスクリプト/環境側の既知の問題であり T02 の差分に起因しない)。`./scripts/v2-foundation.sh build` は core/apps/iOS Simulator 全ターゲットで成功。`./scripts/v2-foundation.sh test`(フル `ClairV2Core`/`ClairV2Apps`)はフル並列実行で 2 回とも異なる少数の timing 系テスト(1 回目: `ClairDaemonRuntimeTests` の 3 件 `.transportTimedOut` と既知の `h04LongLivedWaitID...` 系 1 件; 2 回目: `h04InvalidTerminationCallbackRetainsHandleUntilRealCleanupCompletes` 1 件)が失敗したが、統合前の base(`5454915`)でも同じ対象テストを単体実行すると成功し、統合後ツリーでも該当テストを単体実行するとすべて成功した。既存 queue に繰り返し記録されている H04 まわりの非決定的タイミング flake(H06/H07/N04/N05/N06/H10 で既出)と同種の、フル並列実行時のみ再現する既知の環境要因であり、T02 のロジック起因ではないと判断した。
- result: `ClairDaemon` に `ClairV2PTYAgentProcessFactory`/`ClairV2PTYAgentProcess`(native PTY supervisor 経由の raw stdin/stdout/stderr、child reaping、descriptor 継承の遮断)、`ClairV2TerminalBoundary`(認証済み attach/read/acknowledge/detach、bounded journal、resize owner、raw input FIFO と operation dedupe)を追加し、`ClairDaemonHost.attach` が endpoint 省略時にこの raw process/boundary を自動配線するようにした。`main.swift` は `--project-root`/`--opencode-executable`/`--opencode-version` を受け取って `ClairV2OpenCodeProvider` を登録し、環境変数は `HOME/PATH/LANG/TMPDIR/XDG_CONFIG_HOME/XDG_DATA_HOME` のみ継承する。
- known limitation: 実 OpenCode 実行ファイルを使った検証は worker が `T02_OPENCODE_EXECUTABLE` 経由で実施済み(本統合では未再実行)。物理 iPhone/APNs、実 provider credential、mobile transport 経路への接続は本タスクの完了証拠に含まれない。フル `ClairV2Core` 実行時のみ再現する上記の非決定的 timing flake は今回も解消されておらず、今後のタスクでも継続して観測される可能性がある。
- remaining: `N08`(G1 Mobile-on-Clair dogfood, 実機/APNs/実 provider 前提)、`T03`/`T04` 以降の terminal track が残る。no push/publication
