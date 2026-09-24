# T02: Daemon-owned raw PTY backend

Worker: `codex/v2-t02-daemon-pty` (isolated worktree `bbde/clair`)
Base: `59883ea0bb879677149f8b8831ff41af868c17db`
Lease: `f2f7b4e7-b0fc-4634-ab88-6a30302f6292`

## Invariants (before implementation)

- H04 owns stable SessionID, provider identity, validated cwd and lifecycle.
  A registered OpenCode adapter selects a native PTY process factory. No v1
  runtime, rendering surface, screen scraping or inferred approval is involved.
- stdin/stdout/stderr share a real controlling PTY. A small native supervisor
  creates the terminal session, reaps its provider child, and anchors the process
  group until descendant cleanup. A daemon-owned control pipe closes on crash.
  Unconfirmed cleanup keeps the H04 process/session fenced.
- Raw output is an in-memory bounded byte journal. Epoch and byte offsets expose
  every retention gap. Binary frames have a checked 64 KiB payload maximum.
  Subscriber cursors are independent; delivery is acknowledged explicitly.
  Slow or disconnected viewers cannot suspend PTY draining.
- Daemon attachment IDs bind exact scope, generation, epoch and connection.
  Reconnect preserves the process and SessionID; old epochs never attach to a
  replacement process. A daemon restart requires fresh authorization and state.
- H03 authorizes every remote read/effect. Input commits into one bounded FIFO
  under the authority's synchronous dispatch seam. Operation fingerprints are
  digest-only; committed/rejected/uncertain results are retained in a bounded
  non-evicting dedupe window. Retry cannot resend an earlier input.
- Accepted input means queued bytes, not provider success. A write failure or
  exit with queued bytes becomes explicit uncertainty. No semantic prompt or
  approval is translated to provider text. Raw callers supply their own bytes.
- Desktop geometry has an explicit local owner token. Mobile attachments never
  receive a resize authority; detaching any surface never stops the process.
- No terminal content, arguments, credentials or tokens enter diagnostics,
  test output, checked-in fixtures or persistent journals.

## Failure and focused test matrix

| Boundary | Required evidence |
| --- | --- |
| Native spawn | controlling tty on all three descriptors, binary I/O, cwd, exec failure |
| Lifecycle | normal/abnormal exit, stop/escalation, provider child reaping, descendant cleanup, daemon pipe EOF |
| Identity | duplicate launch, attach/detach without relaunch, resume keeps SessionID and changes epoch |
| Output | binary frame bounds/malformed frame, exact offsets, retention gap, epoch mismatch, slow viewer independence |
| Input | FIFO, duplicate/conflicting ID, scope denial/revoke, stale generation, queue and operation capacity |
| Geometry | desktop owner updates real PTY size; mobile and stale owner cannot resize |
| Composition | authenticated host starts a registered real PTY process and writes/reads it without fixture endpoint effects |

Controller owns full Swift suite, independent D5 review, app/simulator/device
verification, queue updates and integration. N08 owns real provider credentials
and iPhone/APNs dogfood evidence.

## 実装と N08 の接続点

- `ClairPTYAgentProcessFactory` を登録済み provider に指定すると、Swift v2
  runtime が controlling PTY を起動する。native supervisor は provider を
  `waitpid` で回収してから、自身が所有する process group を終了する。daemon の
  control pipe EOF でも同じ回収を行う。別 group/session へ意図的に離脱する
  subprocess の封じ込めを提供する sandbox ではない。
- `ClairDaemonHost.startSession` / `resumeSession` は endpoint を省略できる。
  その場合は実 PTY endpoint を取得し、raw journal と H06 の interrupt/stop を
  接続する。終了済み process を attach し直さず、semantic prompt/approval の
  raw text への変換もしない。
- `host.terminal.attach` は scope、process generation、subscriber ID と任意の
  cursor を受け取る。read は frame を保持し、acknowledge でのみ cursor を進める。
  reconnect は同一 device の同一 subscriber を置き換える。detach は process を
  終了しない。閉じた session の末尾も journal の保持範囲内で閲覧できる。
- `ClairTerminalInputRequest` は raw bytes と、その SHA-256 digest を含む
  B03 operation metadata を結び付ける。認証済み `input(_:on:)` と trusted local
  `localInput` は同じ FIFO / dedupe window を使う。入力に resize owner は不要。
