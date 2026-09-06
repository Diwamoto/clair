# Design

## Current state

Interaction Labは、project group、activity bar、command window、source control、terminalを一つのcompact workspaceとして持つ。API Testerの専用view、request persistence、curl preview、response surfaceはまだない。[app/page.tsx](../../../prototypes/clair-interaction-lab/app/page.tsx)がモックの状態とUIを集約している。

native ClairではUIはSwiftUI shell + 必要なAppKit view、Gitやfilesystem等のdomainはRust coreに置く方針である。[ADR-0001](../../decisions/0001-adopt-swiftui-appkit-frontend.md)はこのprojectのfrontend境界と矛盾しないが、実HTTP実行の配置は決めていない。

## Proposed design

API Testerをactivity barの独立したfirst-class viewとして追加する。左にproject-scoped request collection、中央にrequest editor、下または右にcurl previewとresponse inspectorを配置し、既存のeditor/tab rowを増やさない。

モックでは次の操作モデルを採用する。

- requestは`id`、`name`、`method`、`url`、`query[]`、`headers[]`、`body`、`updatedAt`を持つ。
- collectionは`Record<projectGroupId, ApiRequest[]>`として保存し、既存project groupと同じidで分離する。
- query/headerの空行はcurl生成時に除外し、値はshell argumentとして安全にsingle-quote escapeする。
- Sendは外部networkを呼ばず、method/statusに応じたfixture responseを返す。画面には`MOCK RESPONSE`と明示する。
- requestの編集とresponseの表示を同じworkspaceの中で完結させ、Terminalへcurlを手入力する必要をなくす。

## Components and responsibilities

| Component | Responsibility | Changed interface |
|---|---|---|
| Activity bar API Tester button | viewを開く、未保存request countを示す | `mainView = api-tester` |
| API Tester sidebar | project-scoped collectionの一覧、新規・複製・削除、選択 | `ApiRequest[]` selection callbacks |
| Request editor | method、URL、query、headers、bodyの編集と保存 | `ApiRequestDraft` |
| Curl preview | request draftからcommandを生成・copy | `buildCurl(request)` |
| Response inspector | mock send結果のstatus、elapsed、headers、body表示 | `ApiResponse` |
| localStorage adapter | schema parse、migration/fallback、project分離 | `clair-api-tester-v1` |

## Data and control flow

1. API Testerを開くとactive project group idでcollectionを選び、selected requestを復元する。
2. Editorの変更はdraft stateに入り、Saveでselected collectionへ反映してlocalStorageへ書き込む。
3. `buildCurl`はdraftのmethod、URL、query、headers、bodyを読み、previewを更新する。
4. Sendは保存または現在のdraftをfixture executorへ渡し、mock responseをinspectorへ表示する。
5. project group切替では同じviewを維持し、collectionだけを切り替える。存在しないprojectには空collectionを用意する。

## Interfaces and contracts

モック内の暫定型は次の契約を持つ。

```text
ApiRequest = {
  id: string,
  name: string,
  method: GET | POST | PUT | PATCH | DELETE,
  url: string,
  query: { key: string, value: string, enabled: boolean }[],
  headers: { key: string, value: string, enabled: boolean }[],
  body: string,
  updatedAt: string
}

ApiResponse = {
  status: number,
  elapsedMs: number,
  headers: { key: string, value: string }[],
  body: string,
  isMock: true
}
```

`buildCurl`は同じ入力に対し同じcommandを返す。無効なURLでもeditorは落とさず、Send時にmock error responseを表示する。Copyに失敗した場合はUIでnoticeを出し、request stateは変更しない。

## State, persistence, and migration

モックの保存keyは`clair-api-tester-v1`とし、project idごとにcollectionを格納する。読み込み時は配列、field type、methodの許容値を検証し、不正なentryだけを除外する。key全体が壊れている場合は空collectionへfallbackし、既存の`clair-project-groups`等を削除しない。将来schemaを変更する場合はversioned keyまたは明示的なmigrationを追加する。

