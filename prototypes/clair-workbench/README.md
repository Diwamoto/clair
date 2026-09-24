# Clair Workbench — 動くモック

Clair UI の Design canvas を **実際に動く React 実装** に落としたモック。
状態を持った本物のコンポーネントとして組み直してあり、IDE として触った
ときの操作感を確認するのが目的。

このモック自身も Artifact として公開されている
（`https://claude.ai/code/artifact/89251d23-43a1-47ff-93c3-7c1be1069895`）。
**キャンバス（下記）とは別 URL** — 更新するときは `npm run artifact` の
`dist/artifact.html` をこの URL に publish する。キャンバスの URL に誤って
publish しないこと（build 出力でキャンバスの appifact-doc を上書きしてしまう）。

## 正本はキャンバス

デザインの正本は Claude Design の **Clair UI** キャンバス
（`https://claude.ai/code/artifact/8e7aded4-c0f1-46e4-af9c-4b9501ff4ce1`）。
値は全部そこから写しており、**React 側の都合で見た目を変えることはしない**。

- `src/tokens.ts` — Tokens artboard の写し。色・タイプスケール・radius・
  spacing・chrome budget（titlebar 48 + status bar 26 = 74px）。
- `src/icons.tsx` — 各 artboard の SVG パスをそのまま React 化したもの。
- 画面のレイアウト値（286px sidebar、34px activity strip、44px overlay
  header、40px 行など）は artboard の inline style をそのまま使っている。

キャンバスが描いていない状態（hover、フォーカス、空状態）は、Tokens
artboard が定義しているトークン（`surfaceHover` / `surfaceActive` /
EMPTY STATE コンポーネント）だけで作っている。新しい見た目は足していない。

キャンバス側が間違っている・足りないと分かったら、**モックで直さずキャンバスを
直す**。手順は `.claude/skills/clair-workbench-sync`。

## アプリの外枠

**Main artboard のヘッダー・サイドバー・フッターがアプリの外枠**であり、全画面で
そのまま使う。`src/chrome.tsx` の `AppShell` が一度だけ組み立て、以降アンマウント
されない。切り替わるのは**サイドバーの中身とメイン領域だけ**。

```
AppShell
├─ AppTitlebar   48px  traffic lights / project タブ / 他Project / 検索 / ⌘K / 設定
├─ body
│  ├─ Sidebar    286px  SidebarStrip(34px) + panel   ← panel だけ差し替わる
│  └─ main                                            ← ここだけ差し替わる
└─ AppStatusBar  26px  branch / 変更数 / 画面固有 / 利用枠 / セッション数
```

他の artboard がそれぞれ自前のヘッダーを描いているのは、artboard が静止画1枚
だからであって、別のchromeが存在するという意味ではない。**それらは内部パーツ
として扱う**。各画面が出すのは3つだけ：

| 画面 | panel（サイドバー） | main | status |
| --- | --- | --- | --- |
| ワークスペース | ファイルツリー | ペイン | Ln, Col |
| 変更を確認 | ステージ済み/変更 + コミット | 全幅diff | 対象ファイル |
| （↳ グラフ切替） | 変更を確認と同じ | グラフ表 | 対象ファイル |
| アクティビティ | アクティビティ一覧 | チャット + 承認 | Claude Code · 実行中 |
| 実行とデバッグ | breakpoint / callstack / 変数 | エディタ + コンソール | 現在行 |
| セッション | （未定義→ツリー） | セッション表 | 入力待ちバッジ |
| 設定 | セクション一覧 | 設定本文 | 設定 · セクション名 |

**マージグラフは「変更を確認」の中の一モード**（git GUI ツールが履歴グラフに
独立したタブを与えないのと同じ発想）。sidebar には専用アイコンを持たず、
`SourceControlModeTabs`（`chrome.tsx`）という「変更 / グラフ」の2択が
`MainHeader` の中に入り、`wb.screen` を `review` ↔ `graph` で切り替える。
panel（サイドバー）は両モードとも同じ変更ファイル一覧のままなので、この
consolidation で「マージグラフにはキャンバス上サイドバーの定義がない」という
以前のギャップも解消した。

