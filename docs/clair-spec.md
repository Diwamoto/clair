# Clair 仕様書

Status: accepted — Clair の唯一の仕様正本
Date: 2026-09-21

この 1 ファイルが Clair の仕様の正本である。実行順序は
[`clair-tasks.md`](clair-tasks.md)、進捗の可視化は
[`clair-kanban.html`](clair-kanban.html)。

過去に分かれていた product vision / scope / principles、native rewrite plan、
editor invariants、review invariants はこの文書に統合し、元ファイルは削除した。
ccedit(旧 Clair v1)は 2026-09-21 に製品としても資料としても廃止した。復元は
Git の archive tag から行う。

受理済みの決定記録([`decisions/`](decisions/))はこの文書の下位にあり、
矛盾した場合はこの文書が優先する。

---

## 1. 存在理由

Clair は、Daiki が会社と自宅のどちらでも不自由なく AI を使って開発するための
personal native macOS IDE である。

VS Code の editor / navigation / Git / debugging の統合体験と、Ghostty の
terminal / pane 操作の自然さを、一つの Project workspace へ統合する。別々の
アプリを行き来すると Project、terminal、agent、worktree、diff review の
context が分断される。席を離れた後も agent を進められることにも価値がある。

Clair は agent 固有の chat UI を正本にしない。通常の shell と各 CLI の raw
terminal をそのまま使えることを保証し、その周囲に Project ownership、起動
導線、通知、diff review、command automation を加える。

## 2. 製品原則

1. **Project が workspace の所有単位**。一つの process が複数 Project を Chrome
   の tab group のように保持する。Project は Git repository でなくてよい。各
   Project は独立した editor / terminal / agent / notification / pane layout を
   持ち、非表示中も明示的に終了されるまで session を継続する。
2. **Editor と terminal を同格に扱う**。Clair は agent dashboard ではない。各
   pane は editor / terminal / diff を混在できる tab group であり、任意に split、
   移動、最大化、均等化できる。file tree / search / Git は sidebar を標準とし、
   必要なら pane へ開ける。
3. **Raw terminal を互換性の正本にする**。通常 shell、Claude Code、Codex、
   OpenCode が raw PTY として完全に使えることを優先する。agent 内容を TUI の
   screen scraping で推測しない。process lifecycle、bell、終了 code、公式 hooks
   等、根拠のある情報だけを補助表示と通知に使う。
4. **独自 editor が Clair の価値を作る**。外部 editor を前提にしない。agent に
   よる file 変更の live 反映、branch diff、merge、Project/pane integration を
   Clair 自身が所有する。VS Code extension 互換は目指さず、言語機能は LSP、
   debugger は DAP、container は Dev Container specification を利用する。
5. **Worktree は任意の execution context**。worktree は Project や agent の必須
   所有単位ではない。agent 起動時に Project root か managed worktree を選ぶ。
   managed worktree は Clair の local 管理領域に置く。
6. **Branch 全体を成果物として review する**。base branch に対する branch 全体の
   diff として review し、commit 済みと未 commit/untracked を分けて表示する。
   統合前に clean な commit 状態を要求する。採用は merge commit で行い、conflict
   は merge editor または agent への再依頼で解決する。
7. **すべての操作を command にする**。stable ID、typed parameter/result schema、
   error、risk metadata を持つ Command Registry へ登録する。palette、menu、
   shortcut、CLI、MCP は同じ command を呼ぶ。AI には `aiAvailable` な command
   だけを公開する。危険性を AI に推測させず、固定 risk と対象状態を使う
   deterministic preflight で判断する。
8. **User control と回復可能性を保つ**。agent が disk 上の file を変更した場合は
   その内容を正本とし、同じ file の未保存 buffer は破棄して live reload する。
   terminal transcript は
   session 終了後に保存しない。Claude Code、Codex、OpenCode が自身の local storage
   に保存したチャット履歴は Clair が読み取り専用で表示できる。Clair はその本文を
   複製・永続化しない。Clair の状態は Mac 内の専用 storage に保存し、
   repository を自動的に汚さない。
9. **Personal、native、macOS-only を選ぶ**。single user、自所有 device、macOS に
   最適化する。Windows/Linux、team collaboration、account system、hosted agent、
   marketplace、VS Code extension 互換のために中核を複雑化しない。
10. **体感と dogfooding を判断材料にする**。合格線は、同じ作業を ccedit より
    明確に快適に行えることとする。優先順位は一般市場の網羅性ではなく、Clair を
    使った日常開発で繰り返し発生する摩擦から決める。

