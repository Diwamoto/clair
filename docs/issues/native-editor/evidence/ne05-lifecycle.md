# NE-05 lifecycle / memory evidence

測定日: 2026-09-09（Apple M4、macOS 26.6.2、arm64、Release build、各fixtureは独立プロセスで1回）

## 測定境界

- `open_footprint_bytes` と `before_release_footprint_bytes` は、1 fixtureだけを開いたプロセスの `task_info(TASK_VM_INFO).resident_size`。
- `after_release_footprint_bytes` は `Document.releaseDisplayCache()` 後にparser idleを最大5秒待ち、さらに0.1秒待って取得した値。peak RSSやinput-to-photonではない。
- 累積値は既存の `benchmark.json` / `poc-measurements.md` の「先行文書を保持した累積max RSS」。単独値と比較して速度・必要メモリ比を主張しない。

## 2026-09-09 実装後: 表示解放とfallbackの境界

表示 cache の解放と parser の idle を別状態として記録する。固定した upstream revisionには元々 close用job handle／idle通知／join APIがないため、PoC配下の [lifecycle patch](../../../../prototypes/native-editor-poc/upstream-patches/CodeEditSourceEditor-lifecycle.patch) が `TreeSitterExecutor` の queued/running taskをcancelし、queue empty後にだけ `TreeSitterClient.close` を完了させる。close開始時はrevisionを無効化し、旧highlighterのlate callbackは適用しない。

native安全上限（UTF-8 bytes `10,000,000`、UTF-16長 `10,000,000`、最大行UTF-16長 `1,000,000`）のいずれかを超える文書は `webFallback` とし、POCはnative controllerとTree-sitterを生成せず、サイズと理由を表示する。上限内でUTF-16長が `250,000` を超える文書は非同期nativeとし、1MB fixtureでclose後idleを確認した。

### 実装後のprobe

| fixture | policy | display lifecycle | analysis lifecycle | parser idle | fully released | native controller |
|---|---|---|---|---|---|---|
| `normal.swift` | `synchronousNative` | `displayCacheReleased` | `idleVerified` | `true` | `true` | close後に解放 |
| `1mb.swift` | `asynchronousNative` | `displayCacheReleased` | `idleVerified` | `true` | `true` | close後に解放 |
| `10mb.swift` | `webFallback` | `fallback` | `notStarted` | `true` | `true` | 生成しない |
| `long-line.ts` | `webFallback` | `fallback` | `notStarted` | `true` | `true` | 生成しない |

実行コマンドは `python3 prepare-build.py`、`swift build -c release`、`./run.sh --lifecycle-probe -ApplePersistenceIgnoreState YES fixtures/<fixture>`。native 2 fixtureは表示解放とparser drainがともにexit 0で完了し、fallback 2 fixtureはnative資源を生成せずexit 0となる。各値は `task_info(TASK_VM_INFO).resident_size` の単独プロセス測定であり、peak RSSやinput-to-photonではない。

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

## 2026-09-09 実測結果

| fixture | bytes / UTF-16 / 最大行UTF-16 | policy | 単独open footprint | close前 | close後 | 解放API |
|---|---:|---|---:|---:|---:|---|
| `normal.swift` | 110 / 81 / 21 | synchronousNative | 113,754,112 | 113,754,112 | 113,770,496 | true |
| `1mb.swift` | 1,048,554 / 833,466 / 30 | asynchronousNative | 211,517,440 | 212,549,632 | 212,647,936 | true |
| `10mb.swift` | 10,485,735 / 8,334,815 / 30 | webFallback | 117,342,208 | 117,342,208 | 117,342,208 | true |
| `long-line.ts` | 1,048,589 / 1,048,589 / 1,048,589 | webFallback | 102,170,624 | 102,170,624 | 102,170,624 | true |

累積max RSSの既存値は `normal.swift` 149.2 MiB、`1mb.swift` 250.3 MiB、`10mb.swift` 1077.7 MiB、`long-line.ts` 1168.4 MiB（`benchmark.json`、同一プロセスで順次保持）であり、今回の単独probeと混同しない。50追加タブ生成・表示の既存値は1,419.08 msだった。native資源を作らない `fallback/notStarted` も、解放対象が存在しないため `fully_released=true` として扱う。

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

## 制限・引き継ぎ

- lifecycle patchは `Package.resolved` の依存revisionを変更せず、PoCの `.build` checkoutへ `prepare-build.py` が適用するローカル差分である。本番採用時はCodeEditSourceEditor upstreamまたは管理対象forkへ同等の契約を取り込み、upstreamテストを追加する。
- `TreeSitterExecutor` の実行中operationは協調的にcancelされる。close completionはoperationが戻りqueueから除去されるまで遅延するが、強制停止ではない。
- footprintは `resident_size` の単独プロセス値であり、ピークRSSや入力から描画までの遅延ではない。今回のnative probeではnormalが `113,754,112 → 113,770,496` bytes、1MBが `211,517,440 → 212,647,936` bytesで、いずれも `idleVerified` まで完了した。10MBと長大行は安全上限によりnative controller／parserを生成しない。
- dirty本文、Undo/Redo、composition、pending proposalを保持したままのタブ解放は対象外である。これはユーザー状態を無断破棄しないための仕様であり、タブを閉じる最終解放の設計は本番実装時に別途行う。
