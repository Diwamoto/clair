# 2026-09-22 Clair v2 performance budget run

契約: [clair-v2-performance-budget.md](../../clair-v2-performance-budget.md)

環境: Apple M4 / Mac mini、macOS 26.5 SDK、Swift Release build、
commit `e41da9b` + 本 run の harness。raw data は
[`budget.json`](budget.json) と [`startup-warm.json`](startup-warm.json)。

再現:

```bash
make perf-budget
make perf-startup
```

## 結果

- `BUDGET-START-HALFBOUNCE`: **合格**。bundled Release の `exec` → 初フレームが
  median 192.98 ms / p95 195.18 ms (予算 300 ms = ハーフバウンス)。
- `BUDGET-OP-100`: 現在 UI から到達できる 35 操作は合格。表に先行登録された
  未実装の構文ハイライト 2 操作だけが `missing-affordance` のため、suite 全体は不合格。

編集そのものは予算内で余裕がある(10 MiB の打鍵 0.11 ms、1 MiB 単一行 0.11 ms)。
重い disk 走査、10 MiB 読み込み、履歴 diff は background + loading 表示へ移した。
Git の同期操作は敵対的 dirty corpus でも 44 ms 以下に収まった。

## 解消した違反 6 件

| 操作 | 変更前 p95 | 変更後 p95 / 判定 |
|---|---:|---:|
| `tree.scan.20k` | 960.4 ms / 表示なし | 1018.4 ms / background+loading |
| `tree.scan.dirty` | 226.8 ms / 表示なし | 248.3 ms / background+loading |
| `file.rope.10mb` | 482.9 ms / 表示なし | 507.6 ms / background+loading |
| `history.preview.10mb` | 123.4 ms / main thread | 131.8 ms / background+loading |
| `git.refreshStatus.dirty` | 225.9 ms | 24.4 ms / pass |
| `git.review.dirty` | 112.7 ms | 44.0 ms / pass |

## 残る監査項目 2 件

| 操作 | 現在 p95 | 状況 |
|---|---|---|
| `syntax.reset.4mb-json` | 188.5 ms | `SyntaxParser` の呼び出し元が UI に無い (`E11` 未実装)。実装時は background + loading が必要 |
| `syntax.update.4mb-json` | 4.45 ms | 同上。差分 parse 自体は予算内 |

## 予算内だが注意すべき数値

- `palette.files.rank.20k` 20.8〜26.1 ms。`paletteItems` は `paletteView` の
  body 内で呼ばれるため**打鍵ごと**に走る。20,000 ファイルは `WorkbenchFiles.limit`
  そのものなので、これが最悪値。予算の 1/4 を毎打鍵使う。
- `project.switch.cached` 20.7 ms、`tree.directories.20k` 20.4 ms。後者は前者の
  内訳で、`switchProject` が `collapsed` 再計算のために同期実行している。
- `git.changes.dirty` 23.5 ms。source control view の読み側。単発なら問題無いが
  `refreshStatus` と重なると main thread の占有が積み上がる。

## 否定的確認で「壊れなかった」もの

敵対的 corpus でも破れなかった経路。予算判定と同じくらい重要なので記録する。

- 10 MiB / 200,000 行の打鍵: 0.11 ms。文書サイズに比例しない
  (`INV-PERF-001`)。
- 1 MiB 単一行の打鍵: 0.11 ms。長い 1 行が短い行と同じ経路に乗っている
  (`INV-PERF-003`)。
- 1 MiB CJK の打鍵: 0.72 ms。多バイトでも 1 桁以内。
- `workspace.restore`: 0.05 ms。起動経路に走査が入っていない。
- `state.snapshot`: 0.00 ms。CLI/MCP の読み取りは main thread を止めない。
- `file.save.10mb` 3.47 ms と `history.record.10mb` 3.15 ms。保存は速い。
  遅いのは `preview` の diff だけ。
