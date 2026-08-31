---
project_code: p0003-native-workspace-bootstrap
title: "Stable / Dev native workspace bootstrap"
status: complete
source_issue: "https://github.com/Diwamoto/clair/issues/3"
suggested_branch: "project/p0003-native-workspace-bootstrap"
created: 2026-08-30
updated: 2026-08-31
owners:
  - Daiki
related_adrs:
  - ADR-0001
  - ADR-0008
related_investigations: []
---

# Stable / Dev native workspace bootstrap

## Outcome

Clean checkout から同じ標準commandで SwiftUI macOS application と Rust
workspaceをbuild・testでき、Clair StableとClair Devを別bundle、別表示名、別settings/data
領域で同時に起動できる。Swift applicationはRust coreへの最小C ABI smoke callを実行し、
localとGitHub Actionsで同じunsigned smoke buildを再現できる。

## Documents

- [Requirements](requirements.md)
- [Design](design.md)
- [Implementation plan](plan.md)

## Context links

- Source issue: https://github.com/Diwamoto/clair/issues/3
- Parent roadmap: https://github.com/Diwamoto/clair/issues/1
- Ordering dependency: https://github.com/Diwamoto/clair/issues/2
- Related architecture: [Development workspace](../../architecture/development-workspace.md)
- Related runbook: [Local development](../../runbooks/local-development.md)
- Related plan: [Clair v2 roadmap](../../plans/clair-v2-roadmap.md)
- Existing decision: [ADR-0001 SwiftUI + AppKit frontend](../../decisions/0001-adopt-swiftui-appkit-frontend.md)
- Project decision: [ADR-0008 Stable / Dev runtime identity](../../decisions/0008-stable-dev-runtime-identity.md)

## Readiness

- [x] goalsとnon-goalsが明確
- [x] 受け入れ条件が検証可能
- [x] component境界と主要interfaceが決まっている
- [x] accepted ADRと矛盾しない
- [x] materialなblocking questionがない
- [x] 各受け入れ条件がplanとvalidationへ対応している

Issue #3のordering dependencyである#2はopenだが、2026-08-30に利用者が#3の開発環境を
先に完成させるよう明示した。#3が必要とする未確定のruntime identityとminimum macOSは
[ADR-0008](../../decisions/0008-stable-dev-runtime-identity.md)で固定したため、実装を変え得る
decision blockerは残っていない。

## Blocking questions

None. Xcode 26.6 is installed, its developer directory is selected, and the
license and first-launch setup are complete.

## Completion summary

Implemented the committed Xcode/Cargo workspace, Stable/Dev runtime profiles,
SwiftUI bootstrap lifecycle, Rust core C ABI, `clair-ptyhost` skeleton, shared
developer commands, CI workflow, ignore rules, architecture, and runbook.

Full Xcode verification now passes on Xcode 26.6. Stable and Dev build as
separate unsigned app bundles, all Rust and Swift tests pass, Xcode static
analysis passes, and both apps were launched together with visibly separate
bundle, preferences, and Application Support identities. The bundle smoke path
also supports Xcode 26's Debug dylib layout while continuing to verify the real
Rust symbol.

## Validation evidence

Passed on 2026-08-30:

- `make workspace-check` — PBX plist, workspace XML, both shared schemes,
  channel xcconfig structure, 63 project objects, 3 targets, all internal
  references, and tracked file paths passed.
- `make artifact-check` — representative Cargo, DerivedData, generated, and
  Xcode user outputs are ignored; none are tracked.
- `make test-rust` — 2 tests passed across `clair-core` and `clair-ptyhost`;
  doc tests passed.
- `make lint-rust` — `cargo fmt --check` and Clippy with warnings denied passed.
- `cargo run -p clair-ptyhost --locked -- --smoke` — returned
  `clair-ptyhost/0 smoke=ok`.
- `swift format lint --recursive --parallel --strict apple` — passed.
- Swift 6 CLI typecheck passed for both `CLAIR_STABLE` and `CLAIR_DEV` app source.
- `make smoke-ffi` — compiled and executed Stable and Dev Swift binaries linked
  to `libclair_core.a`; both returned `0x434C4149` with the expected bundle ID
  and created isolated temporary Application Support directories.
- `make smoke-app-link` — linked the complete shared SwiftUI source graph for
  `CLAIR_STABLE` and `CLAIR_DEV` at deployment target macOS 14.0; both outputs
  are arm64 Mach-O executables containing `_clair_core_smoke`.
- `bash -n scripts/*.sh`, workflow YAML parsing, documentation-link resolution,
  and whitespace checks passed.
- `make doctor` correctly detected that full Xcode was the one missing
  prerequisite before it was installed.

Passed on 2026-08-31 with Xcode 26.6, Swift 6.3.3, macOS SDK 26.5, and Rust
1.98.0:

- `make clean-artifacts` followed by `make ci` — Rust format/Clippy, strict Swift
  format, Xcode analysis, workspace validation, 2 Rust tests, 6 Swift/XCTest
  tests, Stable/Dev CLI FFI smoke, full SwiftUI link smoke, both unsigned app
  builds, bundle metadata/linkage smoke, and artifact guards all passed.
- `make build-stable build-dev` produced `Clair.app` and `Clair Dev.app` with
  bundle IDs `com.diwamoto.clair` and `com.diwamoto.clair.dev`; both contained
  `_clair_core_smoke` in the Xcode-selected linked image.
- `make run-stable` and `make run-dev` launched two concurrent processes and two
  windows. Their visible bootstrap state showed distinct display names, bundle
  and preferences domains, and Application Support paths ending in `Clair` and
  `Clair Dev`; both reported `0x434C4149` and a ready Swift-to-Rust path. Both
  processes were then terminated normally.
- The Swift test suite wrote one unique key to each bundle preferences domain,
  verified the values did not cross domains, and removed both test values. It
  also verifies that an unavailable system Application Support location is
  reported instead of being replaced with a manually constructed fallback path.

The GitHub Actions run remains an integration check after the working tree is
reviewed, committed, and pushed. The tracked workflow runs the same passing
`make ci` entrypoint on `macos-26`; no commit, push, or issue-state change was
performed by this project execution.
