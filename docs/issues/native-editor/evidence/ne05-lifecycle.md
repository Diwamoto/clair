# NE-05 lifecycle / memory evidence

測定日: 2026-09-08（Apple M4、macOS 26.6.2、arm64、Release build、各fixtureは独立プロセスで1回）

## 測定境界

- `open_footprint_bytes` と `before_release_footprint_bytes` は、1 fixtureだけを開いたプロセスの `task_info(TASK_VM_INFO).resident_size`。
- `after_release_footprint_bytes` は `Document.releaseDisplayCache()` 後に0.2秒待って取得した値。peak RSSやinput-to-photonではない。
- 累積値は既存の `benchmark.json` / `poc-measurements.md` の「先行文書を保持した累積max RSS」。単独値と比較して速度・必要メモリ比を主張しない。

## 結果

| fixture | bytes / UTF-16 / 最大行UTF-16 | policy | 単独open footprint | close前 | close後 | 解放API |
|---|---:|---|---:|---:|---:|---|
| `normal.swift` | 110 / 81 / 21 | synchronousNative | 116,539,392 | 116,539,392 | 115,687,424 | true |
| `1mb.swift` | 1,048,554 / 833,466 / 30 | asynchronousNative | 174,555,136 | 175,587,328 | 175,357,952 | true |
| `10mb.swift` | 10,485,735 / 8,334,815 / 30 | webFallback | 333,856,768 | 323,502,080 | 411,549,696 | true |
| `long-line.ts` | 1,048,589 / 1,048,589 / 1,048,589 | webFallback | 191,758,336 | 192,839,680 | 192,528,384 | true |

既存の累積max RSSは `normal.swift` 149.2 MiB、`1mb.swift` 250.3 MiB、`10mb.swift` 1077.7 MiB、`long-line.ts` 1168.4 MiB（`benchmark.json`、同一プロセスで順次保持）である。50追加タブ生成・表示は1,419.08 msだった。

## 実装した保持方針

- clean、Undo/Redo履歴なし、marked textなし、pending proposalなしの文書だけ `controller.view`、TextKit/CodeEdit表示状態、delegate通知を外し、本文・UTF-16 selection・scroll originをsnapshotへ残す。
- dirty本文、Undo/Redo履歴、composition、pending proposalがある文書は表示controllerを解放しない。close後の本文とUndoを無断破棄しない。
- 再オープン時はcontrollerを作り直し、本文・selection・scrollを復元する。selection snapshotがUTF-16範囲外なら `{0, 0}` へ安全にfallbackする。

## 大規模file policy

`LifecyclePolicy.swift` のPoC安全ゲートは次の数値である。

- UTF-8 bytes `<= 10,000,000`、UTF-16長 `<= 10,000,000`、最大行UTF-16長 `<= 1,000,000` がnative対象。
- UTF-16長 `<= 250,000` は同期native。それを超え、安全ゲート内なら非同期native。
- いずれかのnative上限を超えたら `webFallback` とし、byte数・UTF-16長・最大行長のどの境界かを記録する。
- self-testで同期境界、非同期境界、byte上限、最大行上限の各 `N` / `N+1` を検証した。

## 未完了 / blocker

`normal.swift`、`1mb.swift`、`long-line.ts`ではcontroller解放後のfootprintが同等か僅かに減少した。一方、10MB probeでは解放API自体はtrueでも0.2秒後のfootprintが `323,502,080` bytes から `411,549,696` bytes へ増えた。Tree-sitterの非同期parse/query jobがcontroller解放後も継続している可能性があり、parser jobのcancel/idle待機をまだ証明できていない。このためNE-05はopenのままとし、10MBはnativeへ無条件投入しない。次に必要なのは解析jobのgeneration/cancellation契約と、close後にjobが保持していたcontroller/parser/delegateが解放されたことを確認する証跡である。
