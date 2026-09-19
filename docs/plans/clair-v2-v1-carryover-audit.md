# Clair v1 → v2 継承 audit

Status: active
Date: 2026-09-19
根拠: [product principles](../product/principles.md)、[product scope](../product/scope.md)、[feature parity matrix](../benchmarks/feature-parity-matrix.md)、ADR-0002〜0015、v2 [task queue](clair-v2-native-rewrite-queue.md)

v2 の queue は「mobile-on-Clair」「native editor」「libghostty terminal」「mock 準拠 UI」を軸に組まれており、v1 で accepted/must-have だった製品機能の一部が task 化されていない。このドキュメントは抜けを列挙し、追加した `V01`〜`V10` に対応づける。

## 1. 継承状況

| v1 の正本 | 要求 | v2 の現状 | 対応 |
|---|---|---|---|
| ADR-0007 / principle 7 | すべての操作を typed Command Registry に登録。palette/menu/shortcut/CLI/MCP は同じ command を呼ぶ。`aiAvailable`、固定 risk、preflight | **未実装**。`ClairV2AppShell` 内の private `Command` 7 個（palette 専用）のみ。IPC・CLI・MCP なし。daemon の `AgentCommandBoundary` は mobile 向け scoped command でGUI操作は対象外。v1 の `apple/ClairApp/CommandRegistry.swift` と `scripts/clair` は v2 に繋がらない | `V01` `V02` `V03` |
| ADR-0006 / principle 1 | Project = workspace 所有単位。複数 Project、Git なしも可、Project ごとに layout/terminal/agent/notification/settings を保持し復元 | `ProjectID` は protocol にあるが、Mac shell は sample file tree。複数 Project 切替・永続化・復元なし | `V04` |
| scope: Navigation / principle 8 | Quick Open、全文検索・置換 UI、file watcher、agent 変更の live reload、file 単位 local history と復元 | E04 は core の search/replace のみ。`⌘P` は sample file。watcher・local history なし | `V05` |
| ADR-0006 / principle 5,6 / scope: Git | stage/unstage/commit、branch 切替、managed worktree 作成、branch 全体 review（commit 済みと未 commit を分離）、merge commit、native merge editor、cleanup 個別確認 | H07 は read-only の status/diff のみ（mobile 用）。Mac 側の操作系・worktree 作成・merge・conflict 解決なし | `V06` |
| principle 3 / ADR-0002 / scope: agent | Claude Code/Codex/OpenCode を raw terminal として Project root か managed worktree で複数起動。launch profile。事実 signal（bell、exit code、公式 hook）のみ | H04/H05 は OpenCode の semantic adapter のみ。launch profile・Claude Code/Codex なし。mobile の registered agent profile launch（ADR-0011）も未実装 | `V07` |
| scope: Notification | Project badge、通知 history、macOS 通知、Project/terminal 単位 mute | N07 は mobile APNs のみ。Mac 側なし | `V08` |
| ADR-0008 / ADR-0009 / scope: Development loop | Stable/Dev 別 bundle・別 data 領域、GitHub Release + Ed25519 署名 update、click 適用、restart 時 PTY reattach、window close 後も background service 継続、電源接続時の sleep 抑止 | daemon 常駐（H01）と recovery（H10）はある。Stable/Dev identity、updater、sleep 抑止、update restart reattach なし | `V09` |
| scope: Cutover | Stable から Clair source を開き Dev を build・起動、daily-driver blocker なし、ccedit より快適と本人が確認 | N08/T07/E10 は個別 gate。Clair-on-Clair の総合 dogfood は未定義 | `V10` |
| parity: Terminal | OSC 52/633、IME/CJK/wide glyph | T06 は IME/CJK/mouse/paste まで。OSC 52/633 なし | `T07` の acceptance に追記 |

v1 と同等以上で v2 に引き継がれている項目（変更不要）: raw PTY 正本と TUI scraping 禁止（T02/T05）、pairing・device key・revoke・private network（H03/N02/N03、ADR-0011/0012）、APNs（ADR-0015）、native editor（E01〜E10、ADR-0014）、Mac/mobile の入力を broker 到着順で直列化し mobile が PTY を resize しない（T04/T06）、out-of-scope 一覧（Windows/Linux、plugin、task runner 等）。

## 2. ADR との不整合（人間の判断が必要）

1. **PTY の所有言語**: ADR-0010 は Rust `clair-ptyhost` を恒常的な PTY 所有者と決めている。v2 は Swift の `ClairDaemon` + `ClairV2PTY`（C）に置き換え、`crates/` は残るが参照されない。plan §1 は「旧 bridge を残さない」としているが、ADR-0003/0010 を supersede する ADR が存在しない。**ADR-0016 として明示的に supersede を記録するべき**。
2. **semantic adapter**: ADR-0002 は「全 session が `raw_terminal` capability を持ち、semantic は追加層」。v2 の H04/H05/N05 は OpenCode の公式 server API 経由なので方針に反しないが、`raw_terminal` capability が常に併存し、semantic 失敗時に PTY が継続することを `V07` の acceptance で確認する。
3. **ADR-0002/0003/0004 は `proposed` のまま**。v2 が事実上採用している部分（journal/cursor/lease、outbound 接続）を accept/supersede に整理する必要がある（ADR-0016 に含める）。
4. **ADR-0007 の「GUI を state owner」**: v2 は daemon が session を所有する。Command の state owner（GUI か daemon か）を `V01` の設計で決め ADR-0007 に追記する。GUI 状態（pane tree 等）を扱う command は GUI 所有、session 系は daemon 所有とする案を `V01` で検証する。

## 3. 動作確認の方針

「UI だけでは確認が難しい」という ADR-0007 の動機を v2 の完了条件へ戻す。`V01` 以降、Mac 側 UI 操作は command として実行でき、結果は structured state（pane tree、tab、Project、session）の JSON で assert できることを各 task の acceptance に含める。screenshot 照合（U04/U07）は見た目に限定し、操作の正しさは command 経由の test で担保する。
