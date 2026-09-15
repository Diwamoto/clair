# Clair v2 ローカル動作確認手順

Status: active verification guide
Parent: [Clair v2 native rewrite plan](../plans/clair-v2-native-rewrite.md), [task queue](../plans/clair-v2-native-rewrite-queue.md)

この runbook は Clair v2 のエディタ・ターミナル実装をローカルで確認するための手順である。v1（`apple/`、`packages/ClairMobileKit`）の確認には [`local-development.md`](local-development.md) を使う。v2 は独立した Swift package 群で動作する。

## 前提

- macOS 14.0 以降
- Xcode 26 / Swift 6 以降（`make doctor` で確認）
- リポジトリ pinned Rust toolchain（v2 foundation のみ Swift だが、混在ビルド時に必要）

```sh
make doctor
```

## 全体のコンパイルとテスト

v2 の package graph、全 target、iOS Simulator クロスビルド、package tests を一括確認する。

```sh
make v2-foundation
```

内部では次を順に実行する。

```sh
make v2-check   # package manifest / v1 依存境界検証
make v2-build   # core + apps target ビルド
make v2-test    # Core / Apps package tests
```

失敗時は `.build` の出力と `swift build` / `swift test` のエラーを確認する。`make clean-artifacts` は破棄可能なビルド成果物だけを削除する。

## エディタ実装の確認

### E01: invariants / baseline / fixtures

`packages/ClairV2Core/Sources/ClairV2EditorFixtures` に invariant と baseline evidence が置かれる。コンパイルとテストを確認する。

```sh
swift build --package-path packages/ClairV2Core --target ClairV2EditorFixtures
swift test --package-path packages/ClairV2Core --filter EditorFixtures
```

確認観点:

- `EditorInvariants.all` に invariant ID が重複・欠落していないこと
- 各 invariant の `provenBy` が実装予定の task ID と一致すること
- `EditorBaselineEvidence.failures` が ADR-0014 / PoC 証拠から転記されていること
- fixture 生成スクリプトが 10MB / 1MB-long-line / Unicode corpus を再現可能であること

### E02-E05: text storage, transaction, search, Tree-sitter

Core 実装の確認は package test で行う。

```sh
swift test --package-path packages/ClairV2Core --filter ClairV2Editor
```

手動で harness を動かす場合:

```sh
swift run --package-path packages/ClairV2Core EditorBenchmark \
  --fixture packages/ClairV2Core/Tests/Fixtures/10mb.swift \
  --operation keystroke \
  --iterations 20
```

確認観点:

- 10MB ファイル初回表示、スクロール、キー入力の latency / RSS
- 1MB 単一行のキー入力、スクロール
- 日本語 IME、絵文字・結合文字・CRLF の caret 動作
- multi-cursor 編集・Undo/Redo
- external/agent edit の revision 整合性

### E06-E08: native surface (macOS / iOS)

macOS surface は `ClairV2MacApp` 経由で確認する。

```sh
swift run --package-path packages/ClairV2Apps ClairV2MacApp
```

iOS surface は Simulator 経由。

```sh
xcodebuild \
  -project ClairV2Mobile.xcodeproj \
  -scheme ClairV2Mobile \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -derivedDataPath .build/xcode/v2-mobile-simulator \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test \
  -parallel-testing-enabled NO
```

確認観点:

- 全行 eager layout / 一行一 View が存在しないこと（Instruments / View Debugger）
- IME marked text、確定、変換候補ウィンドウの追従
- selection、caret、copy/paste の挙動
- VoiceOver / Dynamic Type

### E09-E10: review anchor / integration gate

```sh
swift test --package-path packages/ClairV2Core --filter ClairV2Review
swift test --package-path packages/ClairV2Core --filter ClairV2EditorIntegration
```

確認観点:

- 編集後の review anchor が stale / orphaned / resolved に正しく遷移すること
- AI suggestion の apply / reject / partial / undo が transaction として動作すること
- 10MB / long-line / IME で performance threshold を満たすこと

## ターミナル実装の確認

### T01: libghostty 基盤

GhosttyKit.xcframework の vendor と ABI 整合性を確認する。

```sh
scripts/v2-ghostty.sh status    # 現在の vendor 状態
scripts/v2-ghostty.sh verify    # pin manifest / license / ABI 検証
scripts/v2-ghostty.sh vendor    # 初回 or pin 更新時の fetch/build
```

package ビルド:

```sh
swift build --package-path packages/ClairV2Core --target ClairV2Ghostty
swift build --package-path packages/ClairV2Core --target ClairV2GhosttyABI
```

確認観点:

- `Config/ghostty-pin.json` に commit SHA / toolchain / digest が記録されていること
- vendor 産物が gitignored ディレクトリにあり、repository にコミットされていないこと
- `ghostty_init` / `ghostty_info` の round-trip が artifact ありで通ること
- artifact なしの環境では `runtimeUnavailable` が fail-closed で返ること

### T02: daemon-owned PTY/session backend

`ClairDaemon` が PTY / process / session を所有する。すでに queue 上は `done` だが、回帰確認に使える。

```sh
swift run --package-path packages/ClairV2Apps ClairDaemon \
  --directory ~/.clair-daemon \
  --project-root /path/to/project \
  --opencode-executable /path/to/opencode
```

確認観点:

- GUI を閉じても daemon が生存し、二重起動しないこと
- OpenCode process が project root で起動し、SessionID が安定すること
- `SIGINT` / `SIGTERM` で安全に停止すること

### T03-T07: surface / integration

macOS surface:

```sh
swift run --package-path packages/ClairV2Apps ClairV2MacApp
```

iOS surface:

```sh
xcodebuild \
  -project ClairV2Mobile.xcodeproj \
  -scheme ClairV2Mobile \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -derivedDataPath .build/xcode/v2-mobile-simulator \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test \
  -parallel-testing-enabled NO
```

確認観点:

- local shell / OpenCode TUI が正しく描画されること
- selection、copy/paste、scrollback
- resize、alternate screen、マウスレポート
- Mac と mobile から同じ session に attach し、入力順序が保持されること
- network switch / sleep-wake / background-foreground で再接続すること
- flood 入力で破損・遅延がないこと

## 日々の開発ループ

小さな変更後は package 単位のテストを優先する。

```sh
# editor core だけ
swift test --package-path packages/ClairV2Core --filter EditorInvariantsTests

# terminal core だけ
swift test --package-path packages/ClairV2Core --filter ClairV2GhosttyTests

# daemon だけ
swift test --package-path packages/ClairV2Core --filter ClairV2DaemonKitTests
```

広い確認は変更が波及しそうなときだけ実行する。

```sh
make v2-foundation
```

`make run-dev` は v1 Clair Dev アプリ用である。v2 には使わない。

## 実機・通知・署名

実機 build、署名、APNs、TestFlight については [`native-mobile-v2.md`](native-mobile-v2.md) を参照する。これらは Apple Developer account 等の外部 credential が必要なため、自動化された daily 確認からは外す。

## 記録

各 task の完了時は queue の execution evidence に次を記録する。

- task ID
- 統合 commit SHA
- 実行した確認コマンドと結果
- 残課題・外部依存
