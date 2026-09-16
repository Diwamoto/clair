# E02: Swift text storage / coordinates / immutable revision

Status: worker implementation complete; independent D5 review / integration pending
Contract recorded before code changes: 2026-09-16
Base: `04f86f85a5277eec3bb29ff1bee0a05ca1c168f0`

親計画と [editor invariants](../editor/clair-v2-editor-invariants.md) を正本とする。
ADR-0014 の Swift 所有という判断を踏襲し、旧 fallback / terminal に関する記述より
現行 v2 計画を優先する。E03 の transaction / selection / undo、E05 の parser / LSP、
view / IME / terminal はこの task に含めない。

## Invariants と実装方針

- `INV-COORD-001/002`: UTF-8 byte length で索引する persistent AVL rope。
  UTF-8 / UTF-16 / scalar / grapheme / line index は別の型とする。各 node の集約値は
  UTF-8 内容から導出するキャッシュであり、独立した可変テキストではない。
- `INV-COORD-003/004/005`: Swift `Character` を境界の oracle とする。
  通常の変換・編集は grapheme 内部を拒否し、明示的な round down / up だけを許す。
  CRLF は分割しない。LF / CR / NEL / LS / PS も改行として扱う。
- `INV-COORD-007/008`: 正規化しない。raw bytes の読み込みは strict UTF-8 validation
  に失敗すると全体を拒否し、replacement character への暗黙変換をしない。
- `INV-REV-001/003/005`: single-owner の非 Sendable buffer と Sendable な immutable
  snapshot を分離する。snapshot は root を共有し、編集は経路だけを path-copy する。
  document UUID と単調増加 sequence を revision とし、別 document / stale revision
  の編集を拒否する。byte-identical replacement は revision を進めない。
  属性を storage に持たせない。全文の String 化は明示的な export API に限定する。
- 行 ID は BOF sentinel と各改行に紐づく「次の行」の ID とする。行内編集、上への挿入、
  suffix の移動でも、存続する改行の ID は保持する。split で新しい改行に新 ID を振り、
  join で消えた改行の ID は再利用しない。CR と LF が編集で一つに結合する場合は、
  残存する改行のうち左側の ID を保持する。BOF の ID は全置換でも保持する。
  これは位置の identity であり、内容の同一性や review anchor の再配置を保証しない。
- `INV-PERF-001`: bounded leaf と AVL aggregate により通常編集・変換・行 lookup は
  document / line 全走査をしない。Unicode seam は両端の leaf だけを再分割し、
  regional indicator 等で後続の境界が変化する場合だけその先へ伝播する。
  Unicode は一つの grapheme の長さ・連鎖に上限がないため、その実際に影響する範囲は
  固定 byte budget に切り捨てない。長い ASCII 行は bounded leaf のまま扱う。

## Failure modes / test matrix

| Failure mode | Acceptance / oracle |
|---|---|
| byte / code-unit / scalar 混同 | E01 corpus の全 grapheme boundary を Swift prefix counts と全座標で往復照合 |
| surrogate / continuation / combining / ZWJ / CRLF の分割 | 全内部 offset の strict rejection と上下丸め、negative / past-end / reversed range |
| チャンク接続で segmentation が変わる | combining / ZWJ / CRLF / RI parity / Indic / prepend の seam 編集を Swift String と照合 |
| 混在改行 / EOF / 空文書の行数ずれ | 全6種類の改行、trailing newline、empty、content/terminator ranges、line-column round trips |
| 行 ID の再採番 / 重複 / join 誤り | 行内・split・join・prefix/suffix 編集・CRLF fusion と保持した snapshot の ID を照合 |
| snapshot の書き換え / revision 再利用 | snapshot 保持、別 task で読み出し、no-op / failed / stale / foreign 編集の非破壊性 |
| invalid UTF-8 のデータ損失 | overlong / truncated / surrogate / stray continuation bytes を load 時に拒否 |
| データ構造の編集依存の破損 | fixed seeds の randomized edits を byte-exact String oracle / rebuild snapshot と differential 比較 |
| 全文コピー / 長行走査 / 木の退化 | E01 10MB / long-line / Japanese fixtures、構造共有と AVL 検証、局所再分割量、E01 latency ceiling |

## 検証と handoff

Task-focused SwiftPM tests、変更した Swift の format/lint、`git diff --check` を行う。
full Swift suite / app / Simulator / signing は controller に残す。
queue status/evidence は編集しない。独立した D5 review と integration は controller が担当する。

## 実装結果

`ClairV2EditorCore` は UI / v1 runtime へ依存しない SwiftPM library target とした。
`TextBuffer` が一つの writer を所有し、`TextSnapshot` / immutable AVL node を reader に渡す。
2,048 bytes を目安に Swift `Character` 境界で分割し、集約値から座標と改行を索引する。
`TextBuffer.replace(_:with:basedOn:)` は E03 が使用する単一 storage replacement であり、
multi-edit transaction、position map、SelectionSet、undo stack は追加していない。

主要 API:

