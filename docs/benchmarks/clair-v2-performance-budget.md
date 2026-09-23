# Clair v2 performance budget

Clair v2 の性能契約の正本。ここで定めた予算は「近づける目標」ではなく、
**超えたら失敗**として機械的に検証される。

本書は Clair の**全機能**に対する予算契約である。

## 1. 予算

### `BUDGET-OP-100`: 操作は 100 ms 以内

ユーザーが起動した操作は、**p95 で 100 ms 以内**に完了する。

100 ms を超える操作は 100 ms 以内に完了させるか、さもなくば
**background 実行 + ローディング表示**にする。この 2 つ以外は認めない。
「速いマシンでは間に合う」は根拠にならない。予算は敵対的 corpus (§3) 上の p95 で測る。

分類は 2 つだけで、どちらかを宣言しないと計測対象にできない。

| 分類 | 意味 | 判定 |
|---|---|---|
| `.mainThread` | main thread / MainActor 上で同期実行される | p95 > 100 ms で **失敗** |
| `.background(affordance:)` | 専用 thread/Task で実行し、UI に進捗を出す | 時間は記録のみ。`affordance` が UI 実装に存在しないと **失敗** |

`.background` の `affordance` は、進捗を出している実際の UI 記号名
(`ProgressView` を出す state など) を書く。名前だけ宣言して spinner が無い経路は
契約違反として落ちる。

### `BUDGET-START-HALFBOUNCE`: 起動はハーフバウンス以内

**製品版 (`.app` bundle, Release build)** の `exec` から
**最初のフレーム提示**までが、Dock の launch bounce 半周期以内。

Dock の bounce は 1 往復 ≈ 600 ms なので、半周期 = **300 ms**。
これは calibration 値であり、実機の bounce 周期が違えば
`scripts/benchmarks/run-startup.sh` の `HALF_BOUNCE_MS` を実測値へ合わせる。

- `warm`: 連続再起動。予算 **300 ms**。
- `cold`: `sudo purge` 後の初回。予算 **600 ms** (1 バウンス)。cold は
  filesystem cache を制御できないので、warm を主指標とする。

起動時に実行される作業はすべてこの予算に入る。workspace の restore、
最初のフレームに必要な state 構築が対象で、disk 走査、`git status`、daemon 健全性、
update check は最初のフレームの後ろに置かれていること。

### `BUDGET-MEM`: 常駐メモリ

仕様 §5.8 `INV-PERF-004` を継承する。開いている文書の常駐メモリは byte
サイズの小さな定数倍 + viewport 状態に収まる。予算値は
`EditorBaselineEvidence.swift` の regression ceiling を下限として使う。

## 2. 実行方法

```bash
# 操作予算 (BUDGET-OP-100)。敵対的 corpus を生成して全操作を計測する。
make perf-budget

# 製品版起動 (BUDGET-START-HALFBOUNCE)。Release build → .app bundle → 計測。
make perf-startup          # warm 5 trials
./scripts/benchmarks/run-startup.sh --cold   # sudo purge を挟む
```

結果は `docs/benchmarks/results/<UTC日付>-<host>/` へ JSON で落ちる。
契約の正本は
[`PerformanceBudgetTests.swift`](../../packages/ClairCore/Tests/ClairCoreIntegrationTests/PerformanceBudgetTests.swift)
の operation table であり、本書はその読み方を書いたもの。表と本書が食い違ったら表が正しい。

## 3. 敵対的 corpus

各機能を否定的に確認するため、corpus は「普通のリポジトリ」ではなく
**壊しに来る形**で作る。`BudgetCorpus` が生成する。

| 名前 | 内容 | 何を壊しに来ているか |
|---|---|---|
| `wide` | 20,000 ファイル / 400 ディレクトリ、clean commit | `WorkbenchFiles.limit` の cap ちょうど。tree 走査と Quick Open の O(n) |
| `deep` | 深さ 40 の入れ子、底に 200 ファイル | path 分割・`treeOrder` の比較コスト |
| `dirty` | 5,000 ファイル中 3,000 変更 + 1,000 untracked | `git status --untracked-files=all` の出力量と parse |
| `10mb` | 10 MiB Swift / 200,000 行 (既存 fixture) | ファイル open / save / 編集 / 検索 |
| `long-line` | 1 MiB = 1 行 (既存 fixture) | 行単位の前提を持つ経路すべて |
| `1mb-japanese` | 1 MiB UTF-8 多バイト (既存 fixture) | grapheme / UTF-8 変換コスト |
| `large.json` | 約 4 MiB の入れ子 JSON | tree-sitter の初回 parse と差分 parse |

`10mb`、`long-line`、`1mb-japanese` は `EditorFixtureGenerator.canonicalFixtures`
を再利用する。新しい fixture 生成器は作らない。

corpus は `/tmp/clair-perf-corpus-v<layoutVersion>` に cache され、
`--regenerate` か `layoutVersion` の変更で作り直す。生成に 40 秒ほどかかる。

`.background` の判定は `ClairAppKit` の source を読んで行う。
affordance が UI 層に存在しないと落ち、さらに p95 が 100 ms を超える操作は
`ProgressView` を持つ**同じファイル**に affordance が現れることを要求する。
100 ms 以内の background 操作は表示を要求しない (出す必要がない)。

## 4. 計測規約

percentile rule:

- nearest-rank p95、`sorted[ceil(0.95 * n) - 1]`
- 1 回の warm-up を捨ててから計測する
- 反復回数は operation ごとに表で宣言する (最低 5、UI 入力系は 20)
- 同一 workload / corpus / build mode / metric / unit 以外を比較しない
- Release build で測る。Debug 値を予算判定に使わない

## 5. 既知の違反と対応

予算を満たせない操作は、予算を緩めるのではなく
`.background(affordance:)` へ移すことで解消する。

最新 run:
[2026-09-22 / Mac mini M4](results/2026-09-22-Mac16,10/README.md)。
起動は合格 (p95 195.18 ms / 予算 300 ms)。UI から到達できる 35 操作は合格し、
未実装の構文ハイライト 2 操作だけが affordance 未接続として意図的に赤く残っている。
