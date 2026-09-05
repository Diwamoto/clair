# Proposed: Clair interaction and visual contract (draft)

これはdraftである。採用する場合は`docs/product/interaction.md`へ移し、
`docs/plans/clair-poc-queue.md`の6行のUI contractをこの文書への参照に置き換える。

## 1. 基本姿勢

Clairの画面は、情報密度で勝ち、装飾で負けないことを目指す。
判断に迷ったら、pixelをcontentへ返す。

- chromeはcontentのために存在する。chromeがcontentを隠してはならない。
- 同じ事実を2箇所以上で常時表示しない。
- system標準のcontrolとClairのchromeを同じ画面で混ぜない。
- 状態は色ではなく、まず形と位置で伝える。色は補強に使う。

## 2. Layout contract

### 2.1 領域の所有

```
┌──────────────────────────────────────────────┐
│ traffic │ Project + tab (全Project並列) │ 🔍 ⌘ ⚙ │  48
├────────────┬─────────────────────────────────┤
│ activity   │                                 │  34
├────────────┤                                 │
│            │        pane content             │
│  sidebar   │   （tab barもheaderも持たない）    │
│            │                                 │
│  204-340   │                                 │
├────────────┴─────────────────────────────────┤
│ status bar                                    │  26
└──────────────────────────────────────────────┘
```

- **titlebar**はProjectとtabを持つ。tabは**全Projectで1本のstrip**であり、
  別Projectのtabへ切り替えるとProjectも切り替わる。
- titlebar右端は左から**検索欄、command、settings**の順。commandはiconのみで、
  ラベルも枠も持たない。
- **activity bar**はsidebarの上端に置く。全幅rowにも縦railにもしない。
- **pane**はtab barもheaderも持たない。terminalとeditorがpaneいっぱいに直接描かれる。
- **sidebar**はactivityによって内容だけが変わる。main areaは変わらない。
- **status bar**はProject全体の状態と、focusしているpaneのcontextを持つ。

sidebarを閉じている間はactivityのiconが見えないため、Files / Search / Git / Review /
Activity / Sessionsは全てcommandとして登録し、shortcutから直接到達できなければならない。
iconを唯一の導線にしない。

### 2.2 activity切替の不変条件

sidebarのactivityを切り替えても、pane layoutとその中のsession、
focus位置、scroll位置は変化しない。

Gitのdiff、branch review、activity detailなど、広い面積を要するものは
pane内のtabとして開く。sidebarはそれらへの入口とlistだけを持つ。

### 2.3 Split

- dividerは**1pxのborderのみ**で、gripや装飾を持たない。
- hit areaは見た目の1pxではなく±4pxを取る。
- hoverしたときに`resizeLeftRight` / `resizeUpDown`カーソルと、borderの色でつかめることを示す。
- dragで比率を変え、結果はmodelへ書き戻してworkspace復元に残す。
- paneの**移動・入れ替え**は、paneの上端中央に置く横向き3点リーダのhandleをdragして行う
  （Ghosttyと同じ形式）。terminalのpaneもeditorのpaneも同じhandleを持つ。
- 均等化、最大化、focus移動、closeは全てcommandとして存在し、shortcutを割り当てられる。
- paneの境界は、focusのあるpaneだけがaccent borderを持つ。

## 3. Chrome budget

| 要素 | 高さ | 備考 |
|---|---|---|
| titlebar | 48 | traffic lightsに必要な最小。tabを含む |
| pane tab bar | 0 | paneはtabを持たない |
| pane content header | 0 | breadcrumbはstatus barへ |
| status bar | 26 | |
| **content到達までの合計** | **74** | 現状174から100削減 |

activity barの34pxはsidebarの中にあり、main areaの縦を消費しない。

splitしてもこの74pxは増えない。paneがchromeを持たないためである。

sidebarのsection headerは32pxを上限とする。
overlayのheaderは48pxを上限とする。

## 4. Type scale

4段階に固定する。

