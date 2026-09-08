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

## 画面

| 画面 | artboard | 入口 |
| --- | --- | --- |
| ワークスペース | `Main` | 起動時 / `esc` |
| 検索 | `Search` | `⇧⌘F`、titlebar の検索欄、sidebar の虫めがね |
| コマンドパレット | `CommandPalette` | `⌘K`（ファイルへ移動は `⌘P`） |
| 変更を確認 | `SourceControl` | sidebar の盾アイコン、`⌃⌘G` |
| マージグラフ | `MergeGraph` | sidebar のブランチアイコン |
| アクティビティ | `Activity` | sidebar のベル、titlebar の Claude Code タブ |
| 実行とデバッグ | `Debug` | `⇧⌘D` |
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