## 3. 用語

- **Project**: Clair が開く local folder。Git repository でなくてよい。
- **Workspace**: Project に保存された pane/tab/sidebar の layout と表示 state。
- **Pane**: editor / terminal / diff を混在できる tab group。任意に split できる。
- **Agent terminal**: launch profile から起動した Claude Code / Codex / OpenCode
  の raw-terminal session。
- **Managed worktree**: Git Project に対して Clair が local 管理領域へ作る任意の
  isolated checkout。
- **Command**: UI、CLI、MCP から共通利用する typed operation。
- **Session**: daemon が所有する長寿命の PTY/process。Mac と mobile はその surface。

## 4. アーキテクチャ

```text
ClairApp                 SwiftUI app shell (macOS)
├── ClairEditorCore      text, coordinates, selections, transactions, undo, search
├── ClairEditorView      AppKit/UIKit viewport, CoreText renderer, IME
├── ClairEditorLanguage  Tree-sitter incremental parse, LSP coordinates/lifecycle
├── ClairReview          review anchors, threads, suggestions, revisions
├── ClairTerminal        libghostty surface, PTY/session bridge
├── ClairAgent           agent session, provider adapter, patch application
├── ClairWorkspace       projects, tabs, splits, worktrees, Git, commands
├── ClairDaemon          long-lived Mac session owner and mobile transport
├── ClairPushRelay       minimal APNs provider boundary
└── ClairMobile          SwiftUI client for iOS/iPadOS
```

SwiftUI は shell、navigation、inspector、review UI、mobile UI に使う。大量の
テキスト描画と入力の hot path は AppKit/UIKit の `NSView`/`UIView` と専用コアで
実装する。

製品ランタイムに次の経路を残さない。

- CodeMirror / `WKWebView` を使った editor
- CodeEditSourceEditor を中核にした editor
- `libvterm` を使った terminal 描画
- Rust bridge を前提にした編集・表示経路
- 旧 UI への機能フォールバック

**命名**: module / target / 型 / ファイル名に `v2` を含めない。`v2` は ccedit
からの移行期を指す一時的な語であり、製品にその区別は存在しない。

## 5. Editor

### 5.1 Text model

`ClairEditorCore` は UI フレームワークから独立させる。

- rope による部分更新
- UTF-8 / UTF-16 / extended grapheme cluster 間の座標変換
- 行インデックスと行 ID
- immutable revision と transaction ID
- 複数選択範囲・矩形選択・マルチカーソル
- 一つの transaction としての編集、Undo/Redo、外部変更の取り込み
- 検索、置換、正規表現、選択範囲への適用
- Tree-sitter の増分構文解析との同期
- LSP の UTF-16 range との変換

ドキュメント全体の `String` を入力や描画のたびに UI へ渡さない。保存、解析、
AI 連携などの境界で必要な場合だけ snapshot を生成する。

### 5.2 座標モデル (`INV-COORD-*`)

- `001` 正本は UTF-8 byte offset。UTF-16 code unit、Unicode scalar、grapheme
  cluster、行/列はすべてその派生であり、第二の正本にしない。
- `002` public API の offset はすべて座標空間で型付けする。裸の `Int` を offset
  引数にしない。
- `003` public offset は UTF-8 継続バイト、UTF-16 surrogate pair、grapheme
  cluster を分割しない。cursor 位置は cluster 境界へ外側 snap する。
- `004` caret 移動、選択拡張、後方削除は extended grapheme cluster 単位で動く。
  1 回の Delete で `👨‍👩‍👧‍👦`、`e`+結合アクセント、`\r\n` がそれぞれ 1 つ消える。
- `005` `\r\n` は 1 改行かつ 1 cluster。単独 `\r`、単独 `\n`、U+0085、U+2028、
  U+2029 も各 1 改行。`\r` と `\n` の間に座標を置かない。
- `006` LSP の UTF-16 位置は LSP 境界でのみ変換し、buffer 内部の index に
  UTF-16 offset を入れない。
- `007` core は文書内容に NFC/NFD を適用しない。正規化は明示的で undo 可能な
  ユーザー編集としてのみ提供する。
- `008` 不正な UTF-8 を暗黙に置換しない。未編集領域を無損失で round-trip する
  か、binary として拒否する。U+FFFD の暗黙代入は禁止。

### 5.3 Revision と不変性 (`INV-REV-*`)

- `001` revision は immutable かつ全順序。内容変更で厳密単調増加し、文書の
  生存期間内で再利用しない。