| 名前 | size | weight | 用途 |
|---|---|---|---|
| `chrome` | 11 | regular | tab、status bar、sidebar row、label |
| `chromeStrong` | 11 | semibold | 選択中のtab、Project名 |
| `title` | 13 | semibold | sidebar header、overlay title |
| `micro` | 9 | medium | badge、shortcut chip、単位 |

editorとterminalのcontent fontは利用者設定であり、このscaleの外にある。

現在使われている8, 10, 12, 14, 15pxは上記4段階へ寄せる。

## 5. Spacing / radius scale

- spacing: 2, 4, 6, 8, 12, 16, 24 の7段階のみ。
- radius: 4（control）、6（card / row）、10（overlay）の3段階のみ。
- border widthは常に1。

## 6. Color contract

`WorkspaceChrome`のtokenを唯一の正本とし、desktopとmobileが同じ値を共有する。
`packages/ClairDesignKit`として切り出す。

### 6.1 意味の割り当て

| token | 意味 | 使ってよい場所 |
|---|---|---|
| `accent` | Clairのfocus、選択、live | focus border、選択tab、live indicator |
| `success` | processが健全に動いている | terminal running |
| `attention` | 人間の判断を待っている | bell、未保存、agent入力待ち |
| `danger` | 失敗、破壊的操作 | exit≠0、destructive command |
| Project accent | Projectの識別 | Project label、そのProjectのtabのtop bar |

`accent`とProject accentは同じ画面で競合しうるので、
Project accentはProject group labelとtabのtop 2pxのみに使う。

### 6.2 systemカラーの禁止

`.foregroundStyle(.secondary)`、`Color.accentColor`、`.borderedProminent`の
system描画をworkspace chrome内で使わない。
root viewに`.tint(WorkspaceChrome.accent)`を置き、
`WorkspaceChrome`のcomponent setで置き換える。

### 6.3 Theme

Clair v2はdark固定とする。light themeとuser themeはv2のscopeに含めない。
（この決定はADRとして残す。）

## 7. State surface contract

### 7.1 重複表示の禁止

1つの事実は1箇所で常時表示する。

| 事実 | 常時表示する場所 | 補助 |
|---|---|---|
| 未保存 | titlebar tabのdot | 保存時にstatus barで一時表示 |
| terminal state | titlebar tabのdot色 | session railの行 |
| attention | Project labelのbadge | session railの行、macOS通知 |
| branch | status bar | Git sidebarのheader |
| 開いているfileのpath | status bar | — |
| agentの利用枠 | status bar（最も逼迫した1つ） | popoverで内訳 |

`保存` buttonは置かない。⌘Sとtabのdotで足りる。

### 7.2 実行context

focusしているpaneが、Project rootで動いているのかmanaged worktreeで動いているのかを
**status barに常時表示する**。managed worktreeのときは`branch`名のchipを出す。

paneがchromeを持たないため、この情報の置き場所はstatus barとsession railになる。

これは美観ではなく安全性の要件である。

### 7.3 Empty / error / loading

| 状況 | 表現 |
|---|---|
| まだ何も無い（空のpane、変更なし） | 中央にicon + 1行のtitle + 1行の説明 + 主要action 1つ |
| 操作の失敗（保存できない等） | 対象surface内のinline banner。alertを使わない |
| 破壊的操作の確認 | alert。これがalertの唯一の用途 |
| 読み込み中 | 既存contentを残したままprogress。全画面のspinnerを出さない |

`ContentUnavailableView`はsystem metricsで大きすぎるため、
`WorkspaceChrome`のempty state componentへ置き換える。

## 8. Focus model

### 8.1 focusの所在

focusは常に1つのpaneにある。focused paneはaccent borderを持つ。
sidebarとoverlayはfocusを一時的に借り、閉じたときに元のpaneへ返す。

### 8.2 terminal focus時のshortcut境界

terminal paneにfocusがあるとき、次のshortcutだけをClairが横取りする。
それ以外の全てのkey inputはPTYへそのまま渡す。

| 予約 | 用途 |
|---|---|
| `⌘` を含む組み合わせ | Clairのcommand |
| `⌃⌘` を含む組み合わせ | Clairのpane操作 |