**パネルはVSCodeのSource Controlと同じstage/changesモデル**。以前は
「COMMIT済み / 未COMMIT」という、実際には「過去のコミットで変わったファイル」対
「作業ツリーの変更」を混同したグルーピングだったが、それをやめて
「ステージ済みの変更 / 変更」という素の `git status` の形に揃えた
（`store.tsx` の `workingPaths` / `stagedPaths`、`data.ts` の
`initiallyStagedPaths`）。ファイル行末の「+」「−」とセクション見出しの
一括「+」「−」で実際にstage/unstageでき、コミットメッセージ欄に入力すると
「コミット」が有効になって、押すとステージ済みのファイルが working set から
消える——コミット履歴として積み上がるわけではない。**キャンバスとの差分**:
`SourceControl` artboard のサイドバーとヘッダーもこの形に描き直し、branch→branch
の diff pill と「merge commitで採用」ボタン（これは branch/PR レビューという
別モデルの名残だった）は削除した。

### タブ

タブは **168px 固定幅**（Main artboard の 124–210px の帯の中）。名前が入りきらない
場合は省略記号ではなく **右端でフェードして隠す**。フェードは「まだ続きがある」を
文字を使わずに伝えられるし、切れ目でも文字のインクが濁らない。実際にはみ出した
タブにだけ適用し、収まっているタブは最後の一文字まで通常の濃さのまま。全名は
hover のツールチップで読める。

**プロジェクトごとのタブグループ**。titlebar には `clair` / `ccedit` /
`clair-releases` の3プロジェクトが並び、それぞれが Chrome のタブグループの
ように自分の chip（プロジェクト名。色は chip 自身の塗りで持つ、詳細は下記の
グループカラー）と自分のタブ行を持つ。既定では全グループが展開済みで、
どのプロジェクトのタブも同時に見える。chip をクリックすると、そのグループの
タブ行が `grid-template-columns: 1fr → 0fr` で自分の chip へ向かって畳まれる
（折りたたみアイコンは出さない — chip 自体がトグルなので不要と判断した。
`activeProject` には触らない — 今開いているグループを畳んでも main の内容は
変わらない）。`clair` 以外の2グループは実データ（開ける
ファイル）を持たないため、`data.ts` の `projectTabs` にモックが既に知っている
情報（ccedit のセッション worktree と `ProjectLayout.restore()` の言及、
clair-releases は汎用のプレースホルダー）から1タブずつ立てている。**キャンバス
との差分**: `Main` artboard もこの3グループ展開状態を描くよう直したが、
`projectTabs` の中身（ファイル名）はキャンバスに定義がない発明であり、正式な
ファイル名が決まったらキャンバス側で上書きしてほしい。

**グループカラー**。色は chip 自身の塗り（背景14〜22%・枠28〜55%の alpha、
`withAlpha`、`tokens.ts`）として乗る — 別立てのドットは持たない。chip を
右クリックすると右クリックメニュー（下記）が開き、その先頭に
`GROUP_COLOR_KEYS`（`tokens.ts`）の見本が並ぶので、そこで選ぶ
（Chromeがタブグループの色pickerを右クリック起点に置くのと同じ）。左クリックは
これまで通り折りたたみのトグル。同じ色でグループ全体（chip + タブ）の下に
2pxのアンダーラインも敷く — どこまでが1つのグループのタブかを縦の区切り線
だけでなく色でも示すため。既定は
`clair`=blue / `ccedit`=green / `clair-releases`=amber。パレットは新しい色相を
足さず、diff/debugの既存アクセント（success・attention・danger・debugBlue・
codeKeywordのpurple）を使い回した6色（+ 無色のgray）。**キャンバスとの差分**:
Tokens artboard の「PROJECT識別 — 色を使わない」という既存ルールと正面から
矛盾する変更なので、今回のユーザー判断でそのルールごと GROUP COLORS
セクションに書き換えた（success/attention/danger が diff・debug 専有という
本筋のルール自体は変えていない）。

デバッガの停止バッジのような画面固有の表示は、2段目の行を作らずに
`AppTitlebar` の `extra` スロットへ入れる。画面が自分の44pxヘッダーを持つ場合
（変更を確認・セッション・マージグラフ）は `MainHeader` としてメイン領域の中に
置く。これは chrome ではなく画面の一部。

