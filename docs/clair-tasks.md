# Clair 実行タスク一覧

Status: active execution queue
Date: 2026-09-22

仕様の正本は [`clair-spec.md`](clair-spec.md)。進捗の可視化は
[`clair-kanban.html`](clair-kanban.html)。この表が実行順序の正本であり、
`.agents/skills/clair-task/scripts/task_lease.py` が機械的に読む。

## 表の規約

- status は `next` / `queued` / `active` / `blocked` / `done` のいずれか。
- difficulty は `D1`〜`D5`。`D5` は独立レビュー必須。
- 行の書式(`| \`ID\` | \`status\` | \`D#\` | deps | outcome |`)は lease helper が
  parse する。崩さない。
- status と実行証跡を編集するのは controller のみ。worker は queue を編集しない。
- `done` は「統合済みブランチが完了条件を満たす」ことを意味する。worker ブランチ
  だけで満たした状態は `done` にしない。
- `blocked` は本物のユーザー gate か外部前提のみ。回復可能な実装失敗は `active`
  のまま残す。

## 優先度

- **P0** — v1 廃止に伴う整理。他のすべてに先行する。
- **P1** — 仕様の中核が実アプリで成立していない箇所。daily-driver の前提。
- **P2** — UI 一致と最終 QA。
- **P3** — 実機・人手 gate。外部依存があり日程を約束しない。

## 2026-09-21 の再編

ccedit(旧 Clair v1)を製品・資料ともに廃止した。これに伴い:

- `U08` を「v1 全削除」に置き換え、依存を外した(QA 待ちにしない)。旧 UI の
  cutover 判定は不要になり、単純な削除作業になった。
- `B04` を追加。コードから `v2` の命名を除去する。製品に v1/v2 の区別は無い。
- 仕様レビューで見つかった「core は実装済みだが実アプリに配線されていない」
  gap を `E11`/`E12`/`T09`/`N10` として明示した。これらは queue に存在しないまま
  「done 扱いの core」と「動かない実アプリ」の乖離を生んでいた。
- `E13`/`E14`/`V11` を追加。仕様 §5.11 と §9 が要求していて未実装の項目。
- `U03` の依存から `N08`(実機 dogfood gate)を外した。UI の実装が dogfood gate の
  完了を待つ理由はない。
- `V10` の依存から未定義の `G2` を外した。

## 2026-09-22 macOS dogfood review

実アプリの動作確認で見つかった問題を、症状だけで閉じず次の実行先へ割り当てた。

- App shell / navigation / motion は `U04`、editor chrome と切替性能は `U05`、terminal chrome と視認性は `U06` の残作業へ追加。
- syntax highlight は既存の `E11`、検索の main-thread stall と mock 乖離は既存の `V05`、Git sidebar / branch / pull / push は既存の `V06` の完了条件へ追加。
- Project tab と file tree の状態不一致、pane focus の遅延は同期 I/O を含む workspace state 問題として `V12` に分離。
- AI provider の残り使用量は表示だけでなくデータ源が欠けているため `H11` に分離。
- 動かない Debug navigation は見た目だけ直さず、仕様 §13 の DAP/Delve 実装として `V13` に分離。実装まで navigation を有効な操作に見せない。

## 残りタスク