- `002` 属性のみの変更は content revision を進めない。syntax highlight、
  diagnostic、review decoration は内容編集ではない。
- `003` revision R の snapshot は immutable で、文書全体を複製せずどのスレッド
  からでも読める。
- `004` stale な結果は明示的に拒否するか rebase する。テキスト再検索で再適用
  しない。
- `005` 文書全体の `String` を typing hot path で materialize しない。snapshot は
  保存、parse、外部同期、AI 受け渡しの境界でのみ作る。

### 5.4 Transaction (`INV-TXN-*`)

- `001` すべての内容変更は atomic に適用される transaction を通る。新しい
  revision を 1 つ作るか、文書を変更しないかのどちらか。
- `002` 1 transaction 内の編集は transaction 前の座標空間で表現し、重ならず、
  同時に適用されたものとして扱う。これが multi-cursor 破損の構造的な対策。
- `003` 各 transaction は旧 revision から新 revision への position mapping を
  公開し、各位置を preserved / shifted / deleted に分類する。anchor、selection、
  fold、review thread はすべてこの mapping を通る。
- `004` 周囲の範囲が削除された位置は明示的に orphaned になる。隣の行へ暗黙に
  再配置しない。

### 5.5 Multi-cursor (`INV-MC-*`)

- `001` `SelectionSet` は常に非空、start offset 順、重複なし。重なる範囲は先に
  マージする。
- `002` N cursor 操作の正しさは「同じ単一 cursor 操作を transaction 前の文書の
  N 箇所へ独立に適用した結果と一致すること」で定義する。
- `003` 各 cursor は操作をまたいで identity と goal column を保つ。短い行を
  縦移動しても cursor が恒久的に合流しない。
- `004` 矩形選択は視覚列で定義し、全角グリフや cluster の内側に落ちた列は
  cluster 境界へ外側 snap する。

### 5.6 Undo (`INV-UNDO-*`)

- `001` 1 ユーザー操作 = 1 undo 単位。N cursor に適用した 1 打鍵は 1 回の Undo で
  戻る。
- `002` Undo はテキストだけでなく選択状態も復元する。
- `003` IME 変換中は undo 対象にしない。確定結果だけが 1 単位で undo stack に
  入る。
- `004` AI 提案の適用/取り消しは 1 単位。部分適用した場合、残りの hunk は新しい
  revision に対して再計算する(テキスト検索での rebase は `INV-REV-004` で禁止)。

### 5.7 外部 / agent 編集 (`INV-EXT-*`)

- `001` UI 外からの編集(file watcher、agent、LSP rename)も、base revision を
  明示した通常の transaction として扱う。特権的な側路を作らない。
- `002` stale な base に基づく外部編集は published mapping で rebase するか拒否
  する。生 offset で適用しない。
- `003` 未保存 buffer を disk 内容で暗黙に置換しない。乖離は明示的な conflict
  として提示する(原則 8 の live reload は未保存 marker の破棄であり、内容の
  暗黙上書きではない)。

### 5.8 性能 (`INV-PERF-*`)

- `001` 1 編集あたりの作業量は編集サイズと可視 viewport に比例し、文書サイズや
  行長に比例しない。これは調整目標ではなくデータ構造の要件。
- `002` 全行の eager layout や 1 行 1 View を行う経路を作らない。
- `003` 極端に長い 1 行も、多数の短い行と同じ viewport 制限経路で扱う。
- `004` 開いている文書の常駐メモリは byte サイズの小さな定数倍 + viewport 状態に
  収まる。
- `005` syntax highlight、diagnostic、search は cancellable な background 処理で、
  入力を止めない。欠けても見た目が劣化するだけで、正しさは損なわれない。
- `006` editor の hot path は WebView、JavaScript、プロセス間 serialize 境界を
  越えない。

### 5.9 回帰の下限

計測済みの失敗値は
[`EditorBaselineEvidence.swift`](../packages/ClairCore/Sources/ClairEditorFixtures/EditorBaselineEvidence.swift)
が機械可読な正本であり、性能テストは任意の数値ではなく
`regressionCeiling(fixture:metric:)` に対して assert する。代表値(Apple M4、
32 GiB、macOS 26.6.2、Swift 6.3.3 Release、~1164x710 viewport、13 pt
monospaced、wrap off、20 回反復の nearest-rank p95):

