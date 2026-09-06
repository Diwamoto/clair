# Requirements

## Motivation

レビューの指摘を差分、ソース、作業対象の範囲から切り離さずに収集し、AIへ不足のない文脈として渡したい。ccedit V1のGit/review workflowをClairのnative editorとproject groupに接続する。

## Goals

- working treeとstaged diffをproject単位、かつそのprojectが所有するworktree単位で確認・操作できる。
- 行アンカー付きコメントとfile/directory/project scopeのコメントを同じreview collectionに保持できる。
- 収集したコメントを、対象・位置・本文を失わないreview briefとしてAIへ渡せる。
- large diffや壊れたanchorでUIが停止せず、破壊的Git操作は明示確認できる。

## Non-goals

- 任意Git hosting serviceのpull request review APIを初期実装で再現しない。
- 複数人の同時編集、コメント同期、権限管理を未決定のまま導入しない。
- AIがGit操作を自動実行することは、このprojectの要件に含めない。

## User-visible behavior

- 利用者は変更一覧からdiffを開き、stage、unstage、discardを区別して操作できる。
- source gutterまたはdiff行からコメントを追加できる。コメントにはrepository-relative file、side、lineまたはrangeを表示する。
- コメント作成時にFile、Directory、Projectのscopeを選べる。scopeを変えても行アンカーと元の対象は失われない。
- Review panelは集めたノート数、対象、位置、本文を表示し、不要なノートを削除できる。
- AIへ送る前に生成されるreview briefの対象とコメント数を確認でき、送信後は送信先と結果を表示する。

## Requirements

### Functional

- `FR-01`: active project groupが所有する`WorktreeID`に対応するworking tree、staged state、branch、sync stateを表示する。
- `FR-02`: file changeを選ぶと、変更種別とstaged/unstagedの基準を明示したdiffを表示する。
- `FR-03`: stage、unstage、discardは対象を明示し、discardには確認と失敗時の回復可能な説明を提供する。
- `FR-04`: diff行とsource行の相互移動を、追加・削除・rename・deleted fileを含めて可能な範囲で維持する。
- `FR-05`: review commentは`WorktreeID`、行/range anchor、file、scope、本文、作成時のrevision identityを保持する。
- `FR-06`: File、Directory、Project scopeのコメントを一つのreview collectionへ集約し、対象別に読み返せる。
- `FR-07`: review collectionをAI向けの構造化briefへ変換し、明示的なユーザー操作で送信する。
- `FR-08`: blameを表示する場合、line anchorとrevision情報が現在の表示対象に対応していることを示す。

### Quality attributes

- `QR-01`: 大きなdiffの読込、anchor再解決、Git status更新はUI threadを長時間blockしない。
- `QR-02`: source offset、diff position、UTF-8/UTF-16/graphemeの変換はunit testで検証する。
- `QR-03`: review briefは利用者が入力したコメント、repository path、必要な差分抜粋以外を送信しない。
- `QR-04`: キーボードでコメント追加、review panel移動、送信前確認を操作できる。

## Constraints

- frontendはADR-0001に従い、SwiftUI shellと必要なAppKit high-frequency viewを用いる。
- Git、filesystem、history等のdomain機能はUIに埋め込まずRust core境界の後ろに置く。
- 既存のproject groupが所有する`WorktreeID`とrepository contextをreview collectionの既定contextにする。branch名やfile名だけで異なるworktreeを結合しない。
- AI送信先、永続化範囲、remote syncは未決定であり、実装開始前に決定または明示的にlocal-onlyへ限定する。

## Acceptance criteria

- `AC-01`: active projectのworking treeとstaged changesを明確に区別し、stage/unstage/discardの対象確認とerror stateを確認できる。
- `AC-02`: representative diffでdiff positionからsource lineへ、source lineから対応するdiffへ移動できる。削除行またはrenameでは代替位置または理由を示す。
- `AC-03`: 行コメントとFile/Directory/Project scopeコメントを作成、一覧、削除でき、各コメントのworktree、対象、anchorを確認できる。
- `AC-04`: 少なくとも異なるfileとscopeを含むcollectionをAIへ送る前に、構造化briefの対象・コメント数・本文を確認できる。
- `AC-05`: binary、large diff、rename、deleted file、stale anchorの各状態でUIが安全に失敗し、継続操作または再解決手段を示す。
- `AC-06`: diff/source offset変換、Git mutation、review brief serializerのautomated testがある。

## Out of scope

- hosted code review serviceとの同期、reviewer assignment、notification、approval workflowはfollow-upにする。
- comment threadの共同編集・リアルタイム共有は、storageとaccess modelが決まるまで扱わない。
- AIからの変更適用、commit、pushの自動化はagent/Git approval policyの別projectで扱う。

## Assumptions

- 初期対象はlocal repositoryとClair内のproject groupである。
- Interaction LabはUX方向の証拠であり、native APIや保存形式の決定ではない。

## Open questions

READMEのBlocking questionsを参照。