native persistence、secretのKeychain連携、collection共有は未決であり、このmockのlocalStorage形式をnative compatibility contractとはみなさない。

## Failure handling and recovery

- malformed localStorage: API Testerだけを空状態で起動し、保存時に新しいvalid stateを書き込む。
- invalid URL: editor入力を保持し、Send時に`400 Mock Request Error`をresponse inspectorへ表示する。
- clipboard unavailable: `Copy failed` noticeを表示し、curl textは画面に残す。
- delete: selected requestを削除し、隣接requestまたはempty stateへ選択を移す。
- project switch: active projectにrequestがなければempty stateを表示し、直前projectのdraftを表示しない。

## Security and privacy

モックのSendは外部networkへ送信しない。入力したAuthorizationなどの値はlocalStorageに平文で保存され得るため、UIに「local-only mock」表示を置き、real secretを入力しないよう明記する。nativeで同じ保存形式や実行経路を採用する決定ではない。

## Observability

response inspectorにmock statusとelapsedを表示する。mockでは外部ログやtelemetryを追加しない。native版では実行先、secret redaction、network error、timeoutの可観測性をexecution boundaryの決定と合わせて設計する。

## Test strategy

- unit: curl生成、shell escape、query/header除外、invalid persistence normalization。
- component: request選択、編集、保存、複製、削除、project切替。
- manual: activity bar / command window、curl copy、Send response、狭いdesktop viewport、既存workspace viewへの回帰。
- native follow-up: HTTP execution、Keychain、timeout/cancellation、redaction、Rust/Swift boundaryのintegration test。

## Options considered

### Option A: Terminalだけでcurlを入力する

- Advantages: 新しい保存形式やUIが不要。
- Disadvantages: requestの再利用性、編集性、responseの構造化表示が弱く、API Testerの目的を満たさない。
- Evidence: issue #21は保存・編集・curl確認・response表示を要求している。

### Option B: 外部APIへ実HTTP requestを送るmock

- Advantages: 実際のAPI結果に近い体験を検証できる。
- Disadvantages: secret漏洩、CORS、ネットワーク許可、再現性をモックの初期sliceへ持ち込む。native execution boundaryも未決である。
- Evidence: issue #21はInteraction Labでmock responseを要求し、secret / execution boundaryを未決事項としている。

## Decision and rationale

既存workspaceへproject-scoped collectionとcompact request/response surfaceを追加し、Interaction Labでは外部networkなしのmock executorを使う。これはユーザーが保存→curl確認→send結果確認の一連の価値を安全かつ再現可能に評価でき、nativeの不可逆なsecurity・network設計を先送りできるためである。

## Risks and mitigations

| Risk | Impact | Mitigation or exit condition |
|---|---|---|
| request editorが既存のdense UIから浮く | API Testerだけdashboard的になる | 既存sidebar、quiet border、One Dark surfaceを再利用し、responsive manual checkを行う |
| localStorageの平文secretを実運用と誤認する | credential exposure | mock-only表示、docsの明記、nativeではKeychain / boundaryを別決定 |
| project switchでcollectionが混線する | 誤ったAPIを送る | project id keyed stateと切替manual testを必須にする |
| curl escapeが不正で再利用できない | request reproduction failure | curl builder unit testとvisible previewを追加する |

## Rollout and rollback

モックは既存 private Sites projectへ一度に公開する。localStorage keyは既存keyと分離し、問題があればAPI Tester viewを開かず既存workspaceへ戻せる。API Tester stateの削除は専用keyだけを対象にする。

## Documentation impact

- 本project bundleをsource of truthとして更新する。
- nativeのsecret、persistence、execution boundaryが決まった時は新しいADRまたは関連architecture/runbookを追加する。
- mockの画面・操作はInteraction Labの`app/page.tsx`をevidenceとして維持する。

## Open questions

READMEのBlocking questionsを参照。
