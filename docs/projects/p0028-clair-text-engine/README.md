---
project_code: p0028-clair-text-engine
title: "Clair text engine: editorとterminalが共有するmonospace surface"
status: ready
source_issue: "local queue P17-P34"
suggested_branch: "project/p0028-clair-text-engine"
created: 2026-09-11
updated: 2026-09-11
owners:
  - Daiki
related_adrs:
  - ADR-0014
  - ADR-0001
  - ADR-0010
related_investigations:
  - docs/issues/native-editor/README.md
---

# Clair text engine

## Outcome

ClairのeditorとterminalがひとつのClair所有surface engineの上で動作し、日常操作の体感がcceditと
VS Code + Ghostty併用の双方に対して明確に優れている。WKWebViewとCodeMirrorはhot pathから外れ、
fallbackとしてだけ残る。大規模fileと長行でlayoutが破綻せず、日本語IMEとVoiceOverが実機で通る。

## Documents

- [Requirements](requirements.md)
- [Design](design.md)
- [Implementation plan](plan.md)

## Context links

- Source decision: [ADR-0014](../../decisions/0014-clair-owned-text-engine.md)
- Parent or related decisions: [ADR-0001](../../decisions/0001-adopt-swiftui-appkit-frontend.md)、
  [ADR-0010](../../decisions/0010-m1-control-plane-swift-with-selective-rust-migration.md)
- Related architecture: [development workspace](../../architecture/development-workspace.md)
- Related plans or runbooks: [PoC queue P17-P34](../../plans/clair-poc-queue.md)、
  [local development](../../runbooks/local-development.md)
- Superseded work: [native editor issues NE-11、NE-15〜NE-23](../../issues/native-editor/README.md)

## Readiness

- [x] goalsとnon-goalsが明確
- [x] 受け入れ条件が検証可能
- [x] component境界と主要interfaceが決まっている
- [x] accepted ADRと矛盾しない
- [x] materialなblocking questionがない
- [x] 各受け入れ条件がplanとvalidationへ対応している

## Blocking questions

None. Tree-sitter grammarの配布許諾は`P23`のscope内のstop conditionとして扱い、project全体のblockerにしない。

## Completion summary

Not started.

## Validation evidence

Not run. 現行既定の基準値は`P17`で取得する。