| 計測元 | 指標 | 値 |
|---|---|---|
| CodeEdit PoC / 10mb.swift | 初回ハイライト表示 | 4543.25 ms |
| CodeEdit PoC / 10mb.swift | 累積最大 RSS | 1077.7 MiB |
| CodeEdit PoC / long-line.ts | 打鍵 median / p95 | 684.86 / 693.29 ms |
| CodeEdit PoC / 10mb.swift | eager 初期 layout | >90,000 ms |
| CodeEdit PoC / multi-cursor | 1 操作に必要な Undo 回数 | 3 |
| CodeMirror+WKWebView / 10mb.swift | `setDocument` 往復 | 2997.26 ms |
| CodeMirror+WKWebView / 10mb.swift | 選択 20 回の bridge 転送量 | 209,714,700 bytes |

これらは近づく目標ではなく、決定的に上回るべき下限である。

fixture は
[`EditorFixtureGenerator.swift`](../packages/ClairCore/Sources/ClairEditorFixtures/EditorFixtureGenerator.swift)
が `10mb`(10 MiB)、`long-line`、`1mb-japanese`、`unicode-corpus` を決定的に
生成する(`scripts/editor-fixtures.sh generate`)。**UI 経路の file サイズ上限は
canonical fixture を開けるように設定する**。

### 5.10 Rendering と入力

`ClairEditorView` は行ごとの SwiftUI View を作らず、可視 viewport の行だけを
CoreText で描画する。

- 可視行の glyph/run をキャッシュする
- 変更された行とその周辺だけを再レイアウトする
- 高速スクロール時は表示用キャッシュを優先する
- caret、selection、composition、diagnostic、review marker を同じ座標系で描画する
- macOS は `NSTextInputClient`、iOS は `UITextInput` を実装し、日本語 IME、
  marked text、確定、delete を正しく扱う
- copy/paste、drag/drop、undo、accessibility、system text cursor の契約を守る

macOS の `NSTextInputClient` は行ローカルの UTF-16 空間で答える(文書全体の
変換を IME 往復ごとに行わないため)。iOS の `UITextPosition` は文書全体の
"composed" UTF-8 offset を持つ(UIKit が自分の保持する position object しか
問い合わせないため、文書全体コストを再導入しない)。marked text は view ローカル
の overlay で、確定時にのみ 1 transaction として buffer へ入る。

### 5.11 Editor 品質 gate

次を満たすまで editor を完成扱いにしない。

- 日本語 IME の実機操作
- 絵文字、結合文字、CRLF、巨大な単一行
- マルチカーソルの入力、削除、貼り付け、Undo/Redo
- 複数選択を含む検索・置換
- 外部変更、file watcher、agent による同時編集
- 10 MiB 級ファイルの初期表示、スクロール、編集
- syntax highlight が実ファイルで色として出ること
- code folding と soft wrap
- LSP による diagnostic、補完、定義ジャンプ、symbol 検索
- layout / input / transaction の計測と回帰テスト

品質 gate とは別に、日常作業に必要な editor 機能として次を持つ(2026-09-25 オーナー決定)。

- Markdown の live preview(editor と並べて表示、編集に追従)
- 定義ジャンプの直接操作(⌘+click、F12、前後の位置へ戻る/進む)
- AI inline 補完(ghost text、Tab で確定、Esc で却下)。LSP 補完とは別経路(2026-09-26 オーナー判断で保留: LSP 補完で足りる間は実装しない)

minimap、VS Code extension 互換、独自 plugin runtime は対象外。

## 6. AI review

Mac の「変更を確認」には、現在のファイルをレビューする操作と Project 全体を
レビューする操作を置く。利用者が Claude Code / Codex / OpenCode を選び、
明示的に開始したときだけ、その Project の root で agent を起動する。
ファイル対象は選択中の差分ファイル、なければ開いているファイルとする。
依頼には対象、読み取り専用のレビューであること、問題箇所のファイル・行・理由を
報告することを含める。結果は起動した terminal に表示する。未保存の editor
buffer が対象に含まれる場合は保存を促し、ディスクと異なる内容を黙って渡さない。
この操作は既存の agent launch と同じ Project / session / 承認境界を通る。

review コメントは行番号や画面上の吹き出しとして保存しない。anchor は最低限
次を持つ。

- file identity
- document revision
- UTF-16 range
- start/end の line ID
- 周辺テキストの hash
- コメント本文、author、thread、status

status は `attached` / `stale` / `orphaned` / `resolved`。編集で行番号がずれても
line ID と周辺 hash で再配置を試み、確信が持てない場合は勝手に移動せず stale
として表示する。

