# Requirements

## Motivation

API開発中に同じリクエストを何度も組み立て直さず、Clairのプロジェクト文脈から保存・再実行したい。Postmanのような専用コレクションを大きく導入せず、まずはcurlへ落ちる小さな操作面を提供する。

## Goals

- API requestのmethod、URL、query、headers、bodyをプロジェクト単位で保存・編集できる。
- 現在の入力から再現可能なcurlを生成し、実行前に確認・コピーできる。
- Send後にstatus、elapsed、response headers/bodyを確認できる。
- 既存のOne Dark、compact sidebar、project groupの文脈に自然に追加する。

## Non-goals

- OAuth、cookie jar、environment secret、team sharing、collection syncを初期スコープで提供しない。
- assertion、runner、scheduled request、複数リクエストのworkflowをこのprojectに含めない。
- ネイティブ実装のsecret保管と実HTTP権限境界を、未決のまま暗黙に確定しない。

## User-visible behavior

- 利用者はactivity barまたはcommand windowからAPI Testerを開ける。
- サイドバーで保存済みrequestを選び、新規作成・複製・削除ができる。
- method、URL、query parameter、header、raw bodyを編集し、Saveで保存できる。
- Requestを送る前にcurl previewを展開し、Copy curlでクリップボードへコピーできる。
- Sendでモックのresponseを生成し、status badge、経過時間、response headers、bodyを表示できる。
- project groupを切り替えると、そのprojectのrequest collectionだけが表示される。

## Requirements

### Functional

- `FR-01`: API Testerはactive project groupをcontextとしてrequest collectionを表示する。
- `FR-02`: requestはmethod、URL、query、headers、body、保存名を編集できる。
- `FR-03`: requestの新規作成、複製、削除、保存、選択切替ができる。
- `FR-04`: request stateからqueryとheadersを含むcurl commandを決定的に生成する。
- `FR-05`: curlを画面上で確認し、明示操作でコピーできる。
- `FR-06`: Send操作はmock responseを返し、status、elapsed、headers、bodyを表示する。
- `FR-07`: collection stateはproject idで分離され、browser-local persistenceから復元できる。
- `FR-08`: native implementationへ引き継ぐsecret、persistence、execution boundaryの未決事項をdocsに残す。

### Quality attributes

- `QR-01`: 保存・切替・編集操作は既存のworkspace stateを壊さず、狭いdesktop viewportでもrequest editorが操作可能である。
- `QR-02`: curl previewはmethod、URL、query、headers、bodyの現在値と一致する。
- `QR-03`: userが入力したheaderやbodyをmock以外の外部送信へ暗黙に流さず、実HTTP実行の有無をUIで明示する。
- `QR-04`: 既存localStorageが壊れていてもAPI Tester以外のproject/session stateを巻き戻さず、初期collectionへ安全にfallbackする。

## Constraints

- Interaction Labは既存のOne Dark / ccedit baselineを拡張し、generic dashboardへ置き換えない。
- project groupが持つrepository contextとactive group selectionを既定のscopeにする。
- モックでは外部ネットワークを呼ばず、localStorageと決め打ちのresponse fixtureだけを使う。
- native frontendは[ADR-0001](../../decisions/0001-adopt-swiftui-appkit-frontend.md)のSwiftUI shell + AppKit high-frequency view方針に従う。

## Acceptance criteria

- `AC-01`: API Testerをactivity barまたはcommand windowから開き、保存済みrequest一覧とeditorを表示できる。
- `AC-02`: method、URL、query、headers、bodyを編集して保存し、request選択を切り替えても保存値を復元できる。
- `AC-03`: 新規・複製・削除が動作し、project group切替後は別projectのcollectionと混線しない。
- `AC-04`: 現在の入力から生成したcurlを表示し、Copy操作で同じcommandをclipboardへ渡せる。
- `AC-05`: Send操作後にmock responseのstatus、elapsed、response headers、bodyを表示できる。
- `AC-06`: native実装で未決のsecret / persistence / execution boundaryと、初期スコープ外の機能が文書化されている。

## Out of scope

- 実HTTP clientの認証、証明書、proxy、redirect、timeout policyはnative execution boundaryの決定後に別projectで扱う。
- API schema import、OpenAPI生成、assertion、request chaining、team collectionはfollow-upにする。
- Issue #21のscopeにないproduction Swift/Rust implementationはこのmock sliceでは変更しない。

## Assumptions

- 初期利用者は一人で、collectionはbrowser-localまたはnative local workspaceに限定できる。
- curlは最初のportable representationとして十分であり、request editorの主要価値を評価できる。
- モックのresponseはUI評価用であり、外部APIの結果や性能を表さない。

## Open questions

READMEのBlocking questionsを参照。
