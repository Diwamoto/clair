# Clair v2 UI implementation checklist（`U01` freeze）

このドキュメントは `docs/plans/clair-v2-native-rewrite-queue.md` の `U01` の deliverable。
Design canvas と Workbench mock（`prototypes/clair-workbench`）を同期した状態から、native
実装（`U02`〜`U08`）が対象とする screen/state、tokens、layout、interaction、motion を
**freeze** する。ここに書かれていない見た目・挙動は正本にないので、native 側で発明しない。
足りない・曖昧な部分は「6. 未定義・要決定事項」に列挙し、guess で埋めていない。

## 0. 正本の確認

- UI の正本は **`prototypes/clair-workbench`**（Design canvas を実際に動く React 実装に
  落としたモック。`prototypes/clair-workbench/README.md` 参照）。
- `prototypes/clair-interaction-lab` は旧い静止画モックで、`clair-workbench` と競合する
  場合は本チェックリストの対象にしない（`clair-v2-native-rewrite-queue.md` P2 節の記載通り）。
- 値はすべて `prototypes/clair-workbench/src/tokens.ts` / `motion.tsx` / `data.ts` /
  `store.tsx` / `chrome.tsx` / `menus.tsx` / `contextMenu.tsx` / `mobile-artboards.ts` /
  `screens/*.tsx` から機械的に写した。React 側の都合による値は使っていない。
- Design canvas 自体（Artifact URL）は本 worktree から編集・参照していない。差分の有無は
  `clair-workbench-sync` skill の管轄であり、`U01` は read-only 監査タスクなので触れていない。

## 1. Mac / mobile のスコープ分離（2026-09-16 sequencing update 由来）

`clair-v2-native-rewrite.md` Phase 4 の 2026-09-16 sequencing update と
`clair-v2-native-rewrite-queue.md` の `U04`〜`U07` 行により、優先順位は次の通り決着している。

| スコープ | 対象 task | 前提 | 備考 |
|---|---|---|---|
| Mac | `U04`（AppShell chrome）、`U05`（editor/diff/review）、`U06`（terminal/agent activity） | Mac 側 `E07`（editor rendering）・`T03`（terminal surface） | iOS 側実装（`E08`/`T05`）や `N08`（G1 dogfood）の完了を前提にしない |
| iOS/iPadOS | `U03`（mobile nav）、`U07` の iOS 分 | `U02` + `N08` | `N08` は blocked のままでよく、他の `U` task をブロックしない |

このため本チェックリストは **画面ごとに Mac-scoped / mobile-scoped を明記** する。デスクトップ
IDE（`#/ide`）は Mac、モバイルアプリ（`#/mobile`）は iOS/iPadOS 実装が対象。

## 2. Design tokens（`U02` が Swift へ写す対象）

### 2.1 Color（`tokens.ts` の `color`）

| グループ | トークン | 値 |
|---|---|---|
| Surface | `chrome` / `canvas` / `surface` / `chromeRaised` / `surfaceHover` / `surfaceActive` | `#31363f` / `#282c34` / `#282c34` / `#1e2227` / `#2e333c` / `#383d47` |
| Chrome ink | `chromeInk` / `chromeInkMuted` | `#b6bcb6` / `#8a908b` |
| Text | `textPrimary` / `textSecondary` / `textTertiary` / `textQuaternary` / `textMuted` | `#f1f3ef` / `#c9cec8` / `#9ba19b` / `#707871` / `#55605a` |
| Line/rule | `lineNumber` / `divider` | `#4b5561` / `#3d454e` |
| Meaning（diff/debug 専有。原則これ以外は色を持たない） | `success` / `attention` / `danger` | `#8acb94` / `#e5c07b` / `#e27b83` |
| Debug | `debugBlue` / `debugBlueText` | `#5b88f7` / `#8fb0fa` |
| Panel | `panel` / `panelDeep` / `overlayGround` | `#181b1f` / `#101214` / `#0c0e10` |
| Editor（One Dark） | `code` / `codeBright` / `codeComment` / `codeKeyword` / `codeType` / `codeFunc` / `codeString` / `codeNumber` | `#abb2bf` / `#d0d4cf` / `#5c6370` / `#c678dd` / `#e5c07b` / `#61afef` / `#98c379` / `#d19a66` |
| Traffic lights | `close` / `minimize` / `zoom` | `#ff5f57` / `#febc2e` / `#28c840` |
| Tab group color（diff/debug に加えて唯一色を持つ用途。2026-09-16 時点でTokens artboardのルールを書き換え済み） | `groupColor.blue/green/amber/red/purple/gray`（`GROUP_COLOR_KEYS`） | `#5b88f7` / `#8acb94` / `#e5c07b` / `#e27b83` / `#c678dd` / `line.stronger` |