| task | status | difficulty | depends | outcome |
|---|---|---|---|---|
| `U08` | `done` | `D3` | — | **P0**。v1 を全削除する。`apple/ClairApp`、`apple/ClairMobileApp`、`apple/ClairTests`、`apple/ClairTextKit`、`editor-web`、`Clair.xcodeproj`/`Clair.xcworkspace`、v1 専用 Makefile lane(`build-editor-web`、`build-stable`、`build-dev`、`run-stable`、`run-dev`、`test-swift`、`smoke-bundles` 等)、v1 専用 scripts、v1 前提の CI job を削除する。Rust crates(`crates/`、`Cargo.toml`、`test-rust`/`lint-rust`)は Swift 側が使っていないので同時に削除するが、削除前に `clair-ptyhost` に v2 が依存していないことを確認する。復元は archive tag からのみ。あわせて `README.md` の v1 前提の記述(`make run-dev`/`make test`/リポジトリ構成図/Rust CLI 説明)と `docs/runbooks/` を現状へ更新する。削除後に `make ci` に相当する経路が通ること。 **完了(2026-09-21、629337f)**: v1(`apple/` の v1 3 dir、`editor-web`、Clair.xcodeproj/xcworkspace、`crates/`、`Cargo.*`、`packages/ClairMobileKit`、v1 の `Config/*.xcconfig`、v1 専用 scripts 15 本、`stable-release.yml`)を削除。Makefile を v2 lane のみへ、`doctor.sh` から Rust を除去、README と runbooks を更新。`make lint`、`check` は通過、`test` は 224 件通過。`make ci` が通ることを確認済み。iOS の cross-build が落ちていた既存の不具合(`ClairWorkspace` の `Process`/FSEvents を `#if os(macOS)` で分離)と、不安定だった `EditorBenchmarkTests` の noop 計測を修正した。v2 の署名 update 用 release workflow は `V09` で新設が必要(`generate-update-*.swift` は残置)。 |
| `B04` | `done` | `D3` | `U08` | **P0**。コードから `v2` の命名を除去する(仕様 §4)。`ClairV2Core`→`ClairCore` 等の package/target/module、`ClairV2*` の型名、`clair-v2-*` のファイル名、`ClairV2Mobile.xcodeproj`、`v2-*` の Makefile target と scripts、`CLAIR_CHANNEL` 以外の v2 由来の識別子。bundle ID と data 領域(`Clair v2`/`Clair Dev v2`)も改名するため、既存 workspace.json の移行経路を用意する(ADR-0008 の identity 契約を壊さない)。機械的な rename を 1 コミットにまとめ、意味のある変更を混ぜない。 **完了 (2026-09-21)**: `ClairV2*`→`Clair*`(package `ClairCore`/`ClairApps`、全 target・型・ファイル)、`ClairV2Mobile.xcodeproj`→`ClairMobile.xcodeproj`、`v2-*` の scripts と Makefile target(`build`/`test`/`check`/`foundation` 等)、`CLAIR_V2_*` 環境変数を rename。data 領域は ADR-0008 どおり `Clair`/`Clair Dev` に戻し、旧 `Clair v2`/`Clair Dev v2` の `workspace.json` を初回のみ移す `ClairChannel.migrateLegacyWorkspace`(既存を上書きしない、test 付き)を追加。bundle ID は元から `v2` を含まず変更なし。**据え置き**: Keychain service `com.diwamoto.clair.mobile.v2`(改名すると保存済みの pairing 秘密が孤立するため。移行は別タスク)。**検証**: `make lint`/`check`/`build`/`mobile-build`/`build-mobile-simulator` 通過、`ClairApps` test 通過。`testCutDeletesSelectionAfterWritingToPasteboard` は並列実行時のみ失敗し、rename 前の base でも同じ失敗(既存の flake)。ディスク上の `.cache/v2-ghostty` は `.cache/ghostty` へ移す必要あり。 |
| `T09` | `done` | `D5` | `T02`, `T04`, `T03` | **P1**。Mac GUI の terminal を daemon 所有 session へ付け替える(仕様 §7)。現状 GUI は `ClairLocalShellSession` で自前 PTY を持ち、`ClairMacApp` は daemon を起動も接続もしていないため、「Mac と mobile は同じ session の別 surface」が実アプリで成立していない。GUI から daemon の single-instance を起動・接続し、surface を `attach`/`detach` で session に繋ぎ、window を閉じても session が継続すること。既存の journal/epoch/cursor/gap-resync(`H08`/`T04`)をそのまま使い、GUI 専用の側路を作らない。Mac と mobile の同時入力が同じ PTY に到着順で適用されること。D5 独立レビュー必須。**完了(2026-09-21)**: daemon が login shell を所有し(`ClairLocalTerminalHost`)、agent session と同じ `ClairTerminalBoundary`(journal/epoch/cursor/gap/入力 FIFO)に載せた。control socket に same-user 限定の terminal open/read/input/resize/close を追加(peer uid 検査)、Ghostty surface の child は `clair attach`、GUI は daemon を起動し pane.close で shell を終了、quit で daemon 停止。GUI は PTY を持たない(`ClairLocalShellSession` は daemon 側へ移動、surface の `session` は test 専用の任意引数)。D5 独立レビュー(opus。fable が利用上限のためユーザー承認の下で代替)で BLOCKER 1 / MAJOR 3 を指摘 → 修正 → 再レビュー APPROVE。test 8 件(detach/reattach、Mac+paired mobile の同一 PTY と入力順、4200 入力、slot 解放、cwd/command 不一致、exit 後の reopen、resize/close、拒否)+ integration 108 件 + iOS build 通過、実バイナリ e2e で detach/再 attach 後も同一 pid。**残(別タスク/follow-up)**: 実 GUI での目視確認、mobile からの shell 発見・grant(`N10`/`T07`。default grant に `local-terminal` は含まれず、closed pane は mobile 側で staleSession になる)、update 再起動時の reattach(`V09`。現状 quit は daemon 停止)、long-poll が GCD worker を占有、既存事項として遠隔入力は session あたり 4096 op で頭打ち(boundary の ledger)。 |
| `E11` | `queued` | `D4` | `E05`, `U05` | **P1**。syntax highlight を実ファイルで色として出す(仕様 §5.11)。現状 `SyntaxParser`(E05)には `ClairEditorLanguage` の外に呼び出し元が無く、`ClairEditorView.highlights` は常に空。日常的に使う言語の tree-sitter grammar を vendor し(Swift、Go、TypeScript/JS、Python、JSON、Markdown、Rust、shell を最低線)、parse 結果の capture を `EditorTokenKind` へ対応づけ、`EditorBuffers` から view へ渡す。`INV-PERF-005`(cancellable background、入力を止めない、欠けても正しさは損なわれない)と `INV-REV-002`(属性変更は revision を進めない)を満たすこと。差分 parse で 10 MiB fixture の打鍵が回帰しないことを計測する。**dogfood review (2026-09-22)**: 実アプリで highlight がまったく色として出ないことを再確認。fixture だけでなく Project から開いた各対象言語の実ファイルで capture→token→描画を通す UI regression test と目視確認を完了条件にする。 |
| `E12` | `queued` | `D5` | `E05`, `E11` | **P1**。LSP を実アプリに配線する(仕様 §5.11、§9)。現状 `LSPDocumentSession` の呼び出し元は test だけで、language server を起動する経路が無く diagnostic も補完も出ない。server の起動・停止・crash 再起動、`ClairEditorView.diagnostics` への表示、補完、定義ジャンプ、参照検索、symbol 検索(palette の symbol 到達)を実装する。最初の第一級は gopls(仕様 §13)、それ以外は汎用経路で動けばよい。revision で stale な結果を拒否すること(`INV-REV-004`)。D5 独立レビュー必須。 |
| `V09` | `active` | `D4` | `H01`, `T02`, `T09` | **P1**。Stable/Dev identity、署名 update、sleep 抑止は実装済み(test 7 件)。**残**: update restart 時の PTY reattach。これは GUI が daemon 所有 session を使うことが前提なので `T09` の後に行う。実 `.app` への適用確認も残る。 |
| `V03` | `active` | `D5` | `V01`, `V02` | **P1**。`clair mcp serve` の stdio MCP adapter。実装と threat test(4 件 + IPC 4 件)は完了。**残**: D5 独立レビュー(人手 gate)。 |
| `V06` | `active` | `D5` | `V01`, `V04`, `H07`, `E09` | **P1**。Git/worktree workflow。stage/commit/switch、managed worktree、branch review(committed/uncommitted/untracked 分離)を実装済み(test 5 件)。conflict は abort して agent へ再依頼(原則 6 が許す経路)。**dogfood review (2026-09-22)**: Git sidebar が実用画面として成立しておらず、左下の branch picker と pull/push ボタンも未配線。Git sidebar から status/diff/stage/unstage/commit を実操作できること、branch 一覧取得・切替が workspace state と同期すること、pull/push は typed command として実行し進行中/成功/失敗/認証要求を表示することを完了条件へ追加する。Git なし Project では表示しない。**残**: 上記 GUI 配線、D5 独立レビュー。 |
| `V05` | `done` | `D4` | `V01`, `E04`, `V04` | **P1**。Quick Open、全文検索・置換、FSEvents watcher、local history を実装。**dogfood follow-up 完了(2026-09-22)**: 検索を titlebar の typed command (`palette.search`, `⌘⇧F`) から開く Workbench mock 準拠の overlay へ統合し、query、進行中、file group、件数、empty/error、keyboard/hover 選択、file/line 遷移を実装。検索は 250 ms debounce + cancellable detached task と generation guard で古い結果を拒否し、一括置換も別の detached task で UI を止めない。重複していた sidebar の検索 destination は削除。`WorkbenchCommandTests` / `WorkbenchSearchTests` 13 件通過、10,000 files の scan 0.371s・rank 0.006s、native snapshot で overlay を視覚照合。 |
| `V11` | `done` | `D3` | `V01`, `V02` | **P1**。仕様 §9 の未実装分。(1) shortcut を任意 command へユーザーが割り当てられるようにする(現状 shortcut は registry の固定 projection)。(2) `clair open path:line:column` を実装する(現状 CLI は `mcp serve` のみ)。path を所有する open Project の active pane へ開き、該当 Project が無ければ新規 Project として開く。 **完了(2026-09-21)**: (1) `file.open`(absolute path + 任意 `line`)を registry に追加。path を所有する open Project(入れ子は最深の root)へ切り替えて tab を開き、無ければ最寄りの Git root(無ければ file の folder)を新規 Project として開く。scan 対象外(`node_modules` 等/上限超)の file も開ける。`ai: false`(agent が読める範囲を勝手に広げない)。`clair open path:line:col` はこれに配線し、相対 path は CLI 側の cwd で絶対化する。line は editor の reveal へ渡す。(2) `shortcut.set`(command, shortcut)を追加。割り当ては `WorkbenchState.shortcuts` に持ち保存・復元され、メニューとパレットの hint は registry 既定ではなく有効な shortcut を投影する。`""` で既定を解除、`⇧⌘x`→`⌘⇧X` に正規化、⌃⌥⌘ を含まない key・重複・引数必須の command・未知の command は拒否。`ai: false`。test 追加(owner/入れ子/Git root/folder、不正入力、割り当て・衝突・解除・保存)。`make lint`/`build`/`test`/`mobile-build` 通過。**残**: col は editor の reveal が line 専用のため未反映、shortcut の割り当て UI(設定画面)は無く CLI/`shortcut.set` 経由のみ、実 GUI での目視確認。 |
| `E14` | `queued` | `D3` | `E03`, `U05` | **P2**。multi-cursor の UI 手段を仕様 §5.5 の水準に上げる。core(`TextSelectionSet`、`TextSelection.rectangular`、1 undo 単位)は実装済みだが、UI からは ⌘クリックの cursor 追加しか使えない。⌘D(次の一致を選択)、⌥ドラッグの矩形選択、ダブル/トリプルクリックの語/行選択を追加する。あわせて editor pane の file サイズ上限(現 10,000,000 bytes)を canonical fixture `10mb`(10,485,760 bytes)が開ける値へ直す(仕様 §5.9)。 |
| `E13` | `queued` | `D4` | `E05`, `E06`, `E11` | **P2**。code folding と soft wrap(仕様 §5.11)。どちらも core/view に実体が無い。fold 範囲は tree-sitter の構文範囲から導出し、fold state は `INV-TXN-003` の position mapping を通して編集に追従させる。fold された行をまたぐ caret 移動・検索・review anchor の扱いを決めること。soft wrap は `INV-PERF-001`/`003` を壊さない(長い 1 行も viewport 制限経路で扱う)。minimap は対象外(仕様 §14)。 |
| `U04` | `done` | `D3` | `U02`, `E07`, `T03` | **P2**。macOS AppShell、titlebar、sidebar、pane/tab、status bar、command/settings を Workbench mock に合わせる。**dogfood follow-up 完了(2026-09-22)**: window chrome を一段へ統合し、偽 traffic light を除去、Project tab の間隔と hover fade、left navigation の hover/selection、未実装 Debug の disabled/準備中表示、settings destination の token 準拠 cross-fade(reduced-motion 時は即時)を実装。native build 成功後、実アプリで二重 titlebar/traffic light が再現しないこと、File / Git / Terminal navigation が内容を切り替えること、Debug が無反応な有効操作に見えないこと、一般→エディタ→ターミナルの連続切替が即時反映されることを目視・Accessibility tree で確認。quota は `H11`、highlight は `E11` へ分離。 |
| `U05` | `active` | `D4` | `U04`, `E07`, `E09`, `V01` | **P2**。Mac の editor / diff / review / context menu を mock に合わせる。slice 11 まで完了(実ファイル接続、変更一覧+stage、diff pane、review thread 永続化、hunk ナビ、agent へ送る、コミット欄、行ドリフト追従、1 行 suggestion)。**dogfood review (2026-09-22)**: editor の scroll indicator が AppKit 既定のまま。track/background を透明にし、thumb のみを現在より角張った token 準拠形状で描画し、hover/drag/overlay scroller、Light/Dark、アクセシビリティ設定を壊さないこと。また editor tab/file 切替に約 1 秒かかるため、同期 file read・buffer/view 再生成・layout の各区間を計測し、I/O と準備を cancellable background task に移し、選択変更への即時フィードバックと stale result rejection を入れる。連続切替と 10 MiB fixture の回帰 test を追加する。**残**: 上記修正と実機確認。highlight は `E11`、multi-cursor UI は `E14` へ分離。 **進捗(2026-09-22)**: file 読込と buffer 生成を background へ(切替は breadcrumb 即表示、drop 時は revision で stale 破棄)。scroll indicator を track なし・角張った knob の overlay scroller へ。**残**: 10 MiB での切替計測・連続切替 test、実機確認。 |
| `U06` | `active` | `D3` | `U04`, `T03`, `V01` | **P2**。Mac の terminal / session list / 承認面を mock に合わせる。通知履歴、session list、承認カード、status bar 実データ化まで完了。描画性能は flood 下の main stall が overlay 有無で 5.3→5.7ms で悪化なし(2026-09-21 計測、`ClairGhosttyFloodPerfTests`)。**dogfood review (2026-09-22)**: (1) terminal 全体が選択されたように見える focus/cursor 表現を止め、非 active pane の caret 点滅を止める、(2) ANSI palette/foreground/contrast が薄いので mock と可読性基準へ合わせる、(3) panel header の terminal title/label を外し、三点リーダの drag handle を上端中央へ置く、(4) Agent 専用 panel は削除し、agent は raw terminal session として terminal panel に統合する。描画・選択・IME・copy/paste の意味は変えない。**残**: 上記修正、実機目視、GPU frame time 計測。 **進捗(2026-09-22)**: panel header の label を除き drag handle を中央へ。**残**: focus/caret 表現、ANSI palette(ghostty config へ palette を渡す API が未整備)、Agent 専用 panel の統合、GPU 計測。 |
| `V12` | `active` | `D4` | `V04`, `U04` | **P1**。Project/pane interaction の正しさと応答性を直す。**dogfood review (2026-09-22)**: project tab をクリックしても file tree が対象 Project へ切り替わらず、pane 間 focus 切替も遅い。`project.switch` を一つの atomic state transition にし、project root・file tree・tabs・active editor・Git/terminal context が同じ Project identity を参照すること。file tree は各階層で folder を先、file を後にし、それぞれ stable な名前順にする。同期 directory scan / Git status / workspace restore を main thread から外し、切替世代が古い結果を捨て、選択表示は即時更新する。rapid project switching、tree ordering、pane focus cycling の regression test、fixture Project での signpost 計測を追加し、interaction path の main-thread stall が 60 Hz frame budget を継続して超えないこと。 **進捗(2026-09-22)**: file tree を各階層で folder 先・名前順に(`WorkbenchFiles.treeOrder`、test 2 件)、折りたたみ判定を 1 pass 化(行ごとの全 collapsed 走査を除去)、再訪 Project は cache した tree で即時切替し scan は background で更新。**残**: 初回 open の同期 scan / workspace restore、pane focus の signpost 計測、rapid switch の regression test。 |
| `H11` | `queued` | `D4` | `H05`, `U04` | **P2**。AI provider の残り使用量を status footer に戻す。旧 Clair にあった provider quota/remaining 表示を、screen scraping ではなく provider の公式 API/hook または根拠のある usage event から取得する。provider ごとの window、使用量/残量、reset 時刻、取得時刻を正規化し、利用不可・未対応・認証切れ・stale を明示する。取得は background で rate-limit/cancel 可能にし、Project/terminal 切替を止めない。OpenCode/Codex/Claude Code のうち取得可能な provider を実データで検証し、取得不能な provider は偽の数値を出さない。 |
| `V13` | `queued` | `D5` | `V01`, `V04`, `U04` | **P2**。左 navigation の Debug を実機能へ接続する(仕様 §13)。DAP を共通 transport/model とし、Go/Delve を最初の第一級 debugger にする。launch/attach、configuration、breakpoint、continue/pause/step、stack/threads、variables、console、終了/crash を typed command と sidebar/pane UI に配線し、Project/worktree identity を保持する。未設定・Delve 未導入・接続失敗を明示し、実装完了までは Debug navigation を disabled/準備中表示にして無反応にしない。D5 独立レビュー必須。 |
| `N10` | `queued` | `D4` | `E08`, `T05`, `N04`, `N12`, `N13` | **P2**。mobile app に editor / terminal surface を配線する。`E08`(iOS editor)と `T05`(iOS terminal)の core を、実際に接続・認証済みの client composition 上で editor / terminal 画面として出す。仕様 §10 の terminal attach と入力、ファイルの段階的読み込みを実画面として提供する。mobile に full source editor を移植することは必須にしない。 |
| `N11` | `active` | `D5` | `H03`, `T04`, `N02` | **P1**。遠隔 client 用の host network transport。承認済み ADR-0016 に従い、host signing key と device grant を永続化し、loopback TLS 1.3 listener、既存 pairing/authorization/terminal boundary を結ぶ request/response wire protocol、resource limit と revoke 時の live channel close を実装する。mobile adapter と app composition は `N12`/`N13` に分離する。D5 独立レビュー必須。 |
| `N12` | `queued` | `D4` | `N11` | **P1**。ADR-0016 に従い、mobile 側の TLS-pinned Network.framework adapter を実装する。`ClairMobileTerminalTransport`、agent、workspace、verifier、push の各 boundary を既存の wire protocol に載せ、`ClairAuthenticatedConnection` の client 用不活性 initializer を追加する。`ClairDaemonKit` を mobile module へ link しない。 |
| `N13` | `queued` | `D3` | `N12` | **P1**。`ClairMobileClient` をアプリ composition root へ接続し、接続 generation と認証済み connection を conversation、diff、terminal surface へ供給する。reconnect / stale generation / endpoint pin failure を UI state として表示する。 |
| `U03` | `queued` | `D3` | `U02`, `N10` | **P2**。mobile の host/project/session/activity/review/notification navigation を mock contract に合わせる。compact/regular size class と safe area に適応しつつ情報階層を変えない。 |
| `U07` | `queued` | `D4` | `U05`, `U06`, `E11`, `E14`, `V12`, `H11`, `V13` | **P2**。screenshot/interaction regression、VoiceOver、Dynamic Type、keyboard-only、reduced motion、contrast の final QA。2026-09-22 dogfood review の titlebar/tab/sidebar/editor/terminal/search/Git/quota/debugger 修正を実アプリで再確認し、差分は canvas 変更か native bug のどちらかへ分類する。Mac 分を先に行い、iOS 分は `N10`/`U03` が揃ってから追い QA とする。 |
| `T07` | `queued` | `D5` | `T04`, `T06`, `T09` | **P3**。terminal integration gate。OpenCode TUI、shell、resize、alternate screen、flood、sleep/wake、network switch、Mac/mobile 同時入力、reattach、OSC 52/633 の実機 test と resource limits。`T09` の後でなければ「同じ session への同時入力」を実アプリで検証できない。 |
| `N08` | `blocked` | `D5` | `H10`, `N06`, `N07`, `T02`, `N09`, `N13` | **P3**。Mobile-on-Clair dogfood gate。iPhone だけを操作して実 terminal session 上で agent を起動し、依頼・承認・diff 確認・follow-up・完了通知・再接続まで行う。**Blocked**: iPhone/iPad 実機、Apple signing、APNs の外部依存。`N09` で Mac 側ペアリング bootstrap 面は解消済み。 |
| `V10` | `queued` | `D5` | `V02`, `V03`, `V04`, `V05`, `V06`, `V07`, `V08`, `V09`, `T09`, `E11`, `U04`, `U05`, `U06`, `V12`, `H11` | **P3**。Clair-on-Clair cutover gate。Stable から Clair source を開き、terminal/agent で Dev を build・起動して変更を確認できる。2026-09-22 dogfood review の daily-driver blocker が解消され、ccedit より快適と本人が確認する。CLI/MCP 経由の scripted 操作でも同じ流れが通ること。Debugger (`V13`) は仕様 §13 の後続ロードマップであり cutover 条件には含めないが、未実装中の navigation は `U04` で無反応に見せない。 |

