# Clair UI リファインメント実行プラン

作成日: 2026-09-19 / 対象: `prototypes/clair-workbench`（モック）と Clair UI Design canvas
（`https://claude.ai/code/artifact/8e7aded4-c0f1-46e4-af9c-4b9501ff4ce1`）

進め方は `.claude/skills/clair-workbench-sync/SKILL.md` に従う（モックと canvas を同じパスで更新、
報告は日本語、最後に両方のリンク）。**この文書で決めた値は決定事項**。独自に色・サイズを足さないこと。

## 0. 前提と方針

- **色は増やさない。** 新しい hue は追加しない。強調はすべて「明度」で行う（= 最も明るいインクがアクセント）。
  色相を持つのは従来どおり diff / debug / 状態の意味（attention・danger・success）と tab group の識別だけ。
- **面のグレーは現行値を維持する**（`canvas #282c34` / `chrome #31363f` / `surfaceHover #2e333c` / `surfaceActive #383d47`）。
- **フォントは macOS 標準**（SF Pro + ヒラギノ角ゴシック、コードは SF Mono）。
- canvas を読む/書くには `Artifact` ツールが必要。セッションに無い場合はモックだけ進め、
  「canvas に反映すべき差分」を最終報告に箇条書きで残す（canvas を勝手に諦めない・勝手に作らない）。

## 1. トークン（`src/tokens.ts`、canvas の Tokens artboard）

### 1-1. インクの色相を面と揃える

現状、面は OKLCH hue ≈ 263°（青寄りグレー）なのに、インクは hue ≈ 130–160°（緑寄りグレー）で
補色に近い組み合わせになっており、全体が濁って見える。インクを hue 264 に揃え、明度はほぼ維持する。

| token | 旧 | 新 | 対 canvas | 対 chrome |
| --- | --- | --- | --- | --- |
| textPrimary | #f1f3ef | **#f1f2f6** | 12.5 | 10.9 |
| textSecondary | #c9cec8 | **#caccd2** | 8.7 | 7.6 |
| chromeInk | #b6bcb6 | **#b7bac1** | 7.2 | 6.3 |
| textTertiary | #9ba19b | **#9b9fa6** | 5.3 | 4.6 |
| chromeInkMuted | #8a908b | **#9b9fa6**（textTertiary と統合） | | |
| textQuaternary | #707871 | **#81858d**（明度を上げる） | 3.8 | 3.3 |
| lineNumber | #4b5561 | **#5f636d** | 2.3 | 2.0 |
| divider | #3d454e | **#494d56** | | |
| textMuted | #55605a | **文字には使用禁止**。既存の 68 箇所は textQuaternary へ置換し、トークン自体を削除 | | |

- `line.*` / `wash.*` の `rgba(242,244,238,…)` は `rgba(241,242,246,…)` に置換（アルファ値はそのまま）。
- 本文のコード色（One Dark の codeXxx）は変更しない。
- `styles.css` のハードコード（`body` の `color`、`.hoverable` の背景色）もトークン値に揃える。

### 1-2. 文字サイズと太さ

macOS のテキストスタイルと同じ 4 段階にする。サイズ差ではなく、太さと色で強弱をつける。

| token | size / line-height | weight | macOS での対応 |
| --- | --- | --- | --- |
| `caption` | 11 / 16 | 400 or 600 | subheadline |
| `secondary` | 12 / 18 | 400 | callout |
| `body` | 13 / 20 | 400 or 600 | body / headline |
| `title` | 15 / 22 | 600 | title3 |

- 太さは **400 と 600 だけ**（ヒラギノの W3/W6 にきれいに対応する）。500 と 700 は廃止。
- 9 / 9.5 / 10 / 10.5 / 11.5 / 12.5 は廃止する。丸め方は、chrome なら下の段へ、読ませる本文なら上の段へ。
  ただし **11px 未満は作らない**。
- 例外: 設定ページの h1（20px）、Mobile の見出し（17 / 20 / 24px）は `display` トークンとして明示的に定義する。
- `body { font-size }` は 11 → 13。

### 1-3. 余白と角丸