`line`（hairline 系: `hairline` `hairlineSoft` `hairlineFaint` `chrome` `chromeSoft`
`strong` `stronger` `ring` `paneDivider`）と `wash`（`faint` `soft` `medium` `raised`
`selected` `strong` `strongest`）は alpha 付き白系の重ね塗りで、`rgba(242,244,238,x)` /
`rgba(255,255,255,0.08)` の形。`withAlpha(swatch, alpha)` ヘルパーは `groupColor` の
値をチップ塗り（背景14〜22%・枠28〜55%）へ変換するのに使う。native 側は同じ semantic name
（`surfaceHover` 等）を保持し、Swift の color asset / semantic token 名にそのまま写すこと。

### 2.2 Type scale（4 段。`type`）

| 名前 | fontSize | fontWeight |
|---|---|---|
| `title` | 13 | 600 |
| `chromeStrong` | 11 | 600 |
| `chrome` | 11 | 400 |
| `micro` | 9 | 500 |

フォントは `sans`（`-apple-system, BlinkMacSystemFont, 'Hiragino Sans', 'Hiragino Kaku
Gothic ProN', 'SF Pro Text', system-ui, sans-serif`）と `mono`（`"SF Mono",
ui-monospace, "JetBrains Mono", Menlo, monospace`）の2種類のみ。

### 2.3 Radius（3 段）と Spacing（7 段）

- `radius`: `control` 4 / `card` 6 / `overlay` 10。
- `space`: `[2, 4, 6, 8, 12, 16, 24]`。
- モバイルは別ルール（2.6参照）: card 10 / button・field 8。

### 2.4 Chrome budget

`chrome = { titlebar: 48, activityBarWidth: 44, statusBar: 26 }`。縦 chrome 予算は
titlebar 48 + status bar 26 = **74px** で全画面共通（editor breadcrumb は意図的な例外、
2.7参照）。

> **2026-09-20 amendment（re-freeze）**: U01 freeze 時点の `sidebarStrip: 34`
> （sidebar panel 内、横アイコン列）は、その後の workbench 敵対的UIレビューにより
> **左サイドバーに独立した縦の Activity Bar**（`activityBarWidth: 44`、sidebar panel の
> 外・titlebar と status bar の間で全高）に置き換わった。`sidebarStrip` トークンは廃止。
> あわせて selected/hover の tint を `washSelected` 一本化（旧 `surfaceHover`/
> `surfaceActive` の二段構え廃止）、file tab の下線（selected 状態の bottom rule）廃止、
> file tree のルート行の大文字化・シェブロン廃止も同時に正本へ反映。詳細は
> `prototypes/clair-workbench` の 2026-09-20 コミット群と、同日付で更新した Design
> canvas `Main` artboard を参照。

### 2.5 Motion primitives（`motion.tsx`。`U02` が Swift アニメーションへ写す対象）

- 尺: `SCREEN_MS = 200`（画面遷移）、`OVERLAY_MS = 90`（オーバーレイ／パネル）。Tokens
  artboard の LATENCY BUDGET（Project 切替 80/200ms、palette 表示 33/80ms）が根拠。
- 種類（`Kind`）: `depth`（既定。奥へ退き奥から出る）/ `slide`（`slide-fwd` /
  `slide-back`、方向は `ORDER` 配列の index 比較で決まる）/ `lift`（下から上がる）/
  `sheet`（手前に被さる）/ `fade`（サイドパネル専用、overlay budget）。
- 画面ごとの `KIND` マッピング: `workspace`=depth, `review`=slide, `graph`=slide,
  `activity`=depth, `debug`=depth, `debugAgent`=depth, `sessions`=lift, `settings`=sheet。
- `ORDER`（slide の方向判定用の左右順）:
  `['workspace', 'graph', 'review', 'debug', 'debugAgent', 'activity', 'sessions', 'settings']`。
