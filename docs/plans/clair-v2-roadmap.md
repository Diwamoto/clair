# Clair v2 roadmap

## Purpose

このroadmapは、cceditからClairへcutoverし、その後personal daily-driver IDEを完成させるmilestone順とexit criteriaを定義する。M1の実装順序は
[PoC feature development queue](clair-poc-queue.md)で扱う。

## PoC execution policy

- GitHub issueは実装開始条件にせず、local queueのdependency-readyな機能を進める。
- 一つのsliceは利用者が確認できるvertical behaviorと、unit/integration/manual smokeで完了する。
- Benchmark corpus生成、反復timing、Instruments、V1 parity計測はsliceごとに行わない。
- Formal performance comparisonと負荷試験は、M1機能が統合されdogfooding可能になった後の
  `L01 Final load and performance`で一度まとめて行う。
- Crash、data loss、unbounded allocation、protocol frame bound等の安全性はperformanceではなく
  correctnessとして各sliceで検証する。

## Milestone 0: Product alignment

### Outcome

product vision、principles、scopeが正本化され、既存project/ADRとの矛盾が明示されている。

### Exit criteria

- [Vision](../product/vision.md)、[principles](../product/principles.md)、[scope](../product/scope.md)がaccepted product directionを表す。
- Worktree-first ownershipをProject-first/optional-worktreeへ置き換えるADRがacceptedである。
- 旧worktree-first projectが再設計前に実装されない状態になっている。

## Milestone 1: Local Clair-on-Clair cutover

### Outcome

Clair Stableだけを使ってClairをvibe codingし、別bundleのClair Devで変更を確認できる。cceditを廃止する。

### Required capabilities

- Native SwiftUI/AppKit shellとccedit Rust core migration。
- Multi-Project workspace、mixed pane/tab、sidebar、layout persistence。
- Native editor、file navigation/search、live reload、local history、diff/merge view。
- Ghostty-class terminal、raw agent launch、optional managed worktree。
- Branch-wide review、merge commit、conflict resolution、cleanup confirmation。
- Command Registry、command palette、configurable shortcuts、CLI、stdio MCP。
- In-app/macOS notificationとmute。
- Stable/Dev並行起動、in-app update、update時PTY reattach。
- cceditより快適だという利用者の体感確認。

### Explicitly not required

- Swift/Rust language intelligence。
- Integrated debugger。
- Dev Container。
- API tester。

## Milestone 1.5: Early mobile agent control

### Outcome

Go editorやdebuggerを待たず、自宅Macで動くClairのagentをiPhone/iPadから安全に確認・操作・起動できる。

### Exit criteria

- Project/session catalog、current screen、bounded scrollback、raw terminal input、registered agent launchが動作する。
- Cloudflare private-network transport、QR device-key pairing、device revoke、APNs opaque attention notificationが動作する。
- Macとmobileの入力がbroker到着順で同じPTYへ適用され、mobileがPTY geometryを暗黙に変更しない。
- GUIを閉じてもhost serviceが継続し、mobile feature flagで機能全体を無効化できる。
- Private TestFlight internal buildと`main`/manual/30日scheduleのCIが動作する。

Initial scopeはsingle-user・自所有device・raw terminalに限定する。semantic approval、vendor adapter、branch review、
public relay/E2EEはこのmilestoneのexit criteriaに含めず、後続sliceで個別に判断する。

## Milestone 2: Go daily-driver editor

### Outcome

ClairをGo開発の日常editorとして利用できる。

### Exit criteria

- generic LSP lifecycleとgopls integrationが動作する。
- completion、diagnostics、definition、references、rename、code action、format、symbol searchが実用になる。

## Milestone 3A: Mobile terminal hardening and extensions

### Outcome

初期mobile controlを実利用で安定させ、必要なagent convenienceを追加する。

### Exit criteria

- gap/resync、network switch、background/foreground、sleep/wake、resource boundを実用状態にする。
- 対応agentのstructured prompt/interrupt/status等をcapability-basedに追加する。raw terminal fallbackを維持する。
- 必要性が確認されたnotification actionやmobile branch reviewを追加する。

## Milestone 3B: Go debugger

### Outcome

Go/DelveをClairのnative debug UIから利用できる。

### Exit criteria

- DAP lifecycle、breakpoint、continue/step、stack、variables、consoleが動作する。

Milestone 3Aと3Bの順序は固定しない。

## Milestone 4: Mobile branch review

### Outcome

mobileからagent branch全体をreviewし、merge commitを承認できる。

## Milestone 5: Dev Container

### Outcome

既存`.devcontainer/devcontainer.json`を使い、container内でeditor、terminal、agentを利用できる。Dev Containerはcore roadmapの最後に実装する。

## Optional later additions

- API tester等のfirst-party機能。
- Mobile利用が定着した場合のClair relay/E2EE transport。
- 実利用で必要性が確認されたlanguage serverやDAP adapter。

## Non-goals across the roadmap

Team、account、settings sync、hosted agent、marketplace、Windows/Linux、VS Code extension compatibilityはこのroadmapへ含めない。
