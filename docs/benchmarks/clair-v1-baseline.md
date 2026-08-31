# ccedit V1 baseline benchmark

## Purpose

ccedit V1 と Clair native rewrite を、同じ host、window size、corpus、操作順、trial policy で比較するための正本手順です。
V1 source は `Diwamoto/ccedit` commit
`80eef4d30f66c4520445872bed73e95c594e2695` に固定します。

大容量 corpus は commit しません。まず [corpus recipe](corpus/README.md) を生成し、raw result は
[`results/`](results/) の schema 1 に保存します。正式なV1 captureとClair captureは、
[PoC queueの`L01`](../plans/clair-poc-queue.md#l01-final-load-and-performance)で利用者と一緒に取得します。

## Preconditions

- Apple Silicon macOS の unlocked GUI login session。locked session の自動値は partial diagnostic とし、UI baseline に採用しない。
- V1 の完全な source commit と、release app bundle の build identity。
- Xcode command-line tools、Rust、V1 の frontend package manager。
- 他の ccedit/Clair process を終了するか、benchmark bundle identifier を固有値にする。
- 低電力 mode、screen recording、外部負荷、同期処理を trial 間で変更しない。

## Pinned V1 checkout and benchmark build

固定 commit の `mise.toml`、`bun.lock`、`src-tauri/Cargo.lock` を使い、既存の ccedit working tree ではなく
一時 clone を build します。private repository を SSH で clone でき、Xcode command-line tools と
`mise` が利用できる clean Apple Silicon host で、Clair repository root から次を同じ shell で実行します。

```sh
CCEDIT_COMMIT=80eef4d30f66c4520445872bed73e95c594e2695
CCEDIT_BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clair-v1-ccedit.XXXXXX")"
CCEDIT_SOURCE="$CCEDIT_BUILD_ROOT/ccedit"
CCEDIT_BUNDLE_ID=dev.daiki.ccedit.benchmark
CCEDIT_TAURI_CONFIG='{"productName":"ccedit Benchmark","identifier":"dev.daiki.ccedit.benchmark","bundle":{"createUpdaterArtifacts":false}}'
CLAIR_SOURCE="$PWD"

git clone --no-checkout git@github.com:Diwamoto/ccedit.git "$CCEDIT_SOURCE"
git -C "$CCEDIT_SOURCE" checkout --detach "$CCEDIT_COMMIT"
test "$(git -C "$CCEDIT_SOURCE" rev-parse HEAD)" = "$CCEDIT_COMMIT"
test -z "$(git -C "$CCEDIT_SOURCE" status --porcelain)"

cd "$CCEDIT_SOURCE"
mise trust mise.toml
mise install
mise exec -- bun install --frozen-lockfile --ignore-scripts
mise exec -- bun --version
mise exec -- rustc --version
mise exec -- cargo --version
mise exec -- bun tauri --version

CCEDIT_TARGET="$(mise exec -- rustc -vV | awk '/^host: / { print $2 }')"
test "$CCEDIT_TARGET" = aarch64-apple-darwin
mise exec -- cargo build --locked --release \
  --manifest-path src-tauri/Cargo.toml \
  --package ptyhost \
  --bin ccedit-ptyhost \
  --target "$CCEDIT_TARGET"
install -d src-tauri/binaries
install -m 0755 \
  "src-tauri/target/$CCEDIT_TARGET/release/ccedit-ptyhost" \
  "src-tauri/binaries/ccedit-ptyhost-$CCEDIT_TARGET"

mise exec -- bun tauri build \
  --bundles app \
  --target "$CCEDIT_TARGET" \
  --no-sign \
  --ci \
  --config "$CCEDIT_TAURI_CONFIG" \
  -- --locked

CCEDIT_APP="$CCEDIT_SOURCE/src-tauri/target/$CCEDIT_TARGET/release/bundle/macos/ccedit Benchmark.app"
test -d "$CCEDIT_APP"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CCEDIT_APP/Contents/Info.plist")" = "$CCEDIT_BUNDLE_ID"
test -z "$(git -C "$CCEDIT_SOURCE" status --porcelain)"
cd "$CLAIR_SOURCE"
```

固定 commit は tool version を `latest` と指定しているため、build 前に次の出力を raw result の build identity とともに
記録します。依存解決は Bun/Cargo の lockfile を frozen/locked mode で行い、inline Tauri config だけで product name と
bundle identifier を override します。通常の `dev.daiki.ccedit` / `dev.daiki.ccedit.dev` bundle や既存 checkout は変更しません。

## Corpus

```sh
bash scripts/benchmarks/generate-corpus.sh --output .build/benchmarks/corpus
```

生成後、`MANIFEST.json` の byte size、SHA-256、generator version、10,000-file profile を result metadata にコピーします。
V1 と Clair は同じ corpus directory を read-only 相当で参照します。V1 collector は通常 bundle ID を拒否し、
事前に存在しない benchmark-only namespace と OS sandbox で通常の HOME 内容を読み書きできない状態にします。

UI 操作は [versioned operation script](workloads/v1-parity-operation-script.json)、metric の name/unit/policy は
[machine-readable metric contract](metric-contract.json) を正本とします。result には両方の SHA-256 を保存します。

## Trial policy

- fresh-profile launch: app process と benchmark-only profile を新しくして 5 trials。最初の warm-up は summary へ含めない。filesystem/cache cold は制御しないため、raw metadata では `fresh-profile` と明記する。
- warm launch: 同じ build/corpus で 1 warm-up の後、5 trials。app の normal quit と relaunch の間で host state を変えない。
- idle resource: first interactive 後 30 秒 idle。RSS/CPU は 1 秒間隔で 30 samples 以上取り、median と max を保存する。
- file/tree/Git operation: 同じ initial state から 5 trials。mutating operation 後は fixture を再生成する。
- terminal flood: 1 MiB payload を100回、合計100 MiB送る同じ command を使い、START/END marker 外を結果から除く。
- UI operation: operation script の action ごとに 1 warm-up + 5 trials。median と max を保存する。
- UI trace: この host で利用できる Time Profiler、Animation Hitches、Power Profiler は同じ marker window を記録し、trace export の raw sample と集計値を result へ転記する。

すべての trial は source/build/environment identity とともに保存します。温度、電源、OS update、表示 scale が変わった結果は別 result directory にします。

## Metrics and gate contract

| Metric | Unit | Collection | Summary | Better direction |
|---|---:|---|---|---|
| `launch.cold_to_first_interactive` | ms | fresh-profile process start to first controlled input accepted | median, max | lower |
| `launch.warm_to_first_interactive` | ms | relaunch to first controlled input accepted | median, max | lower |
| `launch.backend_setup` | ms | V1/Rust setup log phase | median, max | lower |
| `launch.frontend_first_paint_after_load` | ms | V1 frontend perf marker | median, max | lower |
| `idle.rss` | MiB | 1 Hz process sample after idle | median, max | lower |
| `idle.cpu` | % | 1 Hz process sample after idle | median, max | lower |
| `idle.process_count` | count | app process family during idle | median, max | lower |
| `idle.energy_impact` | instrument-defined score | Power Profiler export over idle window | median, max | lower |
| `terminal.flood_cpu` | % | process/app CPU during fixed 100 MiB flood | median, max | lower |
| `terminal.frame_time` | ms/frame | Animation Hitches trace | median, p95 (n >= 20) | lower |
| `terminal.dropped_frame_ratio` | ratio | dropped frames / expected frames | median, max | lower |
| `terminal.input_to_glyph` | ms | timestamped key input to visible glyph | median, p95 (n >= 20) | lower |
| `file.open` | ms | command start to visible document | median, max | lower |
| `file.scroll` | ms/frame | fixed scroll gesture trace | median, p95 (n >= 20) | lower |
| `file.edit` | ms | fixed edit to buffer settled | median, max | lower |
| `file.find` | ms | fixed find command to stable first match | median, max | lower |
| `file.save` | ms | save command to durable write completion | median, max | lower |
| `tree.enumerate` | ms | 10,000-file root to stable visible tree | median, max | lower |
| `tree.find` | ms | fixed file query to stable result | median, max | lower |
| `git.status` | ms | status request to stable result | median, max | lower |
| `pty.reattach` | ms | app restart to existing PTY usable | median, max | lower |

5 measured trials は median と max を報告し、p95 と呼びません。`p95` は20個以上の raw sample がある場合だけ
sorted samples の nearest-rank (`ceil(0.95 * n)`) で算出し、sample count も保存します。
単一 trial や手動 screenshot だけで percentile を作りません。metric が測れない場合は value を 0 や推測値にせず、
`status: not-measured` と capability/tool/reason を raw result に残します。

この project は metric の意味と比較方向を固定します。絶対 threshold、許容 regression、host class 間の補正は、
Clair vertical slice が同じ contract で測れるようになった後に別の accepted decision として決めます。

## Automated V1 capture

固定 app bundle の process/log 部分は次で取得します。

```sh
bash scripts/benchmarks/collect-v1-baseline.sh \
  --app "$CCEDIT_APP" \
  --source-commit 80eef4d30f66c4520445872bed73e95c594e2695 \
  --corpus .build/benchmarks/corpus \
  --operation-script docs/benchmarks/workloads/v1-parity-operation-script.json \
  --metric-contract docs/benchmarks/metric-contract.json \
  --output docs/benchmarks/results/2026-08-31-v1-ccedit-80eef4d/baseline.json
```

この collector が取得するのは environment、app lifecycle log phase、app RSS/CPU/process sample です。
同じ JSON に manual/instrument metric の `not-measured` record を保存できるため、coverage を隠しません。
必要な automated evidence が欠ける場合も sanitized partial JSON を書いて非0で終了します。JSON が存在する場合は
終了コードだけで破棄せず validator と `environment.session.screen_locked`、各 run の reason を確認します。

検証:

```sh
ruby scripts/benchmarks/validate-result.rb \
  docs/benchmarks/results/2026-08-31-v1-ccedit-80eef4d/baseline.json
```

## Manual UI and Instruments capture

自動 collector の後、同じ app/corpus と
[operation script](workloads/v1-parity-operation-script.json) を使って action ID 順に実行します。
locked-session result は診断として保存したままにし、unlocked capture は新しい result directory の
`automated.json` へ出力します。

1. Window を1280 × 800 pointsにし、backing scale、refresh rate、表示 identity を記録する。
2. fresh-profile/warm 起動から最初の controlled input accepted までを marker で測る。
3. 10 MiB/100 MiB の open、find、100-page scroll、固定 byte offset edit、disposable-copy save を行う。
4. 10,000-file tree の enumerate/find/watcher update と Git status stable を測る。
5. IME operation JSON の marked-text update/commit/cancel と UTF-8/UTF-16/grapheme boundary を検証する。
6. 固定100 MiB flood、resize、scrollback、selection、OSC 52/633 を marker window 内で検証する。
7. pane drag/drop を固定 layout で往復し、long-running PTY の normal quit/relaunch/reattach を検証する。
8. Instruments の Time Profiler、Animation Hitches、Power Profiler から raw sample と要約を転記する。

Accessibility、screen recording、Instruments template、PTY reattach が host で利用できない場合は、その capability と理由を result に記録します。

数値は `ui-evidence.json` の observation として保存します。各 observation は canonical action/metric/unit、
UTC timestamp、5 trials（p95 metric は20以上の raw samples）、取得 tool、元 artifact の SHA-256 を持ちます。
`identity.source`、hardware、OS、corpus/operation/metric SHA は `automated.json` と完全一致させ、display は
1280 × 800 points、正の backing scale/refresh rate、privacy-safe な表示 label を記録します。raw export、
trace、screenshot は host-local に保持し、repository には private path、PID、username、terminal transcript を入れません。

```json
{
  "schema_version": 1,
  "base_sha256": "<sha256-of-automated-json>",
  "identity": {
    "source": "<exact automated.json source object>",
    "corpus_manifest_sha256": "<64-hex>",
    "operation_script_sha256": "<64-hex>",
    "metric_contract_sha256": "<64-hex>"
  },
  "environment": {
    "hardware": "<exact automated.json hardware object>",
    "os": "<exact automated.json os object>",
    "session": {"screen_locked": false},
    "display": {
      "status": "measured",
      "identity": "Built-in display",
      "window_points": {"width": 1280, "height": 800},
      "backing_scale": 2.0,
      "refresh_rate_hz": 60.0
    }
  },
  "observations": [
    {
      "id": "launch-fresh-interactive",
      "captured_at_utc": "2026-08-31T04:00:00Z",
      "action_id": "launch.fresh-profile",
      "metric": "launch.cold_to_first_interactive",
      "unit": "ms",
      "samples": [120.0, 118.0, 121.0, 119.0, 117.0],
      "provenance": {
        "kind": "manual",
        "tool": "controlled timestamp marker v1",
        "artifact_sha256": "<64-hex>"
      }
    }
  ]
}
```

`source`、hardware、OS の placeholder は JSON object へ置き換えます。証跡を取り込むときは既存 file を
上書きせず、base byte SHA とすべての比較 identity を検証して新しい `baseline.json` を作ります。

```sh
ruby scripts/benchmarks/ingest-v1-evidence.rb \
  --base docs/benchmarks/results/<unlocked-result>/automated.json \
  --evidence /path/to/sanitized-ui-evidence.json \
  --output docs/benchmarks/results/<unlocked-result>/baseline.json

ruby scripts/benchmarks/validate-result.rb \
  docs/benchmarks/results/<unlocked-result>/baseline.json
```

validator は automated run と evidence の二重 source、identity/display 不一致、unknown action/metric、
wrong unit、sample不足、summary/coverage改変、private host path を fail-closed で拒否します。

## V1 summary

V1 の source/build identity、測定環境、raw trial、coverage、summary は`L01`実行時のdated resultに保存します。
Summary は measured value と not-measured coverage を分け、後続の Clair capture が同じ metric 名を再利用できるようにします。
過去のlocked-session partial captureは正式結果としてcommitしていません。Unlocked UI/Instruments captureが
完了するまで、V1 performance gateの正本値は存在しないものとして扱います。

## Interpretation rules

- V1 と Clair の結果は operation script SHA-256、metric contract SHA-256、corpus manifest SHA-256、build mode、window points、display scale、refresh rate が一致する場合だけ直接比較する。
- いずれかの identity が欠ける結果は `not-comparable` とし、別 baseline とする。
- feature parity の `later` と `out-of-scope` は M1 performance gate の failure にしない。
- 数値差の原因が不明な場合は「改善」と断定せず、trace/operation coverage を追加する follow-up を作る。
