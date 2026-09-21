# Clair / ccedit feature parity matrix

この matrix は [Clair v2 roadmap](../clair-spec.md) の M1 cutover 範囲を固定する。
`must-have` は Clair Stable だけで Clair を開発し、別 bundle の Clair Dev を確認して ccedit を廃止するために必要なもの、
`later` は roadmap 上の後続 milestone、`out-of-scope` は現在の product boundary から意図的に除外するものを表す。

`ccedit V1 status/evidence` の `not-verified` は、V1 実装の precedent または locked-session partial result は確認できても、
固定 commit・同一 corpus・同一操作 script による unlocked UI/PTY/Instruments evidence が揃っていないことを示す。
`not-verified` を parity 達成や性能比較の根拠として扱わない。

このmatrixはscope確認用であり、機能ごとのperformance gateではない。Formal comparisonは
[local PoC queueの`L01`](../clair-tasks.md#l01-final-load-and-performance)だけで行う。

## M1 must-have

| Area | Capability | ccedit V1 status/evidence | Clair M1 classification | Verification anchor |
|---|---|---|---|---|
| Benchmark | 機能統合後に固定したV1 commit、corpus、操作条件で最終負荷試験を行う | not-verified — locked-session partial result のみ。unlocked UI/PTY/Instruments は未取得 | final-only | L01 |
| Native architecture | SwiftUI/AppKit shell、Tauri 非依存 Rust core、versioned Swift–Rust control plane | not-verified — Tauri/React と Rust core の実装構成は context のみ | must-have | #3 / #7 / #8 |
| Application | Stable/Dev を別 bundle ID・product name・settings/data 領域で並行起動 | not-verified — V1 の product identity は未計測 | must-have | #3 |
| Project | Git の有無を問わない local folder を Project として開き、1 process で複数 Project を切り替える | not-verified — V1 の repository-centric flow は precedent のみ | must-have | #9 / #28 |
| Workspace | editor/terminal/diff の mixed tab・pane、任意 split、focus/move/close/equalize と Project ごとの安全な復元 | not-verified — V1 の pane/layout behavior は未計測 | must-have | #9 / #34 / #35 |
| Navigation | large file tree、Quick Open、全文検索・置換、watcher 更新、file history/settings surface | not-verified — V1 の file tree/search behavior は未計測 | must-have | #10 |
| Editor | native document model、open/edit/save/undo、live reload/local history、Unicode/IME、large file、diff/merge seam | not-verified — CodeMirror 6 implementation は context のみ | must-have | #11 / #12 / #13 |
| Terminal | Ghostty-class native surface、raw shell input、resize、scrollback、selection、OSC 52/633、IME/CJK/wide glyph | not-verified — xterm.js + PTY implementation は context のみ | must-have | #5 / #6 |
| Session | Project 切替・window close・app/update restart をまたぐ PTY/session lifecycle と reattach | not-verified — detached ptyhost behavior は未計測 | must-have | #6 / #18 |
| Agent/worktree | Claude Code/Codex/OpenCode を Project root または任意 managed worktree で raw terminal として複数起動 | not-verified — V1 agent profile behavior は未計測 | must-have | #15 / #22 |
| Git | working tree/stage/commit、branch-wide diff、commit gate、merge commit、conflict 解決、worktree/branch cleanup 確認 | not-verified — V1 Git integration behavior は未計測 | must-have | #14 / #22 |
| Commands | stable ID と typed schema を持つ Command Registry、Command Window、menu、任意 shortcut | not-verified — V1 keymap/menu behavior は未計測 | must-have | #25 / #33 / #29 |
| CLI | local IPC、cold/warm routing、`clair open path:line:column`、machine-readable result/error | not-verified — V1 CLI behavior は未計測 | must-have | #16 / #36 |
| AI boundary | stdio MCP、`aiAvailable` filter、static risk、runtime preflight、Clair GUI approval | not-verified — V1 に対する同一 contract の証拠は未保存 | must-have | #25 / #37 |
| Notification | factual signal に基づく Project/terminal notification、history/reveal、mute、macOS notification | not-verified — V1 notification behavior は未計測 | must-have | #15 |
| Reliability | layout/document/PTY recoveryと診断を機能testで継続確認し、launch/resource/terminal/large fixture負荷を最後に測る | not-verified — backend/process diagnostic のみで performance/recovery coverage は未完了 | must-have + final load | P04/P05/P07 + L01 |
| Release/update | 署名・notarize 済み personal build、検証済み update feed、click update、restart reattach、retry/rollback | not-verified — V1 release/update behavior は未計測 | must-have | #18 |
| Cutover | Stable から Clair source を開き Dev を build・起動し、daily-driver blocker なし・ccedit より快適と本人が確認 | not-verified — dogfooding/cutover result は未保存 | must-have | #19 |

## Early and later

| Area | Capability | ccedit V1 status/evidence | Clair M1 classification | Verification anchor |
|---|---|---|---|---|
| Language intelligence | generic LSP、gopls、completion/diagnostics/definition/references/rename/code action/format | not-verified — V1 状態は M1 gate の判定に使わない | later | M2 / #26 |
| Mobile terminal | private iPhone/iPad PWA、pairing/revoke、WSS、raw terminal control | not-verified — V1 desktop baseline の比較対象外 | early slice | P16 / #20 |
| Debugger | DAP、Go/Delve、breakpoint、step、stack、variables、console | not-verified — V1 状態は M1 gate の判定に使わない | later | M3B / #27 |
| Mobile review | branch-wide diff review と merge commit 承認 | not-verified — V1 desktop baseline の比較対象外 | later | M4 / #24 |
| Dev Container | 既存 `.devcontainer/devcontainer.json` の検出・起動と container 内 editor/terminal/agent | not-verified — V1 状態は M1 gate の判定に使わない | later | M5 / #23 |
| First-party additions | API tester 等の密結合 first-party feature | not-verified — V1 状態は M1 gate の判定に使わない | later | Later / #21 |

## Out of scope

| Area | Capability | ccedit V1 status/evidence | Clair M1 classification | Verification anchor |
|---|---|---|---|---|
| Platform | Windows/Linux frontend | not-applicable — V1 の有無にかかわらず product boundary 外 | out-of-scope | roadmap non-goal |
| Collaboration | team workspace、共同編集、account/settings sync、hosted agent/cloud VM | not-applicable — V1 の有無にかかわらず product boundary 外 | out-of-scope | roadmap non-goal / product scope |
| Compatibility | VS Code extension/settings/tasks compatibility | not-applicable — 意図的に互換 contract を持たない | out-of-scope | roadmap non-goal / product scope |
| Extensibility | third-party plugin SDK/marketplace | not-applicable — first-party additions と分離する | out-of-scope | roadmap non-goal / product scope |
| Mobile IDE | mobile full IDE、source editor、汎用 remote shell の新規起動 | not-applicable — Mobile milestone は bounded raw-terminal control に限定 | out-of-scope | product scope |
| Agent state | TUI screen scraping で semantic state/approval/tool call を推測 | not-applicable — factual signal のみを利用する | out-of-scope | product principles / product scope |
| Persistence | session 終了後の terminal transcript 保存 | not-applicable — shell history と active-session scrollback に委ねる | out-of-scope | product principles / product scope |
| Runner | Clair 独自 task runner | not-applicable — build/test/run/lint は terminal または agent が実行する | out-of-scope | product scope |

## Classification rules

- `must-have` は local roadmap の M1 required capabilities と root roadmap issue #1 の M1 issue 群に対応する。
- V1 に存在するという記述だけでは `must-have` や parity pass の根拠にしない。M1 outcome と product scope を優先する。
- `later` は roadmap に明示された後続 milestone または Later issue に destination があり、M1 performance parity の pass/fail に含めない。
- `out-of-scope` は未実装という意味ではなく、[product scope](../clair-spec.md) と [product principles](../clair-spec.md) が意図的に除外する capability を示す。
- V1 と Clair の性能を直接比較できるのは、[benchmark procedure](clair-v1-baseline.md) と [ADR-0001](../decisions/0001-adopt-swiftui-appkit-frontend.md) に従い、固定 commit・corpus・操作 script・環境条件・raw samples が揃った場合だけとする。
- cutover の最終判断は [product vision](../clair-spec.md) に従い、機能数だけでなく Clair-on-Clair の実地利用と本人の体感確認を含む。
