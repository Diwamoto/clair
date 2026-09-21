# Clair text engine surface baseline

## Purpose

[ADR-0014](../decisions/0014-clair-owned-text-engine.md)のtext engine program（`P17`〜`P34`）が使う
surface計測の正本手順です。`P17`で**現行既定**（WKWebView上のCodeMirror editorと
現行のAppKit terminal surface）の基準値を取得し、`P34`で同一host・同一fixture・同一操作の
engine計測と比較します。

これは[ccedit V1 baseline](clair-v1-baseline.md)とは別のcaptureです。V1 baselineはcutover全体を
判断する`L01`のためのもので、engine programは比較対象をClair自身の現行既定に限ります。
[PoC queue](../clair-tasks.md)のbenchmark方針はこのprogramにだけ例外を設けており、
他のfeature itemへ広げません。

## Identity and contract

| 対象 | 正本 |
|---|---|
| metric定義 | [text-engine-metric-contract.json](text-engine-metric-contract.json) |
| corpus | [corpus recipe](corpus/README.md)（`scripts/benchmarks/generate-corpus.sh`） |
| 集計 | `scripts/benchmarks/summarize-engine-baseline.rb` |
| 検証 | `scripts/benchmarks/validate-result.rb` |
| 保存先 | [`results/`](results/) の日付directory |

contractは4つのsurfaceを定義します。`editor.codemirror`と`terminal.appkit-grid`が現行既定、
`editor.clair-text-engine`と`terminal.clair-text-engine`がengineです。比較は同じcomponentの
current-default / engine間だけで行い、editorとterminalの数値を互いに比較しません。

## Preconditions

- Apple Siliconのunlocked GUI login session。locked sessionの自動値はUI baselineに採用しません。
- 計測対象のreleaseビルド。Stable既定を書き換えないよう、benchmark専用のbundle identifierを使います。
- windowはcontractに記録する固定sizeへ合わせ、trial間で変更しません。既定は1280×800 pointsです。
- 低電力mode、screen recording、外部負荷、同期処理をtrial間で変更しません。
- 他のClair processを終了します。terminal floodは必ずbenchmark専用のProjectで実行します。
- corpusは`.build/benchmarks/corpus`など、user repositoryの外のignored directoryへ生成します。

## Fixtures

```sh
bash scripts/benchmarks/generate-corpus.sh --output .build/benchmarks/corpus
```

engine baselineで使うのは次の3つです。byte数とSHA-256は`MANIFEST.json`から転記します。

| fixture id | corpus path | 用途 |
|---|---|---|
| `text-10mib` | `large-files/text-10MiB.txt` | 初回表示、初回色付け、scroll、入力応答 |
| `unicode-fixture` | `unicode/unicode-fixture.txt` | CJK・emoji・combining・full-widthの描画経路 |
| `flood-1mib` | `terminal/flood-1MiB.txt` | `run-terminal-flood.sh`で反復するterminal flood |

## Metrics and how to capture them

すべてのsampleはraw値のまま記録します。中央値やp95を手で書かないでください。集計はscriptが行います。

| metric | surface | 取得方法 |
|---|---|---|
| `surface.input_to_glyph` | editor / terminal | 実キー入力のtimestampと、その文字が可視になったframeのtimestampの差。20 sample以上。 |
| `surface.frame_time` | editor / terminal | 固定windowでのrendered frame間隔。20 sample以上。 |
| `surface.scroll_frame_time` | editor / terminal | 同一距離・同一速度のscroll pass中のframe間隔。20 sample以上。 |
| `surface.dropped_frame_ratio` | editor / terminal | 同一長のwindowを5回。drop frame数 ÷ 期待frame数。 |
| `surface.first_paint` | editor / terminal | fixtureのopen（terminalはattach）から最初のtext frameまで。warm-up 1回を捨てて5 trial。 |
| `surface.first_highlight` | editor | 同じopenから、全可視行が色付けされるまで。warm-up 1回を捨てて5 trial。 |
| `surface.idle_rss` | editor / terminal | 表示が落ち着いた後、1 Hzで30秒以上。 |
| `surface.idle_process_count` | editor / terminal | 同じsnapshotのprocess数。WKWebViewのhelper processを含めます。 |
| `surface.flood_cpu` | terminal | `run-terminal-flood.sh --repeats 100`を5 trial。 |

terminal floodの例:

```sh
bash scripts/benchmarks/run-terminal-flood.sh --corpus .build/benchmarks/corpus --repeats 100
```

計測できなかったmetricは値を作らず、`not_measured_reason`へ理由を書きます。contractの
`missing_evidence`は`not-measured`であり、欠測はそのまま記録します。

## Recording a capture

1. raw sampleを1つのJSONへ書きます。形式は
   [`scripts/benchmarks/fixtures/engine-baseline-samples.example.json`](../../scripts/benchmarks/fixtures/engine-baseline-samples.example.json)
   が示します。このexampleは形式の見本であり、`capture.kind`は`example`です。実測では`measured`にします。
2. 集計してresultを作ります。

   ```sh
   ruby scripts/benchmarks/summarize-engine-baseline.rb \
     samples.json docs/benchmarks/results/YYYY-MM-DD-<host-class>/text-engine-baseline.json
   ```

3. 検証します。resultがこのvalidatorを通ることが`P17`の完了条件の一つです。

   ```sh
   ruby scripts/benchmarks/validate-result.rb \
     docs/benchmarks/results/YYYY-MM-DD-<host-class>/text-engine-baseline.json
   ```

validatorは、identity、環境、contract digest、sample数の下限、中央値・p95・maxの再計算、
summaryとcoverageの整合、privacy flag、host-local absolute pathの不在を検査します。
`capture.kind`が`example`のresultは形式の見本であり、baselineとして採用しません。

## Comparison rule at `P34`

- 同一host、同一display、同一window size、同一fixture、同一build modeで取得したcapture同士だけを比較します。
- 比較はcomponentごとに、current-default surfaceとengine surfaceの間で行います。
- engineが全metricで同等以上、かつ大規模fixtureで明確に優位でない限り、既定を切り替えません。
- 実機の日本語IMEとVoiceOverはこのcontractの対象外です。`P19`と`P21`の手動確認結果を
  [local development runbook](../runbooks/clair-v2-verification.md)へ記録し、gateの判断材料に含めます。