AI からの変更提案はテキスト差分ではなく editor transaction に変換する。

- Apply: transaction として適用
- Reject: 提案を破棄
- Partial apply: 選択した hunk だけ適用
- Undo: 通常の編集と同じ undo stack に入る
- Apply 後に関連 review を再評価し、解決 / stale を更新する

provider 固有のイベント形式は `ClairAgent` の内部 adapter に閉じ込め、review /
編集 / session のモデルは provider 非依存にする。最初の semantic provider は
OpenCode とする。ただし原則 3 のとおり raw terminal が正本であり、semantic
adapter は追加層である([ADR-0002](decisions/0002-layered-agent-remote-control.md))。

## 7. Terminal と session

表示と session 所有権を分離する。

- libghostty は terminal emulation、font、GPU rendering、入力表示を担当する
- PTY、process、resize、session persistence は `ClairDaemon` が所有する
- surface は session へ attach / detach できる
- **Mac と mobile は同じ session の別 surface である**。Mac GUI が自前の PTY を
  持つ構成は仕様違反とする
- raw replay は alternate screen、サイズ、scrollback を考慮する
- update 再起動中も PTY/session を維持し、新 process へ reattach する
- window を閉じても background service は継続し、明示的な Clair 終了で停止する
- agent 実行中は電源接続時に idle sleep を抑止する(battery 時は設定)

ペアリングは一回限りの承認、端末鍵、challenge、権限 scope、明示的な revoke を
持つ。LAN trust をそのまま採用せず、private route を前提にし、平文 WebSocket を
既定にしない。

## 8. Workspace、Git、worktree

- Git の有無を問わず local folder を Project として開き、複数 Project を 1
  process で切り替える
- Project ごとに workspace、terminal、agent、notification、local settings を保持
- Agents 一覧は現在の agent terminal への移動と、3 provider の local chat history
  の閲覧を統合する。履歴行には provider が分かるラベルとアイコンを付ける
- 設定の「使用状況」はユーザーが送信した依頼・追記を 1 件として日別に集計し、
  今日の件数と日別 activity calendar を示す。使用費用は取得可能な token/model
  情報から推定し、実際の請求額と区別して表示する。欠損分をゼロ扱いしない
- editor / terminal / diff を同じ tab group へ置ける任意 split
- pane の focus、移動、close、最大化、幅/高さ/全体均等
- file tree、search、Git の sidebar と、pane へ開く補助 view
- Quick Open、全文検索・置換、file watcher
- diff、stage/unstage、commit、branch/worktree の作成・切替
- commit graph(branch/merge の履歴を graph で表示し、commit から diff へ移動)
- managed worktree は repository 外の Clair 管理領域へ置く
- branch review は base に対する全差分を、commit 済みと未 commit/untracked に
  分けて表示する
- adoption 前に clean commit を要求し、採用は merge commit で行う
- conflict は merge editor または対象 worktree の agent で解決する
- worktree/branch の削除は個別に確認する
- Git なし Project では Git 機能を出さない

## 9. Command、CLI、MCP、通知

- すべての操作を typed Command Registry へ登録する
  ([ADR-0007](decisions/0007-unify-operations-in-a-typed-command-registry.md))
- palette から action、Project、file、symbol へ到達できる
- shortcut は任意 command へユーザーが割り当てられる
- `clair open path:line:column` は path を所有する open Project の active pane へ
  file を開く。該当 Project がなければ新規 Project として開く
- 起動中 Clair を操作する CLI を提供する
- `clair mcp serve` の stdio adapter で AI 向け command を公開する
- Clair の terminal 内の agent は CLI/MCP で子 agent を起動(prompt・worktree 指定)、状態確認、完了待ち、出力回収、pane の close ができる。子 agent 起動と worktree 作成は AI に公開するが `external` risk として GUI 承認を必須にする。terminal 内から来た CLI 呼び出しも AI 経由として同じ gate を通す
- command risk は固定 metadata と runtime preflight で判定し、必要な承認を GUI に
  表示する。AI の自己申告 risk を authorization に使わない
- Clair の terminal で起動した agent の bell / 通知要求 / 終了を記録し、Clair が前面にないとき macOS notification を送る。通知要求の title / body と、terminal が報告する session title は Mac 上の通知と履歴に表示する。通常の terminal は通知しない
- 通知一覧は status bar 右端の通知ボタンの popover だけに置く(独立画面は設けない)。行から対象 terminal へ移動し既読にする。記録は session 状態と Project badge にも使う
- Project / terminal 単位で notification を mute できる