これで縦の chrome 予算（48 + 26 = 74px）が全画面で1箇所に決まる —
ただしエディタのパンくず（下記）だけは意図的な例外で、pane 自身が縦を消費する。

**キャンバスとの差分**: セッションにはキャンバス上サイドバーの定義がないため、
エクスプローラーのツリーのままにしてある。ここを埋めるのはキャンバス側の作業で、
モック側で発明はしない。（マージグラフは今回の変更でセッションと同じ立場から
外れ、変更を確認と同じ panel を使うようになった。）

### 右クリックメニュー

IDE の中ではブラウザ（アプリでは AppKit）のメニューを一切出さない。Tokens の
CONTROLS「nativeを混ぜない」をメニューにも当てはめた。部品は
`src/contextMenu.tsx`（`ContextMenuLayer` / `useContextMenu`）、各面が何を
持つかは `src/menus.tsx`。正本はキャンバスの **ContextMenu** artboard。

| 面 | ヘッダー | 中身 |
| --- | --- | --- |
| titlebar の project chip | Project名・パス | 色見本 / 切り替え・折りたたみ・名前を変更 / 左右へ移動 / Projectを閉じる |
| ファイルのタブ | ファイル名・ディレクトリ | タブを閉じる系 / 分割して開く / Agentに送る › / 変更を確認 / パスのコピー・Finder |
| Claude Code / codex のタブ | セッション | 開く / Agentsの一覧 / Agentを追加 |
| ファイルツリー | 名前・パス | 開く / 分割して開く / Agentに送る › / 変更を確認 / パスのコピー・Finder（フォルダは開閉とパス） |
| エディタ | なし | 切り取り・コピー・ペースト / Agentに送る › / 保存 / 分割・最大化 / ペインを閉じる |
| ターミナル・agent 出力 | なし | コピー・ペースト・クリア（agent は会話を開く）/ 分割・最大化 / ペインを閉じる |

見た目は既存トークンだけで組んである。地は chromeRaised、枠は line.strong、
半径は overlay の 10、影はコマンドパレットと同じで、scrim は敷かない。行は
26px・半径 6（padding 4 の内側で 10 と同心）。hover とキーボード選択はどちらも
surfaceActive の塗りだけ。破壊的な項目は最後に置いて weight 700（赤にしない）。
開くときは LATENCY BUDGET の palette 表示に合わせて 90ms、ポインタに近い角から
0.97→1。閉じるときは動かさない。

ルールは3つ。**ヘッダーは対象がオブジェクト（ファイル・Project・セッション）の
ときだけ**で、選択範囲やペインには出さない。**いま実行できないだけの操作は
disabled で残し**（位置を覚えられるように）、その対象に意味のない操作は出さない。
**同じ操作は同じ名前**（「Agentに送る ›」「右に分割」はどこでも同じ文言・
ショートカット）。右クリックした行・タブ・chip は、メニューが開いている間
line.ring のリングをまとう。

キーボードは ↑↓ / → で submenu / ← / ↵ / esc（1段ずつ閉じる）。外側のクリックは
閉じるだけで下に届けず、別の場所の右クリックはそこで開き直す。

**chip の右クリックは「色を送る」から「メニュー」に変わった。** 色はメニュー
先頭の見本で選ぶ。native 版の project メニュー（切り替え・名前変更・
グループカラー・移動・閉じる）と同じ項目を持たせたうえで、titlebar の並びは横
なので「上へ/下へ移動」は「左へ/右へ移動」にした。名前の変更は chip がその場で
入力欄になる（↵ で確定、esc で戻す）。

**モックでは動かないもの**: 「Finderで表示」はブラウザから開けないので、押しても
閉じるだけ。コピー / ペーストは Clipboard API を使うので、Artifact の枠が
許可しない環境ではペーストが黙って何もしない。

**キャンバスとの差分**: `ContextMenu` artboard を新規追加した（chip・ツリー＋
submenu・エディタ・ターミナルの4場面と、ANATOMY / STATES / RULES）。Tokens の
GROUP COLORS の「右クリックで色を送る」を「メニュー先頭の見本で選ぶ」に書き換え、
CONTROLS に右クリックメニューの1行を足した。分割アイコン（`IconSplitRight` /
`IconSplitDown`）はこの artboard が初出。

