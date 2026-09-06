---
project_code: p0021-api-tester
title: "API Tester"
status: draft
source_issue: "https://github.com/Diwamoto/clair/issues/21"
suggested_branch: "project/p0021-api-tester"
created: 2026-08-28
updated: 2026-08-29
owners: []
related_adrs:
  - "../../decisions/0001-adopt-swiftui-appkit-frontend.md"
related_investigations: []
---

# API Tester

## Outcome

Clairで、プロジェクトごとに保存したAPIリクエストを選択・編集し、生成されたcurlを確認して実行結果を読める。Interaction Labではこの体験をブラウザ内のモックとして検証できる。

## Documents

- [Requirements](requirements.md)
- [Design](design.md)
- [Implementation plan](plan.md)

## Context links

- Source issue: [#21](https://github.com/Diwamoto/clair/issues/21)
- Related architecture: [Architecture index](../../architecture/README.md)
- Related decision: [ADR-0001](../../decisions/0001-adopt-swiftui-appkit-frontend.md)
- Mock evidence: [Clair Interaction Lab](../../../prototypes/clair-interaction-lab/app/page.tsx)

## Readiness

- [x] goalsとnon-goalsが明確
- [x] 受け入れ条件が検証可能
- [ ] component境界と主要interfaceが決まっている
- [x] accepted ADRと矛盾しない
- [ ] materialなblocking questionがない
- [x] 各受け入れ条件がplanとvalidationへ対応している

## Blocking questions

1. ネイティブ版で保存済みリクエストに含まれるsecretをどの境界で保護するか。
2. 実HTTP実行をRust core、Swift shell、または別の承認付きサービスのどこに置くか。
3. 初期リリースで環境変数、OAuth、cookie jar、team sharingを扱うか。

## Completion summary

Interaction LabのAPI Testerモックを実装済み。保存済みrequestのCRUD、field編集、curl preview/copy、mock response確認を検証できる。nativeの実 HTTP 実行、secret保護、persistence boundaryは未着手。

## Validation evidence

- `npm run build` successful on 2026-08-29.
- `git diff --check` successful on 2026-08-29.
- Local dev/preview serverはsandboxのbind制限で起動できず、browser interaction verificationとSites publishはpending。
