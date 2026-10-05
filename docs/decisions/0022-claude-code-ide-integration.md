---
id: ADR-0022
title: "Clair を Claude Code の IDE として接続させる(localhost WebSocket + lock file)"
status: accepted
date: 2026-10-03
deciders: [Diwamoto]
related_projects: []
related_issues: []
supersedes: []
superseded_by: []
---

# ADR-0022: Claude Code の IDE 連携

## Context

Clair の terminal で動く Claude Code は、Clair のエディタが知っていること(選択範囲、開いている
ファイル、言語サーバーの診断)を知らず、ファイルの変更提案も TUI の中でしか承認できない。
Claude Code は VS Code / JetBrains / Neovim 向けに「IDE 連携」を持ち、IDE 側が次を提供すると
自動で接続する(オーナー依頼 2026-10-03「D やる」)。

- `~/.claude/ide/<port>.lock`(`CLAUDE_CONFIG_DIR` があればその下)に pid、workspaceFolders、
  ideName、`transport: "ws"`、authToken を書く
- `127.0.0.1:<port>` の WebSocket で、upgrade の `x-claude-code-ide-authorization` ヘッダを token と照合する。
  Claude Code は subprotocol `mcp` を要求し、upgrade 応答がそれを選ばない socket では接続を完了しない
- その上で MCP(JSON-RPC 2.0)を話し、`openFile` / `openDiff` / `getCurrentSelection` /
  `getLatestSelection` / `getOpenEditors` / `getWorkspaceFolders` / `getDiagnostics` /
  `checkDocumentDirty` / `saveDocument` / `close_tab` / `closeAllDiffTabs` に答える
- IDE の terminal には `CLAUDE_CODE_SSE_PORT` と `ENABLE_IDE_INTEGRATION=true` を渡す
- IDE からは `selection_changed` と `at_mentioned` を通知する

公開仕様はなく、Anthropic の拡張と coder/claudecode.nvim の実装が事実上の仕様である。

## Decision drivers

- 原則 3: raw terminal を正本のまま、TUI を解析しない。Claude Code 自身が出す公式の連携経路だけを使う
- 会社ではサブスクリプションの Claude Code しか使えない。API key や別課金を前提にしない
- localhost の他プロセスから Clair を操作されない
- 拡張なしで動く(Claude Code に plugin を入れさせない)

## Decision

- Mac app の最初の window の store が `ClaudeIDEServer`(Network.framework の WebSocket listener)を
  127.0.0.1 だけに bind して起動する。token は起動ごとに 128 bit の乱数、照合は定数時間比較
- port は前回のものを優先して再利用する。daemon が持つ shell は app の再起動をまたいで残るため、
  shell に入った `CLAUDE_CODE_SSE_PORT` を古くしないため。使えなければ空き port
- lock file は directory 0700 / file 0600 で atomic に書き、開いている全 Project の root を
  workspaceFolders に入れる。Project の追加・削除で書き直し、app の終了で消す
- app の環境変数に `CLAUDE_CODE_SSE_PORT` / `ENABLE_IDE_INTEGRATION` / `FORCE_CODE_TERMINAL` を設定し、
  daemon はこれらを shell に渡す(`ClairLocalTerminalHost.forwardedEnvironment`)
- ツールは store が live state から答える。`openDiff` は提案内容を Clair の data 領域の
  `proposals/` に置き、そのファイルの Project で「提案」diff タブとして開いて、利用者が承認するまで応答を保留する。
  承認で `FILE_SAVED` と内容を返し、ファイルは Claude Code が書く。却下・タブを閉じる・同じタブ名の新しい提案・app 終了は `DIFF_REJECTED`。
  開いている Project の外のファイルはエラーを返し、Claude Code 自身の承認 UI に任せる
- 選択の変化は 100 ms にまとめて `selection_changed` を送る。`agent.mention`(⌥⌘K)で選択範囲を
  `at_mentioned` として接続中の Claude Code に渡す
- 提案タブは app 再起動後に応答先がないので起動時に捨てる

## Consequences

- Claude Code の編集提案を Clair の diff で見て承認できる。診断・選択・開いているファイルを Claude Code が直接読める
- 同じ user の local プロセスは lock file を読めば token を得られる。これは VS Code の拡張と同じ信頼境界で、
  ツールは読み取りと、利用者が承認したときだけの書き込み(書くのは Claude Code)に限る
- 公開仕様ではないため、Claude Code の更新で壊れうる。壊れても raw terminal の Claude Code は従来どおり動く
- 提案 diff タブは Design canvas に未定義(既存の diff と承認カードの語彙で作った)。canvas への反映が残る