### パンくず

エディタの各 pane の最上部に、開いているファイルのパスをパンくず表示する
（`PathBreadcrumb`、`screens/Workspace.tsx`）。**これは Tokens artboard の
既存ルールと矛盾する変更**：CHROME BUDGET のメモには元々「activity barは
sidebarの中、breadcrumbはstatus barへ移す。splitしても縦chromeは74pxのまま
増えない」と書かれていた——つまりパンくずは pane を割っても chrome が増えない
よう status bar 側に置く設計だった。今回はユーザーの判断で「エディタの一番上に
文字通り」を優先し、pane を横に割ると（`⌃⌘D`）パンくずも複製される・縦chrome
は74pxの主張から外れる、という trade-off を受け入れた。Tokens artboard 側の
メモもこの trade-off を明記する形に書き換えている。

## ナビゲーション

サイドバーのナビゲーションは **エクスプローラー / 変更を確認 /
実行とデバッグ / アクティビティ** の4つ。

- **マージグラフに専用アイコンはない。** git GUI ツール（GitKraken や Fork の
  ような）が履歴グラフに独立したタブを与えないのと同じ発想で、グラフは
  「変更を確認」という1つのツールの中の一モードとして扱う。「変更を確認」を
  開くと、そのヘッダーの「変更 / グラフ」で切り替えられる（詳細は上の画面表）。
- **検索はここに置かない。** ファイル・シンボル検索はヘッダーの検索欄に一本化した
  （`⇧⌘F`、`⌘P` も同じ窓を開く）。1つの仕事に入口が2つあるのを避けるため。
- **実行とデバッグ（虫アイコン）を追加。** デバッグ画面はここから開く。
  デバッグ画面自身にも同じナビゲーションが乗るので行き止まりにならない。

この2点と、マージグラフのアイコン削除はデザインキャンバス側
（Main / SourceControl / Activity / Debug / MergeGraph の各 artboard）にも
反映済み。

## 画面遷移

`src/motion.tsx`。**動くのはメイン領域とサイドパネルだけ**で、ヘッダー・
ナビゲーション・フッターは動かない。軸は1本の z 軸で、ワークスペースが一番手前、他の画面はその
奥にいる。画面を離れると今の画面が奥へ退き、次の画面が同じ奥から出てくる
（戻るときはその逆）。ワークスペースとの関係が本当に違う3つだけ別の動きにして
あり、動きが「どこへ行ったか」を語るようにしている。

| 動き | 画面 | なぜ |
| --- | --- | --- |
| `depth` | 既定（ワークスペース・変更を確認・アクティビティ・デバッグ） | 奥へ退き、奥から出る |
| `slide` | マージグラフ ↔ 変更を確認 | 同じツールの中の2モードなので進行方向へ横移動（`SourceControlModeTabs` からの切り替えでもこのまま使う） |
| `lift` | セッション | 全Project横断の1枚の表なので、奥からではなく下から上がる |
| `sheet` | 設定 | 奥ではなく手前に被さるシート |
| `fade` | サイドパネル | 286px の幅で depth や slide をやると破綻して見えるため |

**ランダムには変えていない。** Tokens artboard が「静かで集中しやすい」表示を
掲げている以上、同じ操作が毎回違う動きをするのは設計の主張と噛み合わない。
画面ごとに固定なら、動き自体が場所の手がかりになる。変えたければ
`src/motion.tsx` の `KIND` 表1つを書き換えれば済む。

尺は Tokens artboard の LATENCY BUDGET から取った。Project切替が 80 / 200ms
なので画面遷移は 200ms、palette表示が 33 / 80ms なのでオーバーレイは 90ms。
`prefers-reduced-motion: reduce` では全部止まる。

## 画面