- 動くのは **メイン領域とサイドパネルだけ**。titlebar / navigation strip / status bar は
  chrome として常にマウントされたまま動かない。
- `transitionFor`: 遷移先へ入るときはそのスクリーンの `KIND` を使うが、workspace へ戻る
  ときは「出ていく」画面の `KIND` を使う（workspace 自体は常に `depth` 扱い）。
- `prefers-reduced-motion: reduce` では全て停止する（`U07` の reduced motion 照合対象）。
- コンテキストメニュー・パレット等のオーバーレイは 90ms、ポインタに近い角から `0.97→1`
  で開く。閉じるときは動かさない（`prototypes/clair-workbench/README.md` 右クリック
  メニュー節）。

### 2.6 Mobile 固有寸法（Tokens artboard MOBILE 節、`screens/Mobile.tsx` 冒頭コメント）

- Viewport: 390×844。上 54px は実機の status bar 用の空白（フェイクを描かない）。
- tab bar 78px、gutter 16px、touch target 44px。
- radius: card 10 / button・field 8（desktop の 4-6-10 とは異なるルール）。

### 2.7 Chrome budget の例外

エディタ pane 最上部の `PathBreadcrumb`（`screens/Workspace.tsx`）は、Tokens artboard の
元々の設計（breadcrumb は status bar 側に置き、pane を割っても縦 chrome は 74px のまま
増えない）と矛盾する意図的な trade-off。pane を横に割ると（`⌃⌘D`）breadcrumb も複製され、
縦 chrome は 74px の主張から外れる。Tokens artboard 側のメモもこの trade-off を明記する
形に書き換え済み。`U04`/`U05` はこの例外を「バグ」として直さないこと。

## 3. Screen/state 一覧（Mac IDE、`#/ide`）

AppShell（`chrome.tsx` の `AppShell`）は titlebar 48px + activity bar 44px（縦、
titlebar〜status bar 間で全高）+ sidebar 242px（panel のみ）+ main + status bar 26px
の構成で一度だけ組み立てられ、画面遷移では **activity bar は常にマウントされたまま、
panel と main だけ** が差し替わる（2.4 の2026-09-20 amendment 参照）。全画面共通で、
`U04` の対象。

| 画面 | artboard | 入口 | panel（sidebar） | main | status | motion kind | スコープ |
|---|---|---|---|---|---|---|---|
| ワークスペース | `Main` | 起動時 / `esc` | `ExplorerPanel`（ファイルツリー） | `WorkspaceMain`（pane tree: editor\|agent/terminal） | `WorkspaceStatus`（Ln, Col） | depth | Mac（`U04`+`U05`+`U06`の複合） |
| 変更を確認 | `SourceControl` | sidebar の盾アイコン、`⌃⌘G` | `ReviewPanel`（ステージ済み/変更 + commit） | `ReviewMain`（全幅 diff） | `ReviewStatus`（対象ファイル） | slide | Mac（`U05`） |
| （↳ グラフ切替） | `MergeGraph` | 変更を確認 画面ヘッダーの「変更/グラフ」 | `ReviewPanel` と同じ | `MergeGraphMain`（グラフ表） | `ReviewStatus` と同じ | slide | Mac（`U05`） |
| アクティビティ | `Activity` | sidebar のベル、titlebar の Claude Code タブ | `ActivityPanel` | `ActivityMain`（チャット + 承認カード） | `ActivityStatus`（`Claude Code · 実行中`） | depth | Mac（`U06`） |
| 実行とデバッグ | `Debug` | sidebar の虫アイコン、`⇧⌘D` | `DebugPanel`（breakpoint/callstack/変数） | `DebugMain`（エディタ+コンソール） | `DebugStatus`（現在行） | depth | Mac（`U05`寄り。位置付け未確定、6.5参照） |
| Debug + AI統合（検討中） | `DebugAgent` | `⌘K` →「Debug + AI統合」 | `DebugAgentPanel` | `DebugAgentMain` | `DebugAgentStatus` | depth | Mac／**mock 自身が「検討中」と明記**（6.1参照） |
| セッション | `SessionRail` | `⌃⌘L`、titlebar の codex タブ | 未定義（explorer ツリーのまま代用中。6.2参照） | `SessionsMain`（セッション表） | `SessionsStatus`（入力待ちバッジ） | lift | Mac（`U06`） |
| Agentを追加 | `AddAgent`（overlay） | `⌃⌘N`、セッション画面の「Agentを起動」 | — | `AddAgentOverlay`（agent/place/worktree/branch/prompt/confirm） | — | overlay 90ms | Mac（`U05`/`U06`いずれかに整理要、6.7参照） |
| 設定 | `Settings` | `⌘,`、titlebar の歯車 | `SettingsPanel`（セクション一覧） | `SettingsMain`（設定本文） | `SettingsStatus`（`設定 · セクション名`） | sheet | Mac（`U04`）。セクションの一部が未定義（6.3参照）。**2026-09-20 amendment**: 画面全体を覆うフルスクリーン画面に変更（titlebar/activity bar/sidebarは非表示、独自headerに戻すボタンは右上✕のみ）。旧「panel/mainだけ差し替え、titlebar・サイドバーは触れたまま」の形は廃止（サイドバー/タブ経由で設定から抜けられてしまう問題があったため） |
| 検索 | `Search`（overlay） | `⇧⌘F`、titlebar の検索欄 | — | `SearchOverlay` | — | overlay 90ms | Mac（`U04`/`U05`） |
| コマンドパレット / ファイルへ移動 | `CommandPalette`（overlay） | `⌘K`（`⌘P` はファイルへ移動） | — | `CommandPalette` | — | overlay 90ms | Mac（`U04`） |

