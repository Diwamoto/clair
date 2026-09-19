# V02: local IPC と `clair` CLI — invariants と test matrix

実装: `ClairV2Workspace/WorkbenchIPC.swift`、GUI 接続: `ClairV2AppKit/ClairV2AppShell.swift`(`ClairV2WorkbenchStore`)、CLI: `packages/ClairV2Apps/Sources/clair`。

## Invariants

1. state owner は GUI process(ADR-0007)。IPC は `CommandRegistry.execute` へ転送するだけで、独自の command 実装を持たない。GUI 不在なら CLI は exit 3。
2. socket は `~/Library/Application Support/Clair v2/command.sock`(dir 0700 / socket 0600、`umask` 0177 で作成)。接続 peer の uid が server の uid と異なれば返信せず切断。
3. `confirmed` は wire に無い。destructive 以上は `confirmationRequired` を返し、GUI の native 確認だけが実行できる。
4. 1 connection = 1 request、1MB 上限、silent client は 5s で切る。malformed は `invalidInput`。
5. 稼働中 server がいる path は奪わず `alreadyRunning`。stale な自 uid の socket だけ回収し、socket 以外は消さない。

## CLI

`clair open path[:line[:col]]`(= `tab.open`)/ `clair <command-id> key=value…`。値は bool → int → double → string の順に推論。stdout は JSON、exit 0 ok / 1 command error / 2 usage / 3 GUI 不在。

## Test matrix(`WorkbenchIPCTests`)

| 項目 | test |
|---|---|
| headless で分割 → snapshot → 検証、error の machine-readable | `testSplitSnapshotAssertViaCLIOnly` |
| destructive は IPC から確認不可(`confirmed` 混入も無視) | `testDestructiveCannotBeConfirmedOverIPC` |
| 別 uid 切断、socket 0600 / dir 0700 | `testOtherUserAndMalformedAndPermissions` |
| 未起動 / 二重起動 / 引数 parse | `testNotRunningAndAlreadyRunningAndParse` |

## 既存 CLI の再利用判断

`scripts/clair` と `crates/clair-cli` は v1 GUI(`command-v1.sock`、v1 command 集合)専用。v2 registry と wire・権限モデルが異なり、旧 runtime を fallback に残さない方針のため再利用しない。

## 未対応(後続)

- `path:line:column` の cursor 移動(registry に cursor command が無い。editor の file binding = V04/V05 後)。
- 複数 window の socket 所有(先着 window のみ。V04 の Project 別 window で再設計)。
- MCP adapter と `aiAvailable` の強制は V03。
