# Implementation plan

実装単位は[PoC queue](../../clair-tasks.md)の`P17`〜`P34`である。本文書は全体の順序と
受け入れ条件の対応を示し、各itemの詳細はqueue側を正本とする。agentは
[`clair-issue-executor`](../../../.agents/skills/clair-issue-executor/SKILL.md)で1itemずつ実行する。

## Acceptance mapping

| Acceptance criterion | Implementation slices | Validation |
|---|---|---|
| `AC-01` | P17、P18、P22、P30 | surface上でeditorとterminalが動作するDev harnessと実アプリ |
| `AC-02` | P19、P31 | 実機の日本語IMEによる手動確認 |
| `AC-03` | P18、P22、P23 | 10MB/長行fixtureの初回表示、scroll、編集応答 |
| `AC-04` | P30、P31、P32 | Claude Code / Codex / OpenCodeのTUIとflood |
| `AC-05` | P25、P26、P27、P28 | anchorのwrap/folding追従、diff操作、提案の部分適用 |
| `AC-06` | P34 | 現行既定との同条件比較 |
| `AC-07` | P29 | 既定切替と切り戻しの手動確認 |

## Dependencies

- [ADR-0014](../../decisions/0014-clair-owned-text-engine.md)がaccepted であること。
- `P04`、`P06`、`P15A`、`P15B`、`P15C`が`done`であること。すべて充足済み。
- Tree-sitterのSwift bindingと必要言語grammarの配布許諾（`P23`のscope内で確認する）。

## 実行の波

依存が解けた順に並列実行できる。同時に走らせるagentは必ず別のlinked worktreeを使う。

| 波 | 並列実行できるitem | 備考 |
|---|---|---|
| 1 | `P17`、`P22`、`P33` | 依存がすべて`done`。すぐ着手できる |
| 2 | `P18`、`P19` | `P17`完了後。`P19`はprojectのriskが集中する最重要item |
| 3 | `P20`、`P23`、`P30` | それぞれeditor/terminal/共有層で独立 |
| 4 | `P21`、`P24`、`P25`、`P31` | |
| 5 | `P26`、`P28`、`P32` | |
| 6 | `P27` | |
| 7 | `P29` | editor既定切替 |
| 8 | `P34` | 最終gate |

## Slice 1: 共有surfaceの基礎（P17、P18、P19、P20、P21）

### Changes

`ClairTextKit`のFont、Render、Geometry、Input層。`TextSurfaceSource` protocolの確定。

### Validation

Dev harnessでのfixture描画、可視範囲限定layoutの確認、実機IME、VoiceOver。

### Completion

- [ ] code
- [ ] tests
- [ ] relevant docs

## Slice 2: editor model（P22、P23、P24、P25、P26）

### Changes

`TextBuffer`、`SyntaxHighlighter`、編集primitive、gutter/rail、wrapとfolding。

### Validation

既存の文書契約testの継続通過、anchorの追従、Undo grouping、大規模fixture。

### Completion

- [ ] code
- [ ] tests
- [ ] relevant docs

## Slice 3: terminal surface（P30、P31、P32）

### Changes

`TerminalGridSource`、terminalの入力と選択とscrollback、既定切替。

### Validation

agent TUI、flood、resize、reattach、OSC 52、IME。

### Completion

- [ ] code
- [ ] tests
- [ ] relevant docs

## Slice 4: 製品接続と切替（P27、P28、P29、P33）

### Changes

diffとmergeの描画、AI提案とコメントのsurface、workspace stateの分離、editor既定切替。

### Validation

diff操作、提案の部分適用とstale拒否、切り戻し、既存XCTest suite。

### Completion

- [ ] code
- [ ] tests
- [ ] relevant docs

## Slice 5: gate（P34）

### Changes

計測と判定のみ。engineの不合格項目があれば個別itemへ差し戻す。

### Validation

`P17`で取得した現行既定の基準値との同条件比較。

### Completion

- [ ] code
- [ ] tests
- [ ] relevant docs

## Final verification

- [ ] 全acceptance criteriaにvalidation evidenceがある
- [ ] relevant test、build、format、static checkが通る
- [ ] regressionまたは既知制約が記録されている
- [ ] architectureとrunbookが実装を表している
- [ ] unrelated diffがない

## Deferred follow-ups

- glyph atlasのMetal化。`P34`でCoreTextが不足と判定された場合のみ起票する。
- `TextBuffer`のRust移行。ADR-0010の基準を満たす実測が出た場合のみ検討する。
- CodeMirror経路とWKWebView資産の完全撤去。engine既定が定着した後の整理itemとする。