`AgentsPanel`（`screens/Sessions.tsx`）は `activity` 以外のナビゲーションで `agents`
panel id が選ばれた場合の共有 panel。`App.tsx` の `Ide()` の panel/main/status 分岐
（`navIdFor(wb.screen)` 基準）がルーティングの正本。

### 3.1 Pane / layout の挙動（Workspace 画面、`U04`/`U05` 対象）

- pane 種別: `editor` / `agent` / `terminal`（`PaneKind`）。木構造 `PaneNode`（leaf /
  horizontal split / vertical split、`ratio` は `0.08`〜`0.92` にクランプ）。
- 初期レイアウト: editor（左, ratio 0.62）| agent（右上）/ terminal（右下, ratio 0.55）。
- 操作: divider ドラッグで比率変更、`⌃⌘D`/`⌃⌘⇧D` で分割、`⌃⌘W` で閉じる、`⌃⌘M` で
  最大化トグル、`⌃⌘=` で均等化、`⌃⌘→` でフォーカス移動（`focusDirection`、leaf の
  出現順で巡回）。
- タブ: 168px 固定幅。名前が入りきらない場合は省略記号ではなく **右端でフェードして
  隠す**（実際にはみ出したタブにのみ適用）。全名は hover のツールチップ。
- ファイルタブの `dirty` 状態はドットで表現（`Tab` 型の `dirty: boolean`）。`⌘S` で
  dirty を落とす。
- プロジェクトごとのタブグループ: titlebar に `clair` / `ccedit` / `clair-releases`
  の3 chip、各グループに折りたたみ（`grid-template-columns: 1fr → 0fr`）。既定は全展開。
  グループカラーは chip 自身の塗り（`withAlpha` で 14〜22%/28〜55%）。既定色:
  `clair`=blue / `ccedit`=green / `clair-releases`=amber。
- Explorer ツリー: フォルダ開閉、クリックでタブを開く、M/A バッジ（変更種別）。

### 3.2 Terminal / Agent surface（Mac 側、`U06` 対象）

- Terminal pane: `y`/`N` で codex の承認プロンプトに応答。`git status`、`swift test …`、
  `clear` が実データなしで動く簡易シェル実装（`runTerminal` in `store.tsx`）。
- Agent pane（`AgentPane`）: 実行ログ表示（`● Update(...)`、diff サマリ、
  `** BUILD SUCCEEDED **` 等のトーン付き行）。
- `awaitingApproval` state: 承認待ち中は `y`/`N` の1文字応答のみを解釈するモード。

### 3.3 Review / diff surface（Mac 側、`U05` 対象）

- パネルは **VSCode の Source Control と同じ stage/changes モデル**（「COMMIT済み/未COMMIT」
  という旧グルーピングを廃止し、`workingPaths`（作業ツリーの変更）と `stagedPaths`
  （ステージ済み）の素の `git status` 形に統一済み）。
