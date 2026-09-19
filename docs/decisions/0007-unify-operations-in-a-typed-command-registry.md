---
id: ADR-0007
title: "すべての操作をtyped Command Registryへ統合する"
status: accepted
date: 2026-08-30
deciders:
  - Daiki Iwamoto
related_projects: []
related_issues: []
supersedes: []
superseded_by: []
---

# ADR-0007: すべての操作をtyped Command Registryへ統合する

## Context

Clairは同じ操作をnative UI、command palette、keyboard shortcut、terminal上の`clair` CLI、coding agentから利用したい。Surfaceごとに別のaction implementationを持つと、挙動、validation、permission、error handlingがずれ、AIがGUI automationやshell scriptで内部状態を推測することになる。

AIにはProjectやpaneを操作させたいが、branch delete、merge、terminal terminate等の危険性をAI自身のrisk classificationへ委ねることは安全境界にならない。Claude Code、Codex、OpenCodeで共通利用できるmachine interfaceも必要である。

## Decision drivers

- 人間とAIが同じoperation semanticsを使うこと。
- UI構造を変更してもCLI/AI integrationが壊れないこと。
- Commandのargumentと現在状態からriskを再現可能に判定すること。
- 起動中GUIをMVPのstate ownerとし、後にbackground serviceへ拡張できること。
- Agent vendorごとのintegrationを最小化すること。

## Options considered

### Option A: Surfaceごとにactionを実装する

- Advantages: 各UIを局所的に実装しやすい。
- Disadvantages: validation、undo、permission、error semanticsが分岐する。

### Option B: GUI automationを共通interfaceにする

- Advantages: 既存UIをそのまま利用できる。
- Disadvantages: focus、label、layout変更へ依存し、headless/AI利用に適さない。

### Option C: Typed Command Registryを唯一のoperation定義にする

- Advantages: 全surfaceが同じschema、validation、risk、resultを利用できる。
- Disadvantages: UI-only actionを含め、すべてを明示的なcommand contractとして設計する必要がある。

## Decision

Option Cを採用する。

各commandは最低限、次を持つ。

- stable command ID
- human-readable title/description
- typed input schema
- typed resultまたはstructured error
- fixed risk class (`read`, `additive`, `write`, `destructive`, `external`)
- current target/stateを検査するdeterministic preflight
- `aiAvailable` flag

Command palette、menu、keyboard shortcutはCommand RegistryのUI projectionとする。Shortcutは一部commandだけに既定割当を持ち、利用者が任意commandへ割り当てられる。

`clair` CLIはuser-scoped local IPCで起動中Clairへ接続する。MVPではGUI processをstate ownerとし、GUIが起動していない場合はGUI stateを必要とするcommandを実行しない。Background service導入後は同じregistryとtransport-neutral contractを使ってheadless operationを追加できる。

AI向けには`clair mcp serve`をstdio MCP serverとして起動し、同じlocal IPCへ接続する。AIへは`aiAvailable`なcommandだけを公開する。MCP host側のtool permissionは追加防御として利用できるが、Clair自身のrisk判定と承認を省略しない。

Preflightは固定riskを下げず、対象状態に応じてriskまたはconfirmation requirementを引き上げられる。たとえば通常のpane closeが未保存bufferを破棄する場合、destructive confirmationを要求する。AIによるrisk reviewをauthorization decisionには使わない。

## Rationale

Command Registryを唯一の操作契約にすると、`clair open path:line:column`、command palette、AIによるpane作成が同じProject resolutionとerror handlingを共有できる。AIは画面を推測せず、利用可能なoperationとschemaを発見できる。

Risk metadataをcommand authorが定義し、runtime targetをClairが検査することで、使用agentやmodelの判断品質に依存しないpermission boundaryを作れる。

## Consequences

### Positive

- UI、CLI、MCPでoperation semanticsが一致する。
- Command単位のtest、logging、approval、undo/recoveryを構築できる。
- Agent vendorをMCP adapterの外側へ分離できる。
- 将来のbackground serviceやmobile approvalへ同じpending operationを渡せる。

### Negative

- Focus移動等の細かいUI actionもcommandとして整理する実装負担がある。
- Command ID/schema変更にcompatibility policyが必要になる。
- Registryが巨大化した場合、palette検索とMCP projectionの整理が必要になる。

## Validation

- 同じcommandをpalette、CLI、MCPから実行し、result/errorとstate transitionが一致する。
- Read-only commandは確認なし、destructive commandはClair native UIの確認後だけ実行される。
- Runtime stateによりriskが上がるcommandをfixtureで検証する。
- `aiAvailable: false`のcommandがMCP tool discoveryとexecutionの双方から利用できない。
- 不正なlocal processが別userのClair IPCへ接続できない。

## Revisit conditions

- MCPが対象agentの共通interfaceでなくなる。
- Command schema/versioningの保守費がsurface別implementationを上回る。
- Background serviceがGUI state ownerと分離できず、registryのownership変更が必要になる。

## References

- [Product principles](../product/principles.md)
- [Product scope](../product/scope.md)

## State owner(2026-09-19 追記、V01)

v2 の workbench state(pane tree、tab、Project 選択、settings、palette)は起動中 GUI process の `ClairV2WorkbenchStore` が所有する。
`ClairDaemon` は PTY/session/journal の owner のまま、workbench state は持たない。`clair` CLI(V02)と MCP(V03)は
local IPC 経由で GUI の `CommandRegistry.workbench.execute` を呼ぶ。GUI が起動していなければ workbench command は失敗させる。
Registry 本体は UI 非依存(`ClairV2Workspace`)なので、background service へ移すときは store の置き場所だけを変える。
詳細は [V01 invariants](../plans/clair-v2-v01-command-registry.md)。
