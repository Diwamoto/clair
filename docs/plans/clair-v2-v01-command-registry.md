# V01: typed Command Registry — invariants と test matrix

実装: `packages/ClairV2Core/Sources/ClairV2Workspace/WorkbenchCommands.swift`(UI 非依存)、
projection: `ClairV2AppKit/ClairV2AppShell.swift`(`ClairV2WorkbenchStore`、palette、`ClairV2CommandMenu`)。

## State owner

MVP の state owner は **GUI process**(`ClairV2WorkbenchStore.state`)。daemon は PTY/session/journal を所有し、
pane/tab/Project/settings の workbench state は持たない。V02 の IPC/CLI は起動中 GUI の store へ
`CommandRegistry.execute` を転送し、GUI が居なければ workbench command は実行しない(ADR-0007 の State owner 追記)。

## Invariants

1. すべての workbench 変更は `CommandRegistry.execute` を通る。palette・menu・default shortcut は `commands` の projection で、
   独自の action 実装を持たない(AppShell は `store.run(id, input)` のみ)。
2. command は stable ID、title、固定 risk、`aiAvailable`、typed params(`CommandParam`)を持ち、結果は `CommandResult`、
   失敗は `CommandError{code,message}`(`unknownCommand`/`invalidInput`/`preconditionFailed`/`confirmationRequired`)。すべて `Codable`。
3. input は schema 検証(未知引数・必須欠落・型違い・許可値外)を preflight より先に通す。
4. preflight は固定 risk を **下げない**(`max(fixed, runtime)`)。未保存 buffer を破棄する `pane.close`(最後の editor pane)と
   `tab.close`(dirty tab)は `destructive` へ昇格する。
5. effective risk が `destructive` 以上なら `confirmed: true`(Clair native UI の確認)なしでは実行せず、state を変えない。
6. 失敗した command は state を変更しない。
7. `state.snapshot` は read command で、workbench state 全体を JSON で返す(外部から assert 可能)。
8. `aiAvailable: false` の command(`settings.set`、`palette.*`)は V03 の MCP discovery/execution から除外する。強制は V03。

## Test matrix(`WorkbenchCommandTests`)

| 項目 | test |
|---|---|
| palette と harness で同じ transition/result | `testPaletteAndHarnessProduceSameTransitionAndResult` |
| schema 検証と失敗時 state 不変 | `testSchemaValidation` |
| runtime risk 昇格と確認なし拒否 | `testPreflightEscalatesCloseWithDirtyBufferToDestructive` |
| risk を下げない | `testPreflightNeverLowersFixedRisk` |
| 最後の pane/tab、active なし save の precondition | `testLastPaneAndTabPreconditions` |
| ID/shortcut の一意性、`aiAvailable`、JSON round trip | `testDescriptorsAndJSONRoundTrip` |

## 未対応(後続)

- 利用者による shortcut 再割当: default shortcut のみ。設定 UI が canvas に無いため後回し。
- 最後の editor pane を閉じたときの dirty 判定は global dirty set で近似(buffer と pane の対応は V04/U05)。
- Project 永続化・実 file tree は V04 で完了。実 file 保存は V05、IPC/CLI は V02、MCP と `aiAvailable` 強制は V03。
