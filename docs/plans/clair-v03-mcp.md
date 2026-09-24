# V03: `clair mcp serve` — invariants と threat test

実装: `ClairWorkspace/WorkbenchMCP.swift`(`MCPGate` / `MCPServer`)、GUI 承認: `ClairAppShell.swift`(`requestMCPApproval`)、入口: `clair mcp serve`。

## Invariants

1. adapter は V02 IPC の client。AI の call は `via: "mcp"` を付けて GUI process に届く。authorization は GUI 側の `MCPGate` だけが決める。
2. risk と `aiAvailable` は registry から引く。AI が渡す arguments/自己申告 risk は一切参照しない(未知 argument は registry の validate が拒否)。
3. `aiAvailable: false` は tools/list に出さず、直接 IPC で叩かれても `notAvailableToAI`(prompt も出さない)。
4. effective risk が `write` 以上は GUI の native 確認を通るまで実行しない。拒否・60s 無応答は `denied`。`read`/`additive` は確認なし。
5. 入力検証・precondition は承認 prompt より前に評価する(不正入力で prompt を出さない)。
6. 承認は「カードに出した risk と、その時点の暗黙の対象(active tab / focused pane / Project)」だけを覆う。実行直前に main actor 上で再 preflight し、risk が上がった・対象が動いた場合は `denied`。`confirmed: true` は承認した risk が `destructive` 以上のときだけ渡す。
7. tools/call の arguments は JSON scalar のみ。bool は CFBoolean で判定し(NSNumber の 0/1 を bool にしない)、null/配列/object は `invalid arguments` で拒否する。
8. `via` は client の自己申告。同じ uid の process は `clair <cmd>` や socket 直叩きで MCP 承認を経ずに write を実行できるが、同じ uid の shell は元々 file を直接触れるので権限拡大ではない。destructive は経路に関係なく GUI の確認が要る。
9. 別 user の IPC 接続拒否は V02 のまま(`WorkbenchIPCTests.testOtherUserAndMalformedAndPermissions`)。

## Threat test(`WorkbenchMCPTests`)

| 脅威 | test |
|---|---|
| `aiAvailable:false` を直接呼ぶ | `testAIUnavailableCommandRejectedWithoutPrompt` |
| 承認なし/拒否で write・destructive 実行 | `testWriteAndDestructiveNeedApprovalAndDenialBlocks` |
| 不正入力で prompt を出させる | `testInvalidInputFailsBeforePrompt` |
| 自己申告 risk、tool 一覧の漏れ、`via` の付与 | `testAdapterListsOnlyAIAvailableAndIgnoresClaimedRisk` |
| 承認中の dirty 化・tab 切替で未承認の破棄 | `testApprovalDoesNotCoverEscalationOrRetargeting` |
| 整数 0/1 の bool 化、null で対象を active にすり替え | `testArgumentsKeepJSONTypesAndRejectNonScalars` |

## 未対応

- 承認の「常に許可」は無し(毎回確認)。
- stdio の 1 行に上限は無い(相手は同じ uid の agent 自身)。IPC 側は 1 MiB。
- ponytail: IPC は 1 接続ずつ直列。承認待ち中(最大 60s)は他の CLI 呼び出しも待つ。