| 画面 | artboard | 入口 |
| --- | --- | --- |
| ワークスペース | `Main` | 起動時 / `esc` |
| 検索 | `Search` | `⇧⌘F`、titlebar の検索欄 |
| コマンドパレット | `CommandPalette` | `⌘K`（ファイルへ移動は `⌘P`） |
| 変更を確認 | `SourceControl` | sidebar の盾アイコン、`⌃⌘G` |
| （↳ グラフ切替） | `MergeGraph` | 変更を確認 画面ヘッダーの「変更 / グラフ」 |
| アクティビティ | `Activity` | sidebar のベル、titlebar の Claude Code タブ |
| 実行とデバッグ | `Debug` | sidebar の虫アイコン、`⇧⌘D` |
| Debug + AI統合（検討中） | `DebugAgent` | `⌘K` →「Debug + AI統合」 |
| セッション | `SessionRail` | `⌃⌘L`、titlebar の codex タブ |
| Agentを追加 | `AddAgent` | `⌃⌘N`、セッション画面の「Agentを起動」 |
| 設定 | `Settings` | `⌘,`、titlebar の歯車 |
| モバイル · 概要 | `MobileHome` | `#/mobile`（設定 →「モバイル」からも） |
| モバイル · セッション | `MobileOverview` | モバイルのタブ |
| モバイル · アクティビティ | `MobileActivity` | モバイルのタブ |
| モバイル · 設定 | `MobileSettings` | モバイルのタブ |
| モバイル · ターミナル | `MobileTerminal` | セッション/概要/アクティビティの「ターミナルを開く」 |
| モバイル · ペアリング | `MobilePairing` | モバイルの設定 →「端末を追加」 |

## 動くところ

- **ファイルツリー** — フォルダの開閉、クリックでタブを開く、M/A バッジ。
- **エディタ** — 実際に編集できる。Swift/Go/Markdown をトークン単位で
  ハイライトし、gutter・ハイライト層・キャレット行・status bar の Ln/Col が
  同期する。`⌘S` で dirty を落とす。
- **ペイン** — divider をドラッグして比率を変える。`⌃⌘D` / `⌃⌘⇧D` で分割、
  `⌃⌘W` で閉じる、`⌃⌘M` で最大化、`⌃⌘=` で均等化、`⌃⌘→` でフォーカス移動。
  Main artboard のツリー（editor | agent / terminal）が初期状態。
- **ターミナル** — `y` / `N` で codex の承認プロンプトに答えられる。
  `git status`、`swift test …`、`clear` が動く。
- **コマンドパレット / ファイルへ移動 / 検索** — 打った文字で本当に絞り込み、
  ↑↓ で選択、↵ で実行（分割・画面遷移・ファイルを開く）。検索はファイル本文を
  横断して行番号付きでヒットを出す。
- **変更を確認** — VSCodeのSource Controlパネルと同じ操作感。ファイルを選ぶと
  差分が変わる。行の「+」「−」でファイル単位のstage/unstage、セクション見出しの
  「+」「−」で一括stage/unstage、コミットメッセージを書いて「コミット」を押すと
  ステージ済みのファイルが working set から消える（履歴には残らない——コミット
  履歴を見るのはグラフモードの仕事）。
- **アクティビティ** — メッセージを送れる。承認カードの3択が選べる。
- **デバッグ** — gutter クリックでブレークポイント、ツールバーの step で
  現在行とコンソールが動く。
- **セッション** — exit したセッションの再起動、行から画面遷移。
- **設定** — トグルとセクション切り替えが実際に効く。
- **右クリックメニュー** — chip・タブ・ファイルツリー・エディタ・ターミナル・
  agent 出力で開く。色見本、Project の改名・並べ替え・閉じる、タブをまとめて
  閉じる、分割して開く、Agent に送る（clair の Claude Code には `@path` つきで
  会話に届く）、切り取り / コピー / ペースト、ペイン操作が実際に効く。

## モバイル

モバイルは**デスクトップの縮小版ではない**。仕様
（`docs/projects/p0020-mobile-agent-remote-control/`）が non-goal として
「mobile full IDE、source editor、file browser、diff/review」を明示的に外して
いるので、モバイルが持つのは**席を離れたあと agent を見て返すための経路だけ**。
IDE をそのまま小さくした画面は作らない。

タブは **概要 / セッション / アクティビティ / 設定** の4つ。ターミナルと
ペアリングはこの4つの中から push で開く画面で、5つ目のタブにはしない
（push した画面は tab bar を外して 44px の戻りバーに替える）。

