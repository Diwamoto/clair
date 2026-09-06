# Design

## Current state

Issue #14は未実装である。Interaction Labにはreview panelのUX prototypeがあり、行からの起票、File/Directory/Project scope、収集済みノート、Codexへの送信状態を確認できる。しかしこれはbrowser-local stateであり、native editor、Rust Git core、AI taskとの契約はまだない。

Clairのfrontend境界は[ADR-0001](../../decisions/0001-adopt-swiftui-appkit-frontend.md)で決定済みである。git panel等の状態駆動UIはSwiftUIに置き、source editorとgutterの高頻度操作はAppKit ownershipを許容する。

## Proposed design

Git review workflowを、repository操作、位置解決、review collection、AI handoffの4責務に分ける。UIは同じcollectionをsource gutter、diff viewer、review panelから操作するが、Git mutationやanchor再解決を直接保持しない。

1. `GitReviewService` がrepository status、diff、blame、stage/unstage/discardをRust core経由で提供する。
2. `ReviewAnchorResolver` がdiff position、source range、revision identityを相互変換し、解決不能なanchorを明示的に返す。
3. `ReviewCollectionStore` がproject context内のコメントとscopeを保持し、表示用のgroupingとAI向けbriefを提供する。
4. `ReviewHandoffCoordinator` がpreview済みbriefを選択されたAI destinationへ渡し、送信結果をcollectionに記録する。

## Components and responsibilities

| Component | Responsibility | Changed interface |
|---|---|---|
| AppKit source editor + gutter | 行/range選択、anchor表示、comment composer起動 | `createReviewComment(anchor, scope)` |
| SwiftUI Git/diff panel | change navigation、mutation confirmation、diff表示 | `GitReviewViewModel` |
| `GitReviewService` | status/diff/blameとGit mutationの非同期実行 | Rust core API |
| `ReviewAnchorResolver` | diff/source offset変換、stale anchorの再解決 | `resolve(anchor, revision)` |
| `ReviewCollectionStore` | コメント、scope、collection metadata、brief serialization | `ReviewCollection` |
| `ReviewHandoffCoordinator` | brief preview、明示送信、destination結果 | `send(collectionID, destination)` |

## Data and control flow

```text
source gutter / diff row
  -> canonical ReviewAnchor + ReviewScope
  -> ReviewCollectionStore
  -> review panel groups and previews notes
  -> ReviewBrief serializer
  -> ReviewHandoffCoordinator
  -> selected AI destination
```

`ReviewAnchor` は最低限、repository identity、`WorktreeID`、repository-relative path、base/head revision identity、side、line/range、必要ならdiff positionを持つ。source rangeとdiff positionが一致しない場合、UIは最後に解決できた表示位置とstale reasonを示す。`WorktreeID`は[ADR-0005](../../decisions/0005-adopt-worktree-first-agent-orchestration.md)に従う所有境界であり、branch名やfile名を代用しない。

## Interfaces and contracts

- Git mutationはtarget path、現在のindex/worktree state、confirmation requirementを返す。UIは失敗時に成功したと表示しない。
- コメントのscopeは `file`、`directory`、`project` のいずれかで、line/range anchorとは独立に保存する。
- Review brief serializerはコメント本文、scope、anchor、worktree/repository context、利用者が明示選択した差分抜粋だけを出力する。送信先agent sessionも同じ`WorktreeID`にattachしていることを検証する。
- AI destinationは送信前previewを必須とする。新規taskか既存terminal sessionかは未決定である。

## State, persistence, and migration

初期の保存先は未決定である。local-onlyで開始する場合でも、将来の共有・syncを阻害しないversioned schemaとstable repository-relative pathを使う。prototypeのbrowser `localStorage` は実装へ移植しない。

## Failure handling and recovery

- stale anchor: 元revision、現在位置、再解決結果、手動で開くfileを表示する。
- diff unavailable: Git errorを表示し、最後に成功した表示を変更操作に使わない。
- destructive mutation: confirmation後も再確認したrepository stateが変化していれば中止し、再読み込みを促す。
- AI handoff failure: collectionを保持し、再送可能にする。送信済みとは記録しない。

## Security and privacy

レビューコメントと差分にはsource codeや機密情報が含まれ得る。AIへ送る内容はpreviewしたbriefに限定し、path、diff、promptを不要なlogへ記録しない。remote syncを導入する場合は別途access/storage設計を要する。

## Observability

anchor resolution failure、Git mutation failure、brief serialization failure、handoff failureを、source内容を含まないdiagnostic eventとして記録する。大きなdiffとanchor再解決はdurationを測定する。

## Test strategy

- Rust/unit: diff position、source offset、rename/deletion、stale anchor、brief serializer。
- integration: stage/unstage/discardとstate refresh、collection persistence、handoff retry。
- UI: gutterからの起票、scope切替、keyboard navigation、brief preview。
- performance: representative large diffでmain thread blockingとinteraction latencyを計測する。

## Options considered

### Option A: 行コメントだけをeditor local stateに置く

- Advantages: 最小の初期実装になる。
- Disadvantages: diffとの相互移動、scope comment、AI collection、stale anchorを表現できない。
- Evidence: Interaction Labでもscopeと集約が主操作であり、単独gutter stateでは要件を満たさない。

### Option B: canonical collectionとanchor resolverを先に分離する

- Advantages: source/diff両方から同じコメントを操作でき、AI handoffの入力が安定する。
- Disadvantages: 初期sliceのdata modelとtest範囲が増える。
- Evidence: Issue #14はdiff、blame、review navigation、edge caseを同時に要求している。

## Decision and rationale

Option Bを提案する。これは新しいaccepted ADRではなく、Issue #14の実装設計案である。AI destinationと共有保存の選択が未決定のため、project statusは`draft`とする。

## Risks and mitigations

| Risk | Impact | Mitigation or exit condition |
|---|---|---|
| diff/source offsetのずれ | 間違った行へコメントを表示する | canonical anchorとfixture-based conversion test |
| large diffの同期処理 | editor操作が停止する | Rust workerで処理し、durationを計測 |
| stale anchor | review文脈を失う | revision identity、再解決、明示的なunresolved UI |
| AIへ過剰なsourceを送る | privacy exposure | previewしたbriefのみを送信 |
| 永続化判断の先送り | local dataの互換性リスク | versioned schemaとmigration/retention decisionを実装開始前に確定 |

## Rollout and rollback

まずlocal-onlyのreview collectionをfeature flag下で提供し、Git mutationを伴わないコメント・brief previewを検証する。Git mutationとAI handoffは独立したsliceで有効化する。問題時はreview panelとhand-offを無効化しても、Git status/diff表示は維持する。

## Documentation impact

- 実装後、Git/Rust coreのarchitecture文書を追加または更新する。
- durableな保存先またはAI destinationの選択をした場合はADRを作成する。
- large diff performanceの再現可能な結果をbenchmarkとして追加する。

## Open questions

READMEのBlocking questionsを参照。