```swift
let buffer = try TextBuffer(utf8: Array("日本語\r\n👩🏽‍💻".utf8))
let before = buffer.snapshot
let start = try before.convert(GraphemeOffset(0), to: UTF8Unit.self)
let end = try before.convert(GraphemeOffset(1), to: UTF8Unit.self)
let after = try buffer.replace(TextUTF8Range(start, end), with: "新", basedOn: before.revision)
let position = try after.position(at: start, columnUnit: UTF16Unit.self)
let line = try after.line(at: position.line)
// before は別 actor に渡しても変化しない。全文が必要な境界でのみ string() を呼ぶ。
```

line-column は zero-based、column は改行を含まない content の長さまで。
改行の開始位置は直前の行の末尾、改行の終端は次の行の先頭として扱う。
空文書は空の一行を持ち、末尾改行には空の最終行が続く。
CRLF fusion は、この編集より前から存在した改行の ID を新規改行の ID より優先し、
既存改行が二つ結合したときは左側の ID を残す。

UTF-8 の検証では BOM も保存する。追加 test で Foundation の
`String(bytes:encoding:)` が先頭 BOM を除去することを検出したため、stdlib decoder の
結果を入力 byte 列と完全一致検証してから採用する。invalid sequence の補修結果は拒否する。
新しい `String(validating:as:)` による minimum OS 引き上げはせず、macOS 14 / iOS 17 を維持した。

## Acceptance evidence (2026-09-16)

| 対象 | 証拠 |
|---|---|
| 全座標、境界拒否・丸め、混在改行、BOM / invalid UTF-8 | `EditorTextCoordinateTests` 5 tests |
| immutable revision、stale / foreign / no-op、stable line ID、並行 snapshot read | `EditorTextStorageTests` 5 tests |
| CRLF / combining / ZWJ / Indic / prepend / RI の seam、巨大 grapheme、AVL / sharing | `EditorTextSeamTests` 3 tests |
| deterministic differential edits | `EditorTextRandomizedTests` 2 tests。6 seeds × 400 edits と 300 multi-leaf edits、Swift String / scalar line scanner / fresh rebuild と照合 |
| 長期の局所更新 | 600 insertions で毎回 AVL aggregate / balance を検証 |
| 大きいファイル | `EditorTextPerformanceTests` 1 test、E01 の 3 fixtures、20 edits / fixture、局所再分割 < 20,480 bytes / edit |
| E01 契約の維持 | 既存 E01 の 18 tests を再実行。`EditorInvariants.provenBy` に具体的 test evidence のコメントを併記 |

最終 Debug focused suite は **34 tests / 0 failures**。新 core だけの build も成功。
Swift 6.3.3 / arm64 / macOS 26.6.2。full Swift suite、app、Simulator、署名操作は未実行。

Release の `EditorTextPerformanceTests` も **1 test / 0 failures**。

| E01 fixture | median | p95 | 累積 max RSS |
|---|---:|---:|---:|
| 10mb | 0.111750 ms | 0.146000 ms | 76,840,960 bytes |
| long-line | 0.100000 ms | 0.151709 ms | 87,539,712 bytes |
| 1mb-japanese | 0.351583 ms | 0.412959 ms | 87,539,712 bytes |

long-line p95 と Japanese median は E01 の該当 `regressionCeiling` に対して assert した。
RSS は test runner 全体の累積値で、各 buffer の専用メモリ量ではない。

再現コマンド（この環境では build/cache を作業ごとの `/private/tmp/clair-e02-7e33-*`
へ置き、`--disable-sandbox` を併用。共有 SwiftPM cache は使用していない）:

```sh
swift build --package-path packages/ClairV2Core --target ClairV2EditorCore
swift test --package-path packages/ClairV2Core \
  --filter 'EditorText|UnicodeCorpusTests|EditorFixtureGeneratorTests|EditorBenchmarkTests|EditorInvariantsTests|EditorBaselineEvidenceTests'
swift test -c release --package-path packages/ClairV2Core --filter EditorTextPerformanceTests
swift format lint --strict --recursive packages/ClairV2Core/Sources/ClairV2EditorCore \
  packages/ClairV2Core/Tests/ClairV2CoreTests/EditorText*.swift
swift format lint --strict packages/ClairV2Core/Sources/ClairV2EditorFixtures/EditorInvariants.swift
git diff --check
git diff --cached --check
```

新規 core / tests と `EditorInvariants.swift` の strict lint は pass。
`Package.swift` の既存 line 22 は strict formatter の改行警告を base commit でも再現した。
T08 の Ghostty 部分に当たるため維持し、manifest は新 target の additive 3 行のみ変更した。

この計測は storage replacement + snapshot のみ。E01 の CodeEdit / CodeMirror 数値は
Apple M4 / 32 GiB / macOS 26.6.2 / Swift 6.3.3 Release、約 1164×710 viewport、
13 pt monospaced、wrap off、20 回、nearest-rank p95、RSS は累積 process maximum という
条件の failure evidence であり、本 storage-only 計測を UI 同士の速度比とは解釈しない。
E06 / E10 の layout、実キー入力、実機 IME の性能 gate は未完了。

Unicode segmentation は実行時の Swift `Character` に従う。無制限に長い一 grapheme や
RI parity の影響範囲は実際の範囲だけ再分割するため、任意の Unicode 入力について
固定時間とは主張しない。通常の長い ASCII 行は文書サイズから独立した leaf 単位で更新する。