- `ClairTerminalFrame.encoded()` は B03 length prefix、big-endian epoch (8 bytes)、
  byte offset (8 bytes)、最大 64 KiB の raw payload を返す。transport adapter は
  認証済み attachment に frame を関連付け、raw payload を JSON/base64 にしない。
- 標準上限は process ごとに journal 1 MiB、pending input 256 KiB。raw boundary は
  最大 64 session records、各 session 最大 32 subscribers、各 generation 最大
  4096 input operation results。上限到達時は明示的に拒否し、実行済み ID を追い出して
  再実行可能にしない。途中で失われた queued input は stream snapshot の
  `inputIsUncertain` として通知する。
- executable の local registration は `--project-root` と
  `--opencode-executable` を対にし、必要に応じて `--opencode-version` を指定する。
  provider arguments を remote spawn request として受け取らない。環境変数は
  HOME/PATH/LANG/TMPDIR/XDG の既知の設定だけを選び、token を自動継承しない。

Raw byte journal は H08 の normalized event journal と別に保持する。disk persistence、
portable terminal snapshot、renderer、native mobile UI、live mobile transport adapter、
credential を使う model request、実機/APNs dogfood はこの worker の完了証拠に含めない。
N08 はこの authenticated host boundary と binary frame を製品の mobile 経路へ接続する。

## 検証結果（2026-09-15）

実 OpenCode binary の検証は `T02_OPENCODE_EXECUTABLE` にローカルの executable を指定し、
空の一時 HOME と `--version` を使った。user credential や provider log を読み出さず、
raw output の内容は検証記録に保存していない。

実行コマンド（repository root、scratch は `/private/tmp`）:

```sh
swift test --package-path packages/ClairCore --scratch-path /private/tmp/clair-t02-build --filter t02
swift test --package-path packages/ClairCore --scratch-path /private/tmp/clair-t02-build --filter 't02|h10'
swift build --package-path packages/ClairApps --scratch-path /private/tmp/clair-t02-app-build --product ClairDaemon
clang -Wall -Wextra -Werror -fsyntax-only -I packages/ClairCore/Sources/ClairPTY/include packages/ClairCore/Sources/ClairPTY/ClairPTY.c
git diff --check
```

Raw 結果の要約行:

```text
✔ Test run with 20 tests in 3 suites passed after 2.345 seconds.
✔ Test run with 38 tests in 3 suites passed after 5.899 seconds.
Build of product 'ClairDaemon' complete! (0.71s)
```

T02 20 件と既存 H10 18 件が成功。C strict syntax check は exit 0 / output なし。
変更した Swift files の `swift format lint --strict`、`git diff --check` も exit 0 で成功。
初回の fixture cwd 正規化と Swift compile/format 指摘は修正済み。

## 変更ファイル

- `packages/ClairCore/Package.swift`
- `packages/ClairApps/Package.swift`
- `packages/ClairApps/Sources/ClairDaemon/main.swift`
- `packages/ClairCore/Sources/ClairAgent/ClairAgentRuntime.swift`
- `packages/ClairCore/Sources/ClairAgent/ClairPTYAgentProcess.swift`
- `packages/ClairCore/Sources/ClairDaemonKit/ClairDaemonHost.swift`
- `packages/ClairCore/Sources/ClairDaemonKit/ClairTerminalBoundary.swift`
- `packages/ClairCore/Sources/ClairPTY/ClairPTY.c`
- `packages/ClairCore/Sources/ClairPTY/include/ClairPTY.h`
- `packages/ClairCore/Sources/ClairTerminal/ClairTerminalStream.swift`
- `packages/ClairCore/Sources/ClairTransport/ClairDispatchCommit.swift`
- `packages/ClairCore/Tests/ClairCoreTests/ClairTerminalTests.swift`
- `packages/ClairCore/Tests/ClairCoreTests/ClairTerminalBoundaryTests.swift`
- `packages/ClairCore/Tests/ClairCoreTests/ClairTerminalHostTests.swift`
- この T02 専用メモ

queue / parent plan / ADR は未変更。Xcode 共有生成物、surface、v1 runtime を変更していない。
実装上の未解決 blocker はない。controller による独立 D5 review と統合検証は未実施。