- `space = [2, 4, 8, 12, 16, 24]`。2 はアイコンと文字の間などの極小用途だけ。6 / 3 / 5 / 7 / 9 / 10 / 11 / 13 / 14 / 18 は廃止し、
  最寄りの値へ丸める（10 → 8 または 12 は見た目で判断、原則は小さいほう）。
- `radius = { control: 4, card: 6, overlay: 10, pill: 999 }`。対応は 2 / 3 / 5 → 4、7 / 8 / 9 → 6、12 / 13 / 14 → 10、
  スイッチ類 → pill。44 は Mobile の端末フレームなので例外として残してよい。

## 2. タイポグラフィ（`src/styles.css`）

1. `-webkit-font-smoothing: antialiased` を**削除**する。
   macOS 標準の文字の太さ（ネイティブアプリと同じ見え方）になり、暗い背景での細すぎ感が消える。
2. sans のスタックは `-apple-system, BlinkMacSystemFont, 'Hiragino Sans', 'Hiragino Kaku Gothic ProN', sans-serif`。
   `'SF Pro Text'` の名前指定は削除する（光学サイズの自動切替が効かなくなるため）。
3. mono のスタックは `'SF Mono', ui-monospace, Menlo, 'Hiragino Sans', monospace`。
   **CJK の fallback にヒラギノを明示**して、等幅中の日本語がスカスカになるのを防ぐ。
4. 日本語 UI に `font-feature-settings: "palt" 1` を適用する（body に指定）。
   ただし長文（チャット本文、設定の説明文、コード / `.cl`）には `font-feature-settings: normal` を付けて戻す。
5. 数字が並ぶ場所（ステータスバー、表、時刻、件数、+42 / −9）には `font-variant-numeric: tabular-nums` を指定する。
6. 日本語に正の `letterSpacing` を付けない。該当する 14 箇所のうち日本語のものは削除する。
   「英語大文字＋字間あけ」の見出し（Sessions の表ヘッダー、Debug / Settings のセクションラベル）は、
   通常の大文字小文字の `caption` / 600 / textTertiary にする。
7. **等幅（`.cl` / `monoStyle`）はコード・パス・コマンド・ハッシュだけに使う。**
   85 箇所を監査して、ラベルやメタ情報（例:「3 / 6 files staged」「PermissionRequest」「作業ディレクトリ」「リスク」の見出し側）は sans に戻す。
8. 全角かっこの「コミット（3）」は、件数を別要素にする（半角、tabular-nums）。

※ SF Pro のサイズ別トラッキング（HIG の tracking 表）は、ネイティブの SwiftUI では自動で効く。
Web モックでは後回しでよい。入れる場合は HIG の値を `letterSpacing` に写し、目視で確認すること。

## 3. 面（surface）を 3 層に揃える

- 層は base（`canvas`）/ raised（`chrome`、サイドバー、ステータスバー）/ overlay（パレット、メニュー。`chromeRaised` 系）の 3 つだけ。
- **入力欄を黒く塗らない。** 置かれている面と同じ色に `1px line.hairline` の枠線を付ける。フォーカス時の見た目は §4 に従う。
  対象はコミットメッセージ欄、検索欄（タイトルバー、Agents の絞り込み、設定の検索）、パレットの入力欄、チャットの入力欄。
- **黒い帯をなくす。** diff のファイルヘッダー（`Review.tsx`）と Agents 一覧の表ヘッダー（`Sessions.tsx`）は、
  背景を塗らずに下側の hairline で区切る。
- diff の削除行は、旧行番号の列だけでなく**行全体**を danger の wash で塗る（今は新行番号の列だけ明るく抜けていて崩れて見える）。
- Agents 一覧で、表の下の空白に出ている色違いの帯を消す（背景を統一する）。
- 設定画面は、本文エリア・カード・入力欄で暗さが 3 段になっている。本文は canvas、カードは chrome にして枠線をなくし、
  入力欄は上記ルールに従う。

## 4. 色を足さない強調ルール（Tokens に「EMPHASIS」として追記）