## 完了タスク

証跡の詳細は Git 履歴と各タスクの設計 doc にある。

| task | status | difficulty | depends | outcome |
|---|---|---|---|---|
| `B00` | `done` | `D2` | — | pre-rewrite checkpoint commit と archive tag。 |
| `B01` | `done` | `D3` | `B00` | Swift packages、macOS app、iOS app、daemon executable の target と build/test lane。 |
| `B02` | `done` | `D3` | `B00` | native mobile + APNs 方針の ADR(0015)。PWA 優先の旧方針を superseded に接続。 |
| `B03` | `done` | `D5` | `B01` | `ProjectID`/`WorktreeID`/`SessionID`、revision、operation ID、capability、error、event envelope の共有型。 |
| `H01` | `done` | `D4` | `B03` | GUI から独立した `ClairDaemon` lifecycle、single-instance ownership、local control channel。 |
| `H02` | `done` | `D3` | `H01` | project/worktree catalog、file tree、bounded file read、changed-file summary の read-only API。 |
| `H03` | `done` | `D5` | `B02`, `B03`, `H01` | client transport、one-time pairing、device key、host fingerprint、grant scope、revoke。threat tests 通過。 |
| `H04` | `done` | `D5` | `H02` | OpenCode provider adapter。起動・再開・停止を project/worktree/session identity に関連付け。 |
| `H05` | `done` | `D5` | `H04` | provider 非依存な conversation/tool-call/attention/completion/usage イベント正規化。 |
| `H06` | `done` | `D5` | `H03`, `H05` | prompt/approval/deny/interrupt/stop を scoped command として実装。 |
| `H07` | `done` | `D4` | `H02` | Git status、changed-file list、text/binary diff、hunk metadata。 |
| `H08` | `done` | `D5` | `H03`, `H05`, `H06` | session journal、subscriber cursor、gap/resync、revision snapshot。 |
| `H09` | `done` | `D4` | `B02`, `H03` | 最小 `ClairPushRelay` と APNs provider boundary。opaque event payload。 |
| `H10` | `done` | `D5` | `H06`, `H07`, `H08`, `H09` | daemon の crash recovery、resource limits、structured diagnostics。 |
| `N01` | `done` | `D3` | `B01`, `B02` | SwiftUI native app、composition root、environment、shared package 境界。 |
| `N02` | `done` | `D4` | `B03`, `H03`, `N01` | typed client、Keychain device identity、pairing handshake、certificate 検証。 |
| `N03` | `done` | `D3` | `N02` | host list、pair/re-pair、connection state、device scope、revoke。 |
| `N04` | `done` | `D3` | `H02`, `N03` | project/worktree/session browser と recent destination。 |
| `N05` | `done` | `D4` | `H05`, `H06`, `N04` | conversation stream、prompt composer、attention、approval。 |
| `N06` | `done` | `D4` | `H07`, `N05` | changed-file list、native diff、hunk navigation、review follow-up。 |
| `N07` | `done` | `D4` | `H08`, `H09`, `N03` | APNs registration、notification category、deep link、scene lifecycle。 |
| `N09` | `done` | `D4` | `H03`, `N03` | Mac 側ペアリング bootstrap 面(`N08` が発見した gap の解消)。 |
| `E01` | `done` | `D4` | `B01` | editor invariants、Unicode corpus、10MB/long-line fixture、benchmark harness、回帰の下限。 |
| `E02` | `done` | `D5` | `E01` | rope text storage、line index、stable line ID、座標変換、immutable snapshot。 |
| `E03` | `done` | `D5` | `E02` | transaction、SelectionSet、multi-cursor、矩形選択、Undo/Redo、外部編集マージ。 |
| `E04` | `done` | `D3` | `E03` | literal/regex search、replace preview、replace one/all、選択範囲への適用。 |
| `E05` | `done` | `D4` | `E02` | Tree-sitter incremental parse と LSP coordinate/lifecycle。 |
| `E06` | `done` | `D5` | `E02`, `E05` | macOS custom `NSView`、CoreText visible-line layout、scroll、hit test、caret、selection。 |
| `E07` | `done` | `D5` | `E03`, `E06` | `NSTextInputClient`、日本語 IME、marked text、clipboard、drag/drop、accessibility。 |
| `E08` | `done` | `D5` | `E03`, `E05` | iOS/iPadOS editor surface、touch selection、hardware keyboard、IME、viewport virtualization。 |
| `E09` | `done` | `D5` | `E03`, `E05`, `N06` | revision-aware review anchor、line comment、thread、stale/orphaned、suggestion transaction。 |
| `E10` | `done` | `D5` | `E04`, `E07`, `E08`, `E09` | editor integration gate。edit/multi-cursor/search/review/save/外部編集と性能閾値。 |
| `T01` | `done` | `D5` | `B01` | libghostty の pinned build、license、resource bundle、ABI pin。 |
| `T02` | `done` | `D5` | `H01`, `H04`, `H05`, `H06`, `H08` | daemon-owned PTY/process/session ownership と raw I/O bridge。 |
| `T03` | `done` | `D4` | `T01`, `T02`, `T08` | macOS Ghostty surface を workspace に接続。selection、copy/paste、scrollback、font/DPI、resize。 |
| `T04` | `done` | `D5` | `T02`, `H08` | remote terminal binary stream、epoch/cursor、snapshot/gap、backpressure。 |
| `T05` | `done` | `D5` | `T01`, `T04`, `N01`, `T08` | iOS/iPadOS Ghostty surface と remote session attach。 |
| `T06` | `done` | `D4` | `T03`, `T05` | IME/CJK、paste guard、mouse reporting、focus、desktop-owned PTY geometry。 |
| `T08` | `done` | `D5` | `T01` | Ghostty surface ABI pin(`T03` が発見した gap の解消)。 |
| `U01` | `done` | `D2` | `B01` | Design canvas と Workbench の同期。対象 screen/state、tokens、layout の freeze。 |
| `U02` | `done` | `D3` | `U01` | canvas tokens を Swift の color/type/spacing/radius/motion primitive へ。 |
| `V01` | `done` | `D5` | `B03` | typed Command Registry(22 command)。palette/menu/shortcut を projection 化。 |
| `V02` | `done` | `D4` | `V01`, `H01` | user-scoped Unix socket IPC(0600/0700、peer uid 検証)と `clair` CLI 基盤。 |
| `V04` | `done` | `D4` | `V01`, `H02` | Project model と workspace 永続化。Git の有無を問わない folder、実 file tree、layout 復元。 |
| `V07` | `done` | `D4` | `V01`, `V04`, `T03` | agent launch profile を raw terminal で複数起動。worktree cwd 対応。 |
| `V08` | `done` | `D3` | `V04`, `V07` | Project badge、通知 history、macOS banner、Project/terminal 単位 mute。事実 signal のみ。 |

## 統計

- 完了 50 / 全 73(2026-09-22 時点)
- 残り 23(うち `N08` は blocked、人手 gate の active 8 件を含む)
- `python3 .agents/skills/clair-task/scripts/task_lease.py validate` がこの数を検証する。
