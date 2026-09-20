# V03: `clair mcp serve` — invariants と threat test

実装: `ClairV2Workspace/WorkbenchMCP.swift`(`MCPGate` / `MCPServer`)、GUI 承認: `ClairV2AppShell.swift`(`requestMCPApproval`)、入口: `clair mcp serve`。

## Invariants

1. adapter は V02 IPC の client。AI の call は `via: "mcp"` を付けて GUI process に届く。authorization は GUI 側の `MCPGate` だけが決める。
2. risk と `aiAvailable` は registry から引く。AI が渡す arguments/自己申告 risk は一切参照しない(未知 argument は registry の validate が拒否)。
3. `aiAvailable: false` は tools/list に出さず、直接 IPC で叩かれても `notAvailableToAI`(prompt も出さない)。
4. effective risk が `write` 以上は GUI の native 確認を通るまで実行しない。拒否・60s 無応答は `denied`。`read`/`additive` は確認なし。
5. 入力検証・precondition は承認 prompt より前に評価する(不正入力で prompt を出さない)。
6. 別 user の IPC 接続拒否は V02 のまま(`WorkbenchIPCTests.testOtherUserAndMalformedAndPermissions`)。

## Threat test(`WorkbenchMCPTests`)

| 脅威 | test |
|---|---|
| `aiAvailable:false` を直接呼ぶ | `testAIUnavailableCommandRejectedWithoutPrompt` |
| 承認なし/拒否で write・destructive 実行 | `testWriteAndDestructiveNeedApprovalAndDenialBlocks` |
| 不正入力で prompt を出させる | `testInvalidInputFailsBeforePrompt` |
| 自己申告 risk、tool 一覧の漏れ、`via` の付与 | `testAdapterListsOnlyAIAvailableAndIgnoresClaimedRisk` |

## 未対応

- 承認の「常に許可」は無し(毎回確認)。
- D5 独立レビューは未実施(本 task の done 条件。人手 gate)。
- ponytail: IPC は 1 接続ずつ直列。承認待ち中(最大 60s)は他の CLI 呼び出しも待つ。