| 用途 | 表現 |
| --- | --- |
| 主ボタン（コミット、今回だけ許可、Agent を起動） | 背景 textPrimary、文字 canvas、weight 600。hover で opacity .9 |
| 副ボタン | 背景なし、`1px line.strong` の枠、文字 textSecondary |
| 無効状態 | 副ボタンの見た目＋opacity .4（黒くしない） |
| トグル ON | トラック textSecondary、つまみ canvas |
| トグル OFF | トラック surfaceActive、つまみ textTertiary |
| フォーカスリング | `box-shadow: 0 0 0 1px line.ring`（入力欄・ボタン共通、`:focus-visible` のときだけ） |
| リストの選択 | 背景 surfaceActive＋文字 textPrimary。非選択は textSecondary。hover は surfaceHover |
| パレットの選択 | **ハイライトは 1 つだけ。** キーボード操作中はマウス hover で行をハイライトしない（選択そのものを移す） |
| 状態の表示 | バッジの背景を廃止し、「ドット＋テキスト」にする。入力待ち＝attention のドット（意味を持つ色なので許容）、実行中＝textPrimary の塗りドット、待機＝textQuaternary の中抜きリング、exit＝danger の × |
| タブグループ | 枠つきピルと全幅のカラー下線を**廃止**。グループ名の前に 6px の色ドット＋名前（weight 600、textSecondary）。アクティブなタブだけ、下に 1.5px の textPrimary の線 |

→ 画面に占める彩色の面積が大幅に減り、色はグループの識別と意味のある状態だけに残る。

## 5. 画面ごとの修正

**chrome（`chrome.tsx`）**
- サイドバー上部のアイコン列は `justifyContent: 'space-between'` をやめて左寄せ・gap 4 にし、「…」は右端に置く。
  アクティブ表示は背景 surfaceActive の 1 種類だけにする（`underline` prop と下線の描画を削除）。
- タブ名が切れる件は、タブの最小幅を確保し、切れる場合は末尾を省略記号（ellipsis）にする。
- ステータスバーの文字は textQuaternary 以上の明るさにする。区切りの「·」は削除して gap 12 で区切る。

**ファイルツリー（`screens/Workspace.tsx`）**
- テキストの「▾ / ▸」を SVG の chevron（10px、textTertiary）に置き換える。`icons.tsx` に 1 つ追加するだけ。
- プロジェクト名の行（clair / clair-docs）の黄色をやめ、textPrimary / 600 にする。
- 選択行のピルは左右マージンを「背景だけ」に効かせ、M / A バッジの右端をすべての行で揃える（今は選択行だけ約 11px 内側にずれる）。
- インデントは 1 段 12px に統一する。

**リストの選択表示の統一**
- ツリー、変更ファイル一覧、Agents のサイドバー、設定のナビは、すべて「内側に 8px 余白をとった角丸 4 のピル」にそろえる。
  Agents 会話一覧の端から端までの帯＋左の縦線もこれに置き換える。

**エディタ / ペイン**
- 非アクティブなペインは本文を opacity .75 にする（ヘッダーがないのでフォーカスの手がかりにする）。
- コード領域の右側に 16px の余白をとる。

**Agent 会話（`screens/Activity.tsx`）**
- 全要素（メッセージ、承認カード、入力欄）を幅 720px・中央寄せの 1 カラムに揃える（今は左端が 4 通り）。
- Agent の返答は吹き出しをやめ、背景なしの本文にする。吹き出しはユーザーの発言だけ（右寄せ、最大幅 85%）。
- タイムスタンプは hover したときだけ表示する。
- 承認カードは、拒否＝副ボタン、セッション中は許可＝副ボタン、今回だけ許可＝主ボタン。ボタンは等幅にせず内容に合わせた幅で、右寄せにする。
- 入力欄は §3 のルールに従い、右端に送信ボタン（主ボタンのスタイル、アイコンだけ）を置く。

**変更の確認（`screens/Review.tsx`）**
- コミットボタンは §4 の主ボタン（無効時は §4 の無効状態）にする。
- 「変更 / グラフ」のセグメントは、背景を塗らない形にする（選択側だけ surfaceActive）。
- 「3 / 6 files staged」は sans・caption・textTertiary にする。