- 行末の「+」「−」でファイル単位 stage/unstage、セクション見出しの一括「+」「−」、
  コミットメッセージ入力で「コミット」有効化 → 押すとステージ済みファイルが working
  set から消える（**履歴には残らない** — 履歴を見るのはグラフモードの仕事）。
- Empty state: `NoChanges`（Tokens artboard の EMPTY STATE コンポーネント。
  `IconShieldCheck` + 「変更はありません」+「working tree はきれいです。」、
  `screens/Review.tsx`）。
- マージグラフは **「変更を確認」の1モード**（専用アイコンなし）。`SourceControlModeTabs`
  （`MainHeader` 内）で `review` ↔ `graph` を切り替え、`slide` motion。

### 3.4 Activity / Agent 会話 surface（Mac 側、`U06` 対象）

- チャット: user/agent メッセージバブル + 時刻。`sendMessage` はモック内で固定応答を
  echo する。
- 承認カード（`PermissionRequest`）: コマンド文字列表示 + 3択ボタン
  `拒否` / `セッション中は許可` / `今回だけ許可`（`approvalDecision` の型そのまま。
  weight 700 の破壊的表現ルールは README 記載の通り「色ではなく太さ」）。

### 3.5 Debug surface（Mac 側、`U05`寄りだが未整理。6.5参照）

- gutter クリックでブレークポイント（`toggleBreakpoint`）。
- ツールバー: continue / step over / step into / step out / restart / stop
  （`debugStep` の union）。
- コンソールに step ログが積まれる（`debugConsole`）。
- `DebugAgent`（Debug + AI統合）は agent が操作中バッジ（`Agent が操作中 · dap-go`）と
  停止バッジ（`main.go:40 で停止`）を titlebar extra スロットへ出す **検討中** 機能。

### 3.6 Context menu 一覧（`contextMenu.tsx` / `menus.tsx`。正本は canvas の `ContextMenu` artboard）

| 面 | ヘッダー | 中身 |
|---|---|---|
| titlebar の project chip | Project 名・パス | 色見本（`GROUP_COLOR_KEYS`）/ 切り替え・折りたたみ・名前を変更 / 左右へ移動 / Project を閉じる |
| ファイルのタブ | ファイル名・ディレクトリ | タブを閉じる系 / 分割して開く / Agent に送る › / 変更を確認 / パスのコピー・Finder |
| Claude Code / codex のタブ | セッション | 開く / Agents の一覧 / Agent を追加 |
| ファイルツリー | 名前・パス | 開く / 分割して開く / Agent に送る › / 変更を確認 / パスのコピー・Finder（フォルダは開閉とパス） |
| エディタ | なし | 切り取り・コピー・ペースト / Agent に送る › / 保存 / 分割・最大化 / ペインを閉じる |
| ターミナル・agent 出力 | なし | コピー・ペースト・クリア（agent は会話を開く）/ 分割・最大化 / ペインを閉じる |

- 見た目: 地 `chromeRaised`、枠 `line.strong`、半径 `radius.overlay`(10)、影はコマンド
  パレットと同じ、scrim なし。行 26px・半径 6。hover / キーボード選択は
  `surfaceActive` の塗りのみ。破壊的項目は最後・weight 700（赤にしない）。
- 開く: 90ms、ポインタに近い角から `0.97→1`。閉じる: アニメーションなし。
- ルール: ヘッダーは対象がオブジェクト（ファイル/Project/セッション）のときだけ。
  実行不可の操作は disabled で残す（消さない）。同じ操作は同じ文言・ショートカット。
- キーボード: `↑↓` / `→`（submenu）/ `←` / `↵` / `esc`（1段ずつ閉じる）。
- モックでは動かないもの: 「Finder で表示」（押すと閉じるだけ）。コピー/ペーストは
  Clipboard API 依存（Artifact の権限次第で無反応になりうる）— これは mock 制約で
  native 側の仕様ではない。

### 3.7 Command palette / Quick open / Search（`screens/Overlays.tsx`）

- `CommandPalette`: `⌘K` でコマンド一覧、`⌘P` でファイルへ移動。`commands`
  （`data.ts`）は `id` / `title` / `shortcut` / `risk`（`追加`/`読み取り`/`破壊的`）を
  持つ。↑↓ で選択、↵ で実行。
