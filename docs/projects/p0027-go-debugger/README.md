---
project_code: p0027-go-debugger
title: "Go/Delve debugger for the native Clair workspace"
status: in-progress
source_issue: "https://github.com/Diwamoto/clair/issues/27"
suggested_branch: "project/p0027-go-debugger"
created: 2026-09-11
updated: 2026-09-11
owners: []
related_adrs:
  - "../../decisions/0001-adopt-swiftui-appkit-frontend.md"
  - "../../decisions/0010-m1-control-plane-swift-with-selective-rust-migration.md"
related_investigations: []
---

# Go/Delve debugger for the native Clair workspace

## Outcome

ClairのネイティブmacOSワークスペースからGo Projectを起動またはattachし、DAP/Delveを使ってブレークポイント、実行制御、スタック、変数、watch、デバッグコンソールを利用できる。デバッグ画面は既存のUIモックと同じくサイドバーの「実行とデバッグ」から開け、Projectごとに状態が分離される。

## Documents

- [Requirements](requirements.md)
- [Design](design.md)
- [Implementation plan](plan.md)

## Context links

- Source issue: [#27](https://github.com/Diwamoto/clair/issues/27)
- Parent issue: [#1](https://github.com/Diwamoto/clair/issues/1)
- Dependency: [#26 Go/gopls](https://github.com/Diwamoto/clair/issues/26)
- Roadmap: [Milestone 3B](../../clair-spec.md)
- Feature matrix: [Debugger row](../../benchmarks/feature-parity-matrix.md)
- Native shell: [development workspace architecture](../../architecture/development-workspace.md)
- UI reference: `prototypes/clair-interaction-lab` Debug artboard and `prototypes/clair-workbench/src/screens/Debug.tsx`

## Readiness

- [x] goalsとnon-goalsが明確
- [x] 受け入れ条件が検証可能
- [x] component境界と主要interfaceが決まっている
- [x] accepted ADRと矛盾しない
- [x] materialなblocking questionがない
- [x] 各受け入れ条件がplanとvalidationへ対応している

## Blocking questions

None. Delveの実行ファイルが見つからない環境では、wire/clientとUIの自動テストまでを実行し、実Delveのmanual smokeはインストール後に行う。

## Completion summary

Slice 1 is implemented. The native navigation entry, Project-scoped session
model, idle/start UI, bounded console, and the initial Delve/DAP transport are
in the working tree. Source-location reveal and CodeMirror breakpoint gutter
integration are now connected to the Project editor. Fake-server lifecycle
coverage, reconnect handling, native-editor fallback parity, and Delve manual
smoke remain before this project is complete.

## Validation evidence

- `ruby scripts/validate-xcode-project.rb` passed.
- Project-scoped XCTest passed: 12 tests in `ProjectNavigationTests`, including
  debug navigation, source-location reveal safety, and DAP framing/size-limit
  and breakpoint-store coverage.
- `npm --prefix editor-web run build` and the bundled EditorWeb resource sync
  passed, including the breakpoint gutter bridge.
- The native Dev target compiled during the isolated test run.
- Full `make test-swift` was interrupted after an existing file-watcher test
  stopped making progress; it did not report a debug test failure.
- Delve manual smoke is pending because `go`/`dlv` are not installed in the
  current environment.
