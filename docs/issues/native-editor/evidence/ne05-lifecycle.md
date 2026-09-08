# NE-05 lifecycle / memory evidence

測定日: 2026-09-08（Apple M4、macOS 26.6.2、arm64、Release build、各fixtureは独立プロセスで1回）

## 測定境界

- `open_footprint_bytes` と `before_release_footprint_bytes` は、1 fixtureだけを開いたプロセスの `task_info(TASK_VM_INFO).resident_size`。
- `after_release_footprint_bytes` は `Document.releaseDisplayCache()` 後に0.2秒待って取得した値。peak RSSやinput-to-photonではない。
- 累積値は既存の `benchmark.json` / `poc-measurements.md` の「先行文書を保持した累積max RSS」。単独値と比較して速度・必要メモリ比を主張しない。

## 2026-09-09 実装後: 表示解放とfallbackの境界

今回の実装では、表示 cache の解放と parser の idle を別状態として記録する。固定したCodeEditSourceEditorにclose用job handle、idle通知、join APIがないため、close時はrevisionを無効化してlate callbackを拒否するが、parser停止完了を推定しない。

native安全上限（UTF-8 bytes `10,000,000`、UTF-16長 `10,000,000`、最大行UTF-16長 `1,000,000`）のいずれかを超える文書は `webFallback` とし、POCはnative controllerとTree-sitterを生成せず、サイズと理由を表示する。これにより10MB fixtureのような文書を解析jobへ無条件投入しない。上限内でUTF-16長が `250,000` を超える文書は引き続き非同期nativeであり、close後idleは未検証である。

### 実装後のprobe

| fixture | policy | display lifecycle | analysis lifecycle | parser idle | fully released | native controller |
|---|---|---|---|---|---|---|
| `normal.swift` | `synchronousNative` | `displayCacheReleased` | `closeRequestedIdleUnknown` | `null` | `false` | close後に解放要求 |
| `10mb.swift` | `webFallback` | `fallback` | `notStarted` | `true` | `false` | 生成しない |
| `long-line.ts` | `webFallback` | `fallback` | `notStarted` | `true` | `false` | 生成しない |

実行コマンドは `./run.sh --lifecycle-probe -ApplePersistenceIgnoreState YES fixtures/<fixture>`。normalの表示解放は `true` だがparser idleはunknown、10MBはfallbackでexit 0となる。各値は `task_info(TASK_VM_INFO).resident_size` の単独プロセス測定であり、peak RSSやinput-to-photonではない。

## 2026-09-08 再調査: close後jobのcancel/idle契約

### API確認

`Package.resolved` の `CodeEditSourceEditor` 固定revisionは `1fa4d3c3ffba007482111466cb9721416f97ae00` である。このrevisionの実装では次の境界になっている。

|確認対象|既存APIの挙動|NE-05への意味|
|---|---|---|
|`TreeSitterClient.setUp`|内部で全jobをcancelするが、直後に新しい`.reset` setup jobを投入|close cancelとして使うと新しいparseを開始する|
|`TreeSitterClient.applyEdit`|edit開始時に低優先度jobをcancelし、cancel callbackを返す|close後のparser/query全体を止めるAPIではない|
|`TreeSitterClient.queryHighlightsFor`|結果callbackのみ。jobのhandleは返さない|個別queryをclose時にcancelできない|
|`TreeSitterExecutor.cancelAll`|`package` scope。即時停止を保証しない|PoC consumerから呼べず、呼べてもidle確認にはならない|
|`TreeSitterExecutor`|queue empty待機、running taskのjoin、idle通知がない|controller/parser/delegateの解放を証明できない|
|PoC `RevisionAwareHighlightProvider`|edit/query completionでgeneration不一致を拒否|stale結果防止のみ。実行停止・in-flight追跡ではない|
|PoC `Document.releaseDisplayCache`|controller/view/observerを外すがprovider/clientは`Document`所有|close後もexecutor jobの寿命が残る|

したがって、既存APIだけで「close → parser/query jobが停止 → idleを確認 → controller/parser/delegateが解放」を安全に実装することはできない。`setUp` の副作用やproviderのdeinitに依存する実装は、新しい解析jobの投入またはjoinされない非同期処理を残すため採用しない。generation gateは必要だが、それだけではメモリ保持の完了条件を満たさない。

### 再現手順

1. `fixtures/10mb.swift` を生成し、PoCをReleaseでbuild/packageする。
2. `NativeEditorPoC --lifecycle-probe -ApplePersistenceIgnoreState YES fixtures/10mb.swift` を実行する。
3. probeはopen footprint、close前 footprint、`Document.releaseDisplayCache()` の戻り値、0.2秒後の footprintを記録する。
4. 既存証跡では、解放APIは `true` だが、close前 `323,502,080` bytes に対してclose後 `411,549,696` bytesとなった。controller解放だけではTree-sitterの非同期parse/query jobが停止・idleしたとは判定できない。
5. 固定checkoutの `TreeSitterClient.swift` と `TreeSitterExecutor.swift` を確認すると、公開されたclose cancel handleまたはidle/join APIが存在しない。`cancelAll` はpackage scopeで、キャンセルも即時停止を保証しない。

この再現は既存の10MB lifecycle probe結果に基づく。今回の再調査では同一Macの競合を避けるため、Xcode host testとGUI benchmarkを追加実行していない。必要な解決は、upstreamまたはfork側で job単位のcancel、generation付きcompletion、cancel完了後のidle/joinを公開し、その契約をPoCで検証することである。

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
