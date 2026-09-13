# Clair v2 native rewrite task queue

Status: active execution queue
Date: 2026-09-13
Parent plan: [Clair v2 native rewrite](clair-v2-native-rewrite.md)

## Purpose

この queue は Clair v2 の実装順、依存関係、難易度、完了条件の正本である。

最初のゴールは、フルエディタや完成 UI より先に、iPhone / iPad から自宅 Mac の Clair を使って Clair 自身を開発できる状態を作ることとする。Mac 側 server、OpenCode integration、ネイティブ mobile app を最優先し、その後に editor と terminal、最後に Design canvas / Clair Workbench に忠実な UI を完成させる。

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

この gate が完了するまで editor / terminal の本実装を priority lane に入れない。

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
{H10, N06, N07} -> N08 -> G1

G1 -> {E01, T01}
E01 -> E02 -> E03
E03 -> E04
E02 -> E05
{E02, E05} -> E06
{E03, E06} -> E07
{E03, E05} -> E08
{E03, E05, N06} -> E09
{E04, E07, E08, E09} -> E10

G1 -> T02
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
| `B01` | `active` | `D3` | `B00` | v2 の Swift packages、macOS app、iOS/iPadOS app、daemon executable の空 target と build/test lane を作る。旧 runtime module を link せず全 target が build すること。 |
| `B02` | `active` | `D3` | `B00` | native mobile + APNs 方針の ADR を作り、PWA 優先の ADR/P0020/roadmap を superseded として接続する。bundle ID、signing、TestFlight、push entitlement の ownership を記録すること。 |
| `B03` | `queued` | `D5` | `B01` | `ProjectID`、`WorktreeID`、`SessionID`、revision、operation ID、capability、error、event envelope の共有 protocol と invariants を定義する。version negotiation、unknown field、frame bound、replay の golden tests が通ること。 |

## P0-B: Mac host and server

| ID | Status | Difficulty | Depends on | Task and completion evidence |
|---|---|---:|---|---|
| `H01` | `queued` | `D4` | `B03` | GUI から独立して動く `ClairDaemon` lifecycle、single-instance ownership、local control channel、health/version endpoint を実装する。GUI を閉じても daemon が生存し、二重起動せず、安全に停止・再起動できること。 |
| `H02` | `queued` | `D3` | `H01` | project/worktree catalog、file tree、bounded file read、changed-file summary を read-only API として提供する。symlink、permission、missing root、巨大 file の境界 test が通ること。 |
| `H03` | `queued` | `D5` | `B02`, `B03`, `H01` | native client transport、one-time pairing、device key、host fingerprint、grant scope、revoke を実装する。default-deny、expiry、replay、stolen token、revoked active connection の threat tests が通ること。 |
| `H04` | `queued` | `D5` | `H02` | OpenCode を provider adapter の第一実装として起動・再開・停止し、project/worktree/session identity に関連付ける。provider upgrade、abnormal exit、duplicate launch、cwd mismatch を型付きで扱うこと。 |
| `H05` | `queued` | `D5` | `H04` | OpenCode の streaming event を provider-independent な conversation、tool call、attention、completion、usage event に正規化する。順序、重複、partial event、unknown event を deterministic に処理すること。 |
| `H06` | `queued` | `D5` | `H03`, `H05` | prompt、approval、deny、interrupt、stop を scoped command として実装する。operation ID による exactly-once effect、stale approval rejection、audit metadata、disconnect race の tests が通ること。 |
| `H07` | `queued` | `D4` | `H02` | Git status、changed-file list、text/binary diff、hunk metadata を mobile API に追加する。untracked、rename、large diff、invalid encoding、worktree race を壊さず表示できること。 |
| `H08` | `queued` | `D5` | `H03`, `H05`, `H06` | session journal、subscriber cursor、gap/resync、revision snapshot、idempotency window を実装する。network switch、slow client、daemon restart、out-of-range cursor で silent data loss がないこと。 |
| `H09` | `queued` | `D4` | `B02`, `H03` | 最小 `ClairPushRelay` と APNs provider boundary を実装する。opaque event だけを送り、credential rotation、device token replacement、revoke、TTL、sandbox/production 分離を検証すること。 |
| `H10` | `queued` | `D5` | `H06`, `H07`, `H08`, `H09` | daemon の crash recovery、resource limits、structured diagnostics と server integration suite を完成させる。Mac GUI なしで G1 の全 server operation を fixture client から再現できること。 |