- `SearchOverlay`: `⇧⌘F`。ファイル本文横断・行番号付きヒット、ヒット数「N件 ·
  Mファイル」表示、↑↓ で選択。**ヒット0件時のメッセージが定義済み**
  （「一致するものはありません。」）。
- `AddAgentOverlay`: `⌃⌘N`。agent 種別・起動場所（ターミナル/Agents）・worktree
  （現在のProject/新しいworktree）・branch 名・prompt・confirm トグルを持つフォーム。

## 4. Screen/state 一覧（Mobile、`#/mobile`）

モバイルは **デスクトップの縮小版ではない**。`docs/projects/p0020-mobile-agent-remote-control/`
の non-goal（mobile full IDE、source editor、file browser、diff/review を除外）に従い、
「席を離れたあと agent を見て返す」経路だけを持つ。IDE をそのまま縮小した画面は作らない。
色はグレースケールのみ（diff/debug/タブグループ以外は無色というルールがモバイルにも
適用され、接続中/入力待ち/要対応も色を持たない）。

| 画面 | artboard | tab / 入口 | 何を持つか | スコープ |
|---|---|---|---|---|
| 概要 | `MobileHome` | `#/mobile`、タブ「概要」 | host identity（endpoint/fingerprint/protocol）、要対応リスト、Project別セッション数 | mobile（`U03`） |
| セッション | `MobileOverview` | タブ「セッション」 | 全Projectのagent/terminalカタログ。exit・worktree を明示 | mobile（`U03`） |
| アクティビティ | `MobileActivity` | タブ「アクティビティ」 | attention 履歴（**agent名・Project・signal種別・時刻のみ**、terminal内容は含めない） | mobile（`U03`） |
| 設定 | `MobileSettings` | タブ「設定」 | この端末の scope、経路と fingerprint、ペアリング済み端末と revoke | mobile（`U03`） |
| ターミナル | `MobileTerminal` | セッション/概要/アクティビティの「ターミナルを開く」（push、5つ目のタブにはしない） | raw PTY。gap は明示（「欠落 X KB · 保持範囲外」）、viewport は client-local | mobile（`U03`） |
| ペアリング | `MobilePairing` | モバイルの設定 →「端末を追加」（push） | one-time link の指紋読み合わせ。初期 scope は `view` のみ | mobile（`U03`、`N08`/`N09`と接続） |

- タブは **概要 / セッション / アクティビティ / 設定** の4つのみ。ターミナルと
  ペアリングは push 画面で、push 時は tab bar を外して 44px の戻りバーに替える。
- scope は減った側も見せる（`terminate` / `spawn_session` / `manage_devices` は破線の
  チップで、付与されていないことが見える。`SCOPES` in `screens/Mobile.tsx`）。
- 通知に内容を載せない（アクティビティは agent 名・Project・signal 種別・時刻だけ）。
- gap を黙って飛ばさない（terminal scrollback に欠落区切りが入る）。
- mobile artboard の正本データは `src/mobile-artboards.ts`（canvas から機械生成、
  手書き禁止）。キー: `概要` / `セッション` / `アクティビティ` / `設定` / `terminal` /
  `pairing`（6画面、上表と対応）。
- Empty state 例: 「要対応」0件時は `EmptyState`（`screens/Mobile.tsx`）
  「返すものはありません」/「どのsessionも入力を待っていません。呼ばれたらアクティビティ
  に出ます。」。アクティビティ画面の空リストは「返すものはありません」/「呼ばれた
  セッションがあればここに出ます。」。

### 4.1 Responsive 方針

- `#/mobile`: 実機（幅460px以下）は全画面、デスクトップブラウザでは 390×844 枠。
- `#/ide`: 幅1000px未満では **レイアウトを崩さずに縮小表示**（1440×900 のまま
  transform でスケール）。レスポンシブな組み替えは行わない（意図的 — 狭い画面向けに
  畳むと「デザイン厳守」が成立しなくなるため）。native 側もこの非レスポンシブ方針を
  尊重すること（`U04` が対象とする Mac ウィンドウの最小サイズ設計に影響）。

## 5. Native 実装時の注意（`U02`〜`U08` 共通）

- 色を持ってよいのは **diff・debug・タブグループ** の3用途のみ（Tokens artboard の
  ルール。2026-09-16 時点でタブグループが正式に追加されている）。
