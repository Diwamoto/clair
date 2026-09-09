# Clair Workbench — 動くモック

Clair UI の Design canvas を **実際に動く React 実装** に落としたモック。
`prototypes/clair-interaction-lab` がキャンバスの静止画（artboard の HTML を
そのまま埋め込んで文字一致でクリックを付けたもの）なのに対し、こちらは
状態を持った本物のコンポーネントとして組み直してある。IDE として触った
ときの操作感を確認するのが目的。

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
直す**。手順は `.claude/skills/clair-design-sync`。

## 共通パーツ

ヘッダー・サイドバー・フッターは `src/chrome.tsx` の1箇所だけにある。各画面は
それを組み立てるだけで、自前で描き直さない。

- `Titlebar` — 48px。`variant="workspace"` が Main artboard の並列タブ列、
  既定はそれ以外の画面が使う中央寄せの列。右側は各画面が children で渡す。
- `Sidebar` / `SidebarStrip` — 286px（Activity のみ 300px）の列と、その中の
  34px ナビゲーション。activity bar を独立した列にせずここに畳んでいるのが
  Tokens artboard の chrome budget の主張そのもの。
- `StatusBar` / `QuotaMeter` — 26px。
- `ScreenShell` — ヘッダー / 本体 / フッターの縦積み。

これで縦の chrome 予算（48 + 26 = 74px）が1箇所で決まる。

## ナビゲーション

サイドバーのナビゲーションは **エクスプローラー / マージグラフ / 変更を確認 /
実行とデバッグ / アクティビティ** の5つ。

- **検索はここに置かない。** ファイル・シンボル検索はヘッダーの検索欄に一本化した
  （`⇧⌘F`、`⌘P` も同じ窓を開く）。1つの仕事に入口が2つあるのを避けるため。
- **実行とデバッグ（虫アイコン）を追加。** デバッグ画面はここから開く。
  デバッグ画面自身にも同じナビゲーションが乗るので行き止まりにならない。

この2点はデザインキャンバス側（Main / SourceControl / Activity / Debug の
各 artboard）にも反映済み。

## 画面遷移

`src/motion.tsx`。軸は1本の z 軸で、ワークスペースが一番手前、他の画面はその
奥にいる。画面を離れると今の画面が奥へ退き、次の画面が同じ奥から出てくる
（戻るときはその逆）。ワークスペースとの関係が本当に違う3つだけ別の動きにして
あり、動きが「どこへ行ったか」を語るようにしている。

| 動き | 画面 | なぜ |
| --- | --- | --- |
| `depth` | 既定（ワークスペース・変更を確認・アクティビティ・デバッグ） | 奥へ退き、奥から出る |
| `slide` | マージグラフ ↔ 変更を確認 | ナビゲーション上の兄弟なので進行方向へ横移動 |
| `lift` | セッション | 全Project横断の1枚の表なので、奥からではなく下から上がる |
| `sheet` | 設定 | 奥ではなく手前に被さるシート |

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
| マージグラフ | `MergeGraph` | sidebar のブランチアイコン |
| アクティビティ | `Activity` | sidebar のベル、titlebar の Claude Code タブ |
| 実行とデバッグ | `Debug` | sidebar の虫アイコン、`⇧⌘D` |
| Debug + AI統合（検討中） | `DebugAgent` | `⌘K` →「Debug + AI統合」 |
| セッション | `SessionRail` | `⌃⌘L`、titlebar の codex タブ |
| Agentを追加 | `AddAgent` | `⌃⌘N`、セッション画面の「Agentを起動」 |
| 設定 | `Settings` | `⌘,`、titlebar の歯車 |
| モバイル | `MobileOverview` | `#/mobile`（設定 →「モバイル」からも） |

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
- **変更を確認** — ファイルを選ぶと差分が変わる。全差分 / commit済み /
  未commit のフィルタが効く。
- **アクティビティ** — メッセージを送れる。承認カードの3択が選べる。
- **デバッグ** — gutter クリックでブレークポイント、ツールバーの step で
  現在行とコンソールが動く。
- **セッション** — exit したセッションの再起動、行から画面遷移。
- **設定** — トグルとセクション切り替えが実際に効く。

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
