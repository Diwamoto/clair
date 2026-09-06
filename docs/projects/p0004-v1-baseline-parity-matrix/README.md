---
project_code: p0004-v1-baseline-parity-matrix
title: "ccedit V1 benchmark baseline と feature parity matrix"
status: in-progress
source_issue: "https://github.com/Diwamoto/clair/issues/4"
suggested_branch: "project/p0004-v1-baseline-parity-matrix"
created: 2026-08-31
updated: 2026-08-31
owners:
  - Daiki
related_adrs:
  - ADR-0001
related_investigations: []
---

# ccedit V1 benchmark baseline と feature parity matrix

## Outcome

ccedit V1 と Clair の native rewrite を同じ workload で比較できるように、固定した V1
source、決定的な corpus、再現手順、raw result の schema、要約、feature parity の分類、
後続の performance gate で使う指標を repository に残す。

## Documents

- [Requirements](requirements.md)
- [Design](design.md)
- [Implementation plan](plan.md)

## Context links

- Source issue: https://github.com/Diwamoto/clair/issues/4
- Parent roadmap: https://github.com/Diwamoto/clair/issues/1
- Related architecture: [Development workspace](../../architecture/development-workspace.md)
- Existing decision: [ADR-0001 SwiftUI + AppKit frontend](../../decisions/0001-adopt-swiftui-appkit-frontend.md)
- Benchmark procedure and V1 summary: [clair-v1-baseline](../../benchmarks/clair-v1-baseline.md)
- Metric contract: [metric-contract](../../benchmarks/metric-contract.json)
- Operation script: [v1-parity-operation-script](../../benchmarks/workloads/v1-parity-operation-script.json)
- Feature matrix: [feature-parity-matrix](../../benchmarks/feature-parity-matrix.md)
- Corpus: [benchmark corpus](../../benchmarks/corpus/README.md)

## Readiness

- [x] goalsとnon-goalsが明確
- [x] 受け入れ条件が検証可能
- [x] component境界と主要interfaceが決まっている
- [x] accepted ADRと矛盾しない
- [x] materialなblocking questionがない
- [x] 各受け入れ条件がplanとvalidationへ対応している

## Blocking questions

No product decision is open. Absolute pass/fail thresholds are intentionally
deferred until a Clair vertical slice exists. The remaining execution blocker is
an unlocked GUI session for UI/PTY/Instruments evidence; the current capture
records `screen_locked: true` and cannot satisfy those measurements.

## Completion summary

In progress. Added the deterministic 10,000-file/large-file/Unicode-IME/terminal
corpus, versioned operation and metric contracts, parity matrix, sandboxed V1
collector, evidence ingester, result validator, reproducible pinned-source build
procedure, and one fixed-commit raw capture. The capture contains 10 backend trials
and 300 process samples, but remains a locked-session partial result; 17
UI/PTY/Instruments metrics are explicitly `not-measured`.

## Validation evidence

- benchmark shell syntax: pass
- corpus generation and deterministic manifest replay: pass
- corpus contract: 10,011 entries, 10,000 tree files, exact 10/100 MiB and 1 MiB payload sizes
- fixed V1 capture: partial as designed on locked session; 5 fresh-profile + 5 warm runs
- raw result validation and summary recalculation: pass
- unlocked display identity validation and evidence ingestion round-trip: pass with synthetic evidence
- evidence identity/provenance/sample/summary/coverage negative checks: pass
- pinned-source release build, benchmark bundle identity, and sidecar inspection: pass
- validator negative checks for changed source pin and corrupted summary: pass
- benchmark-only app storage cleanup: pass
- UI/PTY/Instruments capture: blocked until the macOS session is unlocked