- native コントロールを混ぜない（`CONTROLS` の「native を混ぜない」ルールはコンテキスト
  メニューにも適用済み）。Mac の titlebar / dropdown / context menu を含め、IDE の中では
  OS標準のメニューを一切出さない。
- Dark テーマのみ。Light テーマは存在しない。
- `⌘,`（設定）、`⌘K`（コマンド）、`⌘P`（ファイルへ移動）、`⇧⌘F`（検索）、`⇧⌘D`
  （デバッグ）、`⌃⌘D`/`⌃⌘⇧D`（分割）、`⌃⌘W`（ペインを閉じる）、`⌃⌘M`（最大化）、
  `⌃⌘=`（均等化）、`⌃⌘→`（フォーカス移動）、`⌃⌘L`（セッション）、`⌃⌘N`（Agent追加）、
  `⌃⌘G`（変更を確認）、`esc`（1段階戻る/閉じる）は `App.tsx` の `Ide()` に実装された
  正式なショートカット一覧。`U04`/`U05`/`U06` はこれをキーバインディング契約として扱う。

## 6. 未定義・要決定事項（native 側で発明しない。人間/デザイン判断待ち）

mock 自身が「キャンバスに定義がない」「検討中」「未定義」と明記している箇所、および
このチェックリスト作成中に発見した canvas 側の欠落を列挙する。**いずれも native 側で
勝手に埋めず、先に Design canvas / Workbench を更新するべき事項**。

### 6.1 Debug + AI統合（`DebugAgent`）は「検討中」

`data.ts` のコマンド名が「Debug + AI統合（検討中）」であり、`screens/Debug.tsx` の
コメントも `/* ── Debug + AI (検討中) ──── */` と明記している。`clair.debug.agent`
コマンドと `DebugAgentBadge` / `DebugAgentPanel` / `DebugAgentMain` / `DebugAgentStatus`
は動く実装だが、位置付けは exploratory。**`U05`/`U06` のどちらが正式に担当するか、
そもそも正式機能として実装対象に含めるかは未決定** — 人間判断が必要。

### 6.2 セッション画面のサイドバー（panel）が未定義

`prototypes/clair-workbench/README.md` に明記: 「セッションにはキャンバス上サイドバーの
定義がないため、エクスプローラーのツリーのままにしてある。ここを埋めるのはキャンバス側の
作業で、モック側で発明はしない。」`U06` 実装時、セッション画面の sidebar panel の内容
（正式には何を出すべきか）は canvas 側の追加作業を待つ必要がある。現状の `AgentsPanel`
（Project別/状態別のセッション数リスト）は暫定であり、`SessionRail` artboard の正式
sidebar 定義ではない。

### 6.3 Settings のセクションのうち「一般」「モバイル」以外は canvas 未定義

`screens/Settings.tsx` のコード自身が明言: `SECTIONS = ['一般', 'AIプロバイダー',
'エディタ', 'ターミナル', 'モバイル', 'アップデート']` のうち、`一般` と `モバイル`
以外を選ぶと本文に「この画面はデザインキャンバスにまだ存在しません。キャンバスが
定義しているのは「一般」の内容だけです。ここに項目を足すのはキャンバス側の作業です。」
という placeholder カードが出るだけで、実コンテンツがない。`U04` は「一般」「モバイル」
の2セクションのみを実装対象とし、残り4セクション（AIプロバイダー/エディタ/ターミナル/
アップデート）は **canvas 側で内容が定義されてから** 着手すること。

### 6.4 `clair` 以外のプロジェクトタブの中身は発明された placeholder

`data.ts` のコメント: 「`clair` 以外の2グループは実データ（開けるファイル）を持たない…
`ccedit` はセッション worktree と `ProjectLayout.restore()` の言及から、`clair-releases`
はプレースホルダーとして1タブずつ立てている」。README も「`projectTabs` の中身
（ファイル名）はキャンバスに定義がない発明であり、正式なファイル名が決まったら
キャンバス側で上書きしてほしい」と明記。`U04` はこの2プロジェクトのタブ内容を
そのまま native に固定移植しない（正式なファイル名が決まるまでの仮値として扱う）。

### 6.5 Debug 画面のナビゲーション上の位置付け