## 10. Mobile

製品クライアントは PWA ではなく署名済みの iOS/iPadOS ネイティブアプリとする
([ADR-0015](decisions/0015-native-mobile-apns.md))。Web UI は開発用の検証・診断に
限定する。

mobile は薄い操作クライアントとして次を行う。

- workspace、tab、split、worktree の閲覧
- ファイルの段階的な読み込み
- terminal の attach と入力(Mac と mobile の入力は broker 到着順で同じ PTY へ)
- agent session の開始、停止、承認
- review thread の閲覧、コメント、提案の apply/reject
- pairing、device scope、revoke の管理
- 承認要求、review 完了、session 異常を APNs 通知で受け取る
- 通知タップから対象 workspace / review thread / terminal session へ deep link
- foreground / background / terminated のどの状態でも、再接続時に revision を検証

通信プロトコルには revision、request ID、capability、idempotency を含め、古い
クライアントからの更新で新しい編集を壊さない。通知 payload に機密のコード内容を
含めず、opaque な resource ID とイベント種別だけを持つ。詳細は認証済み接続で
取得する。APNs 認証情報を Mac アプリへ埋め込まない。relay は配送だけを担当し、
コード内容、agent の秘密、プロジェクト全体を保持しない。

mobile に terminal output や diff を永続 cache しない。mobile は source editor や
merge editor を持たない(2026-09-23 オーナー決定)。

## 11. Runtime identity と更新

- Clair Stable と Clair Dev を別 bundle ID、別 settings 領域で並行起動する
  ([ADR-0008](decisions/0008-stable-dev-runtime-identity.md))
- `VERSION` を変更した main への push で、GitHub Actions が Stable artifact を
  build・署名し、`Diwamoto/clair` の GitHub Release へ発行する
  ([ADR-0009](decisions/0009-stable-github-update-distribution.md)、
  [release runbook](runbooks/release.md))。Apple Developer ID signing と notarization は
  一般配布が必要になるまで後続判断
- app 内で update を表示し、click で download・reattach・restart する
- Stable から Clair source を開き、terminal/agent で Dev を build・起動して変更を
  確認できる

## 12. 完成の定義

- editor 経路に WebView がない
- 10 MiB 級ファイルで全行 eager layout を行わない
- 日本語 IME と Unicode を含む編集が正しい
- マルチカーソル、検索/置換、Undo/Redo が一貫している
- syntax highlight と LSP 由来の diagnostic が実ファイルで動作する
- AI review の anchor が revision-aware で、提案を安全に適用できる
- terminal は libghostty を使い、PTY/session と描画が分離している
- Mac と mobile が secure pairing と明示的な権限で**同じ session** を操作できる
- mobile は署名済みの iOS/iPadOS ネイティブアプリである
- APNs 通知から workspace / review / agent の対象画面へ遷移できる
- CodeMirror、CodeEdit、libvterm、Rust bridge に戻る runtime fallback がない
- module / 型 / ファイル名に `v2` が残っていない
- 性能・メモリ・IME・レビュー適用の回帰テストがある
- 日常操作の体感が ccedit より明確に快適である

## 13. 後続ロードマップ

cutover 条件には含めないが、この順で追う。

1. **Go editor support**: generic LSP 基盤を gopls で第一級にする。補完、診断、
   定義ジャンプ、参照検索、rename、code action、format、symbol 検索。Swift/Rust を
   第一級にすることは約束に含めない。
2. **Debugger**: DAP を共通基盤とし、Go/Delve を最初の第一級 debugger にする。
3. **Mobile branch review**: branch 全体の diff review、merge 承認、対応 agent の
   structured prompt/interrupt。
4. **Dev Container**: 既存 `.devcontainer/devcontainer.json` を検出・起動する。
   devcontainer 作成 UI や独自環境定義は対象外。
5. **First-party additions**: API tester 等。third-party plugin runtime や互換性
   contract は作らない。

## 14. 対象外

- Windows/Linux frontend
- VS Code extension、`tasks.json` の互換実行
- third-party plugin SDK、marketplace
- team workspace、共同編集、role、organization audit
- Clair account、設定同期、hosted agent、cloud/VM provisioning
- mobile full IDE、mobile source editor、汎用 remote shell の新規起動
- Clair 独自 task runner。build/test/run/lint は terminal か agent が実行する
- agent TUI の screen scraping による semantic status/approval 推測
- terminal transcript の session 終了後保存
- editor の minimap