`⌥`単独、`⌃`単独、function keyはPTYへ渡す。
これによりClaude Code、Codex、OpenCode、tmux、vimがそのまま動く。

利用者がcommandへ割り当てられるshortcutも、この予約範囲に限る。

### 8.3 Project切替時

Projectを切り替えたとき、focusはそのProjectが最後に持っていたpaneへ戻る。

## 9. Latency budget

`docs/benchmarks/metric-contract.json`へ追加する。

| 操作 | p50 | p99 |
|---|---|---|
| keystroke → glyph描画（editor） | 16ms | 33ms |
| keystroke → glyph描画（terminal） | 16ms | 33ms |
| tab切替 | 33ms | 80ms |
| Project切替 | 80ms | 200ms |
| file open（1MB以下） | 50ms | 150ms |
| command palette表示 | 33ms | 80ms |
| Quick Open初回結果表示（10k files） | 100ms | 300ms |

このいずれかを恒常的に超える状態でcutoverしない。
principle 10の「cceditより明確に快適」は、この表で判定する。

## 10. Motion

- durationは120ms以下。それを超えるanimationを置かない。
- layoutの変化（split、pane追加）はanimationしない。即座に確定させる。
- animationしてよいのは、hover、press、overlayのfade、badgeの出現のみ。
- `accessibilityReduceMotion`が有効なとき、全てのanimationのdurationを0にする。
  現在`TactileButtonStyle`のみが対応しているので、全体へ広げる。

## 11. Accessibility

- 全てのinteractive elementが`accessibilityLabel`を持つ。
- 全ての操作がkeyboardだけで到達できる。到達できない操作はCommand Registryへ登録する。
- text/背景のcontrastは、常時読ませるtextで4.5:1以上、
  補助情報で3:1以上を満たす。組み合わせごとに検証記録を残す。
- 状態を色だけで伝えない。terminal stateはdotの色と、tooltipのtextの両方で伝える。

## 12. Session rail（新規提案）

Clairの差別化点であるため、contractに含める。

全てのProjectの全terminal/agent sessionを1つのlistで表示する。
表示する情報はPTYとprocessから得られる事実に限り、TUIの内容を解釈しない
（principle 3）。

| 列 | source |
|---|---|
| state | `TerminalSession.State` |
| agent種別 | 起動時のlaunch profile |
| Project | 所有Project |
| 実行context | Project root または managed worktreeのbranch |
| 経過時間 | session開始からの実時間 |
| 最後のsignal | bell / exit code / 公式hook |

行をclickするとその terminalへ移動する。
Projectをまたいだ移動を許可する（Project切替を伴う）。

「次のattentionへ移動」commandを持ち、shortcutを割り当てられる。

## 13. Agent rate limit

`AgentRateLimits.swift`として既に実装がある。この節はそれを追認し、密度だけを定める。

### 13.1 値の入力

| 入力 | 可否 |
|---|---|
| agentが報告した枠と残量（Codex app-server、Claude CodeのCLI出力） | 採用 |
| TUI画面からの読み取り | 不可（principle 3） |
| token数からのClair独自の推定 | 不可 |

取得できないときは推定せず、失敗として扱う。実装はこのとおりになっている。

### 13.2 表示

status barには**最も逼迫している枠を1つだけ**、1行で出す。
全providerを常に並べない。残りはclickで開くpopoverで見る。

meterのしきい値は実装に合わせる。

| 使用率 | token |
|---|---|
| 0–74% | `textTertiary` |
| 75–89% | `attention` |
| 90%以上 | `danger` |

通常時に`success`の緑を使わない。逼迫していない枠は色を持たない。

### 13.3 popover

- 未設定・未対応のproviderは1行にまとめる。1件ごとに72pxの行を作らない。
- segmented control、progress、dividerは`WorkspaceChrome`のcomponentを使う。
  `.pickerStyle(.segmented)`等のsystem描画を使わない（6.2と同じ）。
- 表示のon/offは設定に残す（`clair.agents.show-rate-limits-v1`）。
