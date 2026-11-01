---
id: ADR-0026
title: "clair CLIの出力契約を統一し、実装はSwiftのまま維持する"
status: accepted
date: 2026-11-01
deciders:
  - Daiki
related_projects: []
related_issues: []
supersedes: []
superseded_by: []
---

# ADR-0026: clair CLIの出力契約を統一し、実装はSwiftのまま維持する

## Context

オーナーから、CLIをRust製にするかCobraのようなframeworkを使い、出力を一定にしたいという依頼があった。
当時の不揃いは次のとおりで、いずれも言語に由来しない。

- `CommandResult` の synthesized Codable がそのまま出ていた(`{"result":{"text":{"_0":"…"}}}`)。
- command errorはstdoutのJSON、usageとIPC failureはstderrの平文、`daemon status` は無出力と、経路ごとに違った。
- `main.swift` のif連鎖に分岐があり、usage文字列も重複していた。
- CLIのmessageは設定の「言語」を読まず、常に英語だった。

[ADR-0010](0010-m1-control-plane-swift-with-selective-rust-migration.md)はCLIをRust製の薄いIPC clientにすることを許すが、
Goはcontrol planeの候補から外している。現在のrepoにRustコードはなく、CLIは
`ClairWorkspace`(registry、MCP)、`ClairDaemonKit`、`ClairTerminal`(`attach`)に依存する。

## Decision drivers

- 出力を、scriptとagentが信頼できる1つの形にする。
- GUIとのIPC wire formatと、command registryの契約を変えない。
- 依存とツールチェーンを不要に増やさない。

## Options considered

### Option A: Swiftのまま出力を統一する

- Advantages: 変更が小さい。registry、MCP、attachをそのまま使える。依存が増えない。
- Disadvantages: シェル補完やflag解析のframework機能は付かない。

### Option B: swift-argument-parserを導入する

- Advantages: `open` / `attach` / `daemon` などの固定commandの解析、help、シェル補完が揃う。
- Disadvantages: registry由来のcommandと `key=value` は宣言型に合わず自前のまま残る。出力は揃わない。

### Option C: RustまたはGo + Cobraで書き直す

- Advantages: Cobraなどの成熟したCLI frameworkを使える。
- Disadvantages: ツールチェーンの追加に加え、attachのdaemon接続、MCP adapter、registryのhelpを移植か生成する必要がある。出力の統一そのものはOption Aと同じ作業になる。

## Decision

Option Aを採る。

- どの呼び出しもstdoutにJSONを1行出す。成功は `{"ok":true,"result":…}`、失敗は `{"ok":false,"error":{"code":…,"message":…}}`。
- 人が読むときは `--pretty` で同じJSONを字下げして出せる。既定は1行のまま。
- `ok` がtrueなのはexit 0のときだけ。exitは1 command error、2 usage、3 Clairまたはdaemonに届かない。
- 例外は人が読む `help` / `--help` / `-h`、stdoutを占有する `attach` と `mcp serve`、成功時に無出力の `open --wait`。
- helpと `error.message` は設定の「言語」に従う。JSONのkey、`error.code`、command id、引数名、riskは翻訳しない。
- 変換はCLI側で行い、IPC wire formatは変えない。旧形式は残さない。

## Rationale

不揃いの原因は出力層にあり、frameworkや言語を替えても解消しない。Option B、CはCLIの解析とhelpを
改善するが、registry駆動の中心部分には効かず、どちらも同じ出力変換を別途必要とする。

## Consequences

### Positive

- scriptは `ok` とexit code、`error.code` だけで分岐できる。
- CLIだけを更新しても、起動中のGUIと通信できる。

### Negative

- 旧形式を読むユーザーのscriptは修正が必要になる。
- MCPの応答は別の契約のため今回変更せず、`_0` が残る。
- 失敗を `.text` で返すcommand(`git.*` の一部など)は、従来どおりexit 0かつ `ok:true` になる。registry側の修正が必要な既知の制約である。
- GUI側のcommand固有のprecondition messageは、翻訳されているものに限り言語設定に従う。

## Validation

`WorkbenchIPCTests` が出力の形、exit code、待機の結果、言語切替を検証する。

## Revisit conditions

- シェル補完や多数のflagを持つ固定commandが必要になったら、Option Bを再評価する。
- CLIをGUIなしで広く配布する、または別OSへ展開する要件が生じたら、Option Cを再評価する。

## References

- [ADR-0007](0007-unify-operations-in-a-typed-command-registry.md)
- [ADR-0010](0010-m1-control-plane-swift-with-selective-rust-migration.md)