| 画面 | 何を持つか | 仕様の根拠 |
| --- | --- | --- |
| 概要 | host identity（endpoint・fingerprint・protocol）、要対応、Project別のセッション数 | `FR-01` `FR-19`、Motivation |
| セッション | 全Projectのagent/terminalカタログ。exit・worktree を明示 | `FR-08` `FR-13` |
| アクティビティ | attention の履歴。**どのsessionが呼んだかと時刻だけ** | `FR-11` `QR-02` `AC-07` |
| 設定 | この端末の scope、経路と fingerprint、ペアリング済み端末と revoke | `FR-17` `FR-18`、pairing records |
| ターミナル | raw PTY。gap は明示、viewport は client-local | `G-01` `FR-03` `FR-04` `FR-07` |
| ペアリング | one-time link の指紋読み合わせ。初期 scope は `view` のみ | `FR-16` `FR-09` `AC-11` |

守っている線が3つある。**scope は減った側も見せる**（`terminate` /
`spawn_session` / `manage_devices` は破線のチップで、付与されていないことが
見える）。**通知に内容を載せない**（アクティビティに出るのは agent 名・
Project・signal の種類・時刻だけで、terminal の中身は1文字も出さない）。
**gap を黙って飛ばさない**（ターミナルの scrollback に「欠落 2.3 KB ·
保持範囲外」の区切りが入る）。

色は増やしていない。Tokens の「色を持つのはdiff・debug・タブグループだけ」は
モバイルでも同じで、接続中も入力待ちも要対応もすべてグレースケール。緑の接続
ドットも赤い revoke ボタンも持たない — 破壊的操作は色ではなく weight 700 で
区別する（Tokens の CONTROLS の破壊的ボタンそのまま）。

**キャンバスとの差分**: 以前キャンバスにあったモバイル画面は `MobileOverview`
（セッション）の1枚だけだった。残り5枚は今回キャンバス側に新規追加してある
（`MobileHome` / `MobileActivity` / `MobileSettings` / `MobileTerminal` /
`MobilePairing`）。あわせて Tokens artboard に **MOBILE** 節を足し、これまで
`MobileOverview` の inline style にしか無かったモバイル寸法（390×844、上54pxは
実機のstatus barの場所、tab bar 78px、gutter 16px、touch 44px、radius は card 10
/ button・field 8）をルールとして書いた。モバイルの radius が desktop の
4-6-10 と違うのはこの節が根拠。

### Live / Design 比較

`?review=1` を付けると各画面に Live/Design の切替が出て、走っている実装と
その画面の artboard を並べて見られる。artboard のスナップショットは
`src/mobile-artboards.ts` にあるが、**手で書き写していない** —
キャンバスから機械的に生成する:

```bash
python3 .claude/skills/clair-workbench-sync/scripts/canvas_edit.py \
  extract <saved-canvas.html> /tmp/canvas/
node scripts/mobile-artboards.mjs /tmp/canvas
```

写経すると比較がキャンバスではなくモックに同意し始めるので、キャンバスが
変わったら生成し直す。artboard 側の CSS は `.dc-board` の下にスコープして
あるので、artboard の `.cl` / `.card` が周りの実装に漏れない。

## スマホから見る

- `#/mobile` — モバイルアプリ。実機（幅 460px 以下）では全画面、デスクトップ
  ブラウザでは 390×844 の枠の中に出る。
- `#/ide` — デスクトップの IDE。幅 1000px 未満では **レイアウトを崩さずに
  縮小表示** する（1440×900 のまま transform でスケール）。下の小さなバーで
  ズームとフィットを切り替えられる。このバーだけはビューア用の器で、
  デザインの一部ではない。

レスポンシブに組み替えないのは意図的。狭い画面向けに畳んだ時点で「デザインを
厳守する」が守れなくなるため。

## 動かす

```bash
npm install
npm run dev     # http://localhost:5174（--host 付きなので LAN からも見える）
npm run build   # dist/index.html 1枚に全部インライン
```

`npm run build` は `vite-plugin-singlefile` で JS/CSS を全部 HTML に埋め込むので、
`dist/index.html` を置けばどこでも動く（サーバ不要）。