## P0-C: Native iPhone / iPad app

| ID | Status | Difficulty | Depends on | Task and completion evidence |
|---|---|---:|---|---|
| `N01` | `queued` | `D3` | `B01`, `B02` | SwiftUI native app、composition root、environment、shared package、unit/UI test target を作る。signed physical-device build と TestFlight smoke の手順を確立すること。旧 `ClairMobileApp` は reference に留める。 |
| `N02` | `queued` | `D4` | `B03`, `H03`, `N01` | typed client、Keychain device identity、pairing handshake、certificate/host pin、capability negotiation を実装する。credential を log/UI stateへ漏らさず、再起動後に安全に reconnect できること。 |
| `N03` | `queued` | `D3` | `N02` | host list、pair/re-pair、connection state、device scope、revoke UI を最小 native UI で実装する。offline、expired QR、fingerprint change、revoked device を区別できること。 |
| `N04` | `queued` | `D3` | `H02`, `N03` | project/worktree/session browser と recent destination を実装する。複数 project を混線せず、missing root と permission error を明示すること。 |
| `N05` | `queued` | `D4` | `H05`, `H06`, `N04` | OpenCode conversation stream、prompt composer、attention、approval/deny/interrupt を native app へ接続する。重複 tap、background 中の response、stale approval が安全であること。 |
| `N06` | `queued` | `D4` | `H07`, `N05` | changed-file list、native diff、hunk navigation と review follow-up を実装する。binary/large/truncated diff を明示し、表示だけで working tree を変更しないこと。 |
| `N07` | `queued` | `D4` | `H08`, `H09`, `N03` | APNs registration、notification category、deep link、scene lifecycle、background reconnect を実装する。foreground/background/terminated から正しい host/session/revision へ戻る実機 smoke が通ること。 |
| `N08` | `queued` | `D5` | `H10`, `N06`, `N07` | G1 Mobile-on-Clair dogfood gate。iPhone だけを操作して Clair repo で OpenCode を起動し、依頼、承認、diff確認、follow-up、完了通知、再接続までを行い、fixture と実機 evidence を残すこと。 |

Apple Developer membership、Team ID、APNs key は `N01`、`H09`、`N07` の実機完了に必要な外部依存である。入会待ちの間も code、simulator、mock APNs provider、protocol tests は進めるが、G1 は実機通知を確認するまで完了にしない。

## P1-A: Clair-owned native editor

Editor track と Terminal track は G1 完了後、別 worktree で並列に進めてよい。

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
| `T02` | `queued` | `D5` | `H01`, `H08`, `N08` | PTY/process/session ownership を `ClairDaemon` に実装し、surface から分離する。stable SessionID、resize owner、bounded journal、attach/detach、child reaping を検証すること。 |
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
10. `N08` で G1 を実機判定
11. G1 後に Editor track `E01` と Terminal track `T01` / `T02` を並列開始
12. G2 後にだけ `U01` から UI track を開始

依存が未完了の task を、並列数を埋める目的で先行実装しない。

## Execution evidence

`clair-v2-orchestrator` の controller だけが、統合済み task の status と実行記録を更新する。各記録には task ID、統合日、integration commit、検証結果、明示的な残課題を含める。worker branch の完了だけでは記録しない。

### B00 — 2026-09-14

- integration commit: `882505339461471a20b647d05a5e57dc6dc313cf`
- archive tag: `archive/clair-v1-2026-09-14`
- verification: `git diff --cached --check` passed; `python3 .agents/skills/clair-v2-orchestrator/scripts/test_task_lease.py` passed (3 tests); queue validation passed before checkpoint
- restored scope: current tracked changes and 9 explicitly listed untracked repository files, including the v2 plan, queue, and orchestrator skill; ignored build/machine output was excluded
- remaining: no v2 implementation task is integrated yet; no push or publication performed