README のナビゲーション節では「実行とデバッグ（虫アイコン）」がサイドバーの4ナビの
1つとして明記されているが、`U04`（AppShell chrome）と `U05`（editor/diff/review）/
`U06`（terminal/agent activity）のどちらの task が Debug 画面（`DebugPanel` /
`DebugMain`）の実装を担当するかは queue の task 説明文からは一意に決まらない
（`U05` は "editor、diff、AI review" 、`U06` は "terminal、agent activity、session
list、attention/approval" と書かれており、Debug のブレークポイント/ステップ実行/
コンソールはどちらの範疇にも明示的に含まれていない）。実装着手前に、Debug 画面の
担当 task を明確化する必要がある。

### 6.6 Command palette / Quick open にヒット0件の状態がない

`screens/Overlays.tsx` の `SearchOverlay` は `!hits.length` 時に
「一致するものはありません。」を出すが、`CommandPalette`（`⌘K` のコマンド一覧、
`⌘P` のファイルへ移動）の `rows` フィルタには同等の 0件メッセージが実装されていない
（`rows.map` が単に空配列になるだけで、空状態の視覚的フィードバックがない）。これが
canvas 側の意図的な省略か、単なるモックの実装漏れかは不明。**native 側で独自の
0件メッセージを発明せず**、canvas 側に確認してから `U04` で実装すること。

### 6.7 `AddAgent` overlay の担当 task が不明瞭

`AddAgentOverlay`（`⌃⌘N`、セッション画面の「Agentを起動」から開く）は agent 起動
フォームで、内容的には session 管理（`U06` の scope）と AppShell のコマンド体系
（`U04` の scope）の両方にまたがる。queue のタスク定義には overlay 単位の割り当てが
ないため、`U04`/`U06` どちらが実装責任を持つかは着手前に決める必要がある。

### 6.8 Mobile: ターミナル/ペアリングの「push」ナビゲーションモデルの native 相当が未検証

README は「push した画面は tab bar を外して 44px の戻りバーに替える」とモックの
挙動を説明しているが、これは SwiftUI の `NavigationStack` / タブ非表示パターンの
どれに対応するかという native 側の技術選択はまだ検証されていない。`U03` 着手時に
SwiftUI 実装方針（`NavigationStack` の push + `toolbar(.hidden, for: .tabBar)` 等）を
確認すること。仕様としての見た目・情報階層は canvas に従うが、実現方式は `U03` の
設計判断が必要という点を明記しておく。

### 6.9 Debug 画面と `E07`/`T03` 前提条件の関係

`U04`/`U05`/`U06` はそれぞれ `E07`（editor rendering）・`T03`（terminal surface）を
前提とするが、Debug 画面はエディタ内 gutter 操作とコンソール（terminal 風出力）の
両方を使う複合面である。6.5 の担当未確定と合わせて、Debug 画面が `E07` と `T03` の
どちらか一方で着手可能か、両方必要かも未決定。

## 7. 参照ソース一覧

- `prototypes/clair-workbench/README.md`
- `prototypes/clair-workbench/src/tokens.ts`
- `prototypes/clair-workbench/src/motion.tsx`
- `prototypes/clair-workbench/src/store.tsx`
- `prototypes/clair-workbench/src/data.ts`
- `prototypes/clair-workbench/src/chrome.tsx`
- `prototypes/clair-workbench/src/menus.tsx`
- `prototypes/clair-workbench/src/contextMenu.tsx`
- `prototypes/clair-workbench/src/mobile-artboards.ts`
- `prototypes/clair-workbench/src/App.tsx`
- `prototypes/clair-workbench/src/screens/Workspace.tsx`
- `prototypes/clair-workbench/src/screens/Review.tsx`
- `prototypes/clair-workbench/src/screens/Activity.tsx`
- `prototypes/clair-workbench/src/screens/Debug.tsx`
- `prototypes/clair-workbench/src/screens/Sessions.tsx`
- `prototypes/clair-workbench/src/screens/Settings.tsx`
- `prototypes/clair-workbench/src/screens/Overlays.tsx`
- `prototypes/clair-workbench/src/screens/Mobile.tsx`
- `docs/plans/clair-v2-native-rewrite.md`（section 2, 7, Phase 4/5）
- `docs/plans/clair-v2-native-rewrite-queue.md`（Priority contract, Working rules,
  Milestone gates, `U01`〜`U08` 行）