**Agents 一覧（`screens/Sessions.tsx`）**
- 列見出しは日本語に統一する（例: エージェント / プロジェクト / 実行場所 / 経過 / 最後のシグナル / 利用枠）。caption / 600 / textTertiary。
- 「移動 ↵」は hover している行と選択行だけに出す。
- 状態の表示は §4 に従う。

**コマンドパレット（`screens/Overlays.tsx`）**
- 1 行・高さ 32px にする。コマンド ID（`clair.pane.…`）は表示しない（title 属性に入れる）。
- ヘッダー（「⌘ コマンド　Command Registry の全操作」＋ esc）を削除して、検索欄を最上段にする。
  モード切替（コマンド / ファイルへ移動）はフッターに残す。
- ショートカットは、キーごとに小さなキーキャップ（`1px line.hairline`、radius 4、caption、tabular-nums）で表示する。

**設定（`screens/Settings.tsx`）**
- 行の説明文は、行のタイトルだけでは意味が伝わらないものにだけ残す。カードの見出しにある説明文は削除する。
- トグルは §4 に従う。「~/Projects」は入力欄の見た目（§3）にし、右端に「変更…」の副ボタンを置く。

**Mobile（`screens/Mobile.tsx`）**
- デスクトップ側がすべて終わってから、§1〜§4 のトークン置換だけを行う。レイアウトは変えない。

## 6. canvas 側の更新

`clair-workbench-sync` の「Editing the canvas」の手順に従う（`scripts/canvas_edit.py` で extract / pack）。

- **Tokens:** インクの値（§1-1）、type scale（§1-2）、spacing / radius（§1-3）、EMPHASIS 表（§4）、面は 3 層（§3）。
- **Main:** タブグループの表現、サイドバー上部のアイコン列、ツリーの chevron とプロジェクト名の色。
- **Activity:** 1 カラム化、Agent の返答は吹き出しなし、承認ボタンの扱い。
- **CommandPalette:** 1 行化、ヘッダー削除、キーキャップ。
- **SessionRail:** 列見出しの日本語化、状態の表示方法。
- **SourceControl:** コミットボタン、ヘッダー帯の廃止、削除行の塗り。
- **Settings:** トグル、入力欄、説明文の削減。

## 7. 検証（全部通るまで完了扱いにしない）

```bash
cd prototypes/clair-workbench
# 数値リテラルが tokens.ts 以外に残っていないこと（Mobile.tsx の display 例外は目視で確認）
grep -rEn "fontSize: ?[0-9]" src --include=*.tsx | grep -v Mobile.tsx      # → 0 行
grep -rEn "(gap|borderRadius): ?[0-9]" src --include=*.tsx | grep -v Mobile.tsx  # → 0 行
grep -rn "textMuted\|#55605a\|242,244,238" src                                # → 0 行
grep -rn "antialiased" src/styles.css                                          # → 0 行
npm run artifact && git diff --check
```

スクリーンショットで、ワークスペース / 変更の確認 / Agent 会話 / Agents 一覧 / パレット / 設定を修正前後で比べる。
ヘッドレス Chrome で撮る場合の注意:
- 画面は JS の `element.click()` で切り替え、1.5 秒以上待ってから撮る（遷移アニメーションが headless では遅い）。
- `Emulation.setDeviceMetricsOverride` と `Input.dispatchMouseEvent` の組み合わせは座標がずれて誤クリックする。
  倍率は起動引数の `--force-device-scale-factor=2 --window-size=1440,900` で指定する。

## 8. 完了時

- 親リポジトリで、フェーズごとにコミットする（トークン → typography → 面 → 強調 → 各画面）。ブランチは `rewrite/clair-v2` のままでよい。
- モック（`dist/artifact.html` → `https://claude.ai/code/artifact/89251d23-43a1-47ff-93c3-7c1be1069895`）と canvas を再 publish する。
- 日本語で報告する。「実施した判断」「canvas に反映できなかった差分（あれば）」を明記し、最後に 2 つのリンクを載せる。
