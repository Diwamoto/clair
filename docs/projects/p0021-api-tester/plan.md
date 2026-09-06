# Implementation plan

## Acceptance mapping

| Acceptance criterion | Implementation slices | Validation |
|---|---|---|
| `AC-01` | Slice 1 | activity bar / command windowから開いて一覧とeditorを確認 |
| `AC-02` | Slice 2 | request選択、全field編集、Save、再選択をmanual check |
| `AC-03` | Slice 1, Slice 3 | CRUDとproject group切替でcollection分離をmanual check、reloadで復元 |
| `AC-04` | Slice 2 | curl previewとCopy操作、builder unit check |
| `AC-05` | Slice 3 | Send後のmock status、elapsed、headers、bodyをmanual check |
| `AC-06` | Slice 4 | docs reviewで未決境界とout-of-scopeの存在を確認 |

## Dependencies

- 既存Interaction Labのproject group、activity bar、command window state。
- [ADR-0001](../../decisions/0001-adopt-swiftui-appkit-frontend.md)のnative frontend方針。
- 実HTTP実行、secret保護、native persistenceの追加決定はmockの完了には不要だがnative実装の依存となる。

## Slice 1: API Tester view and project-scoped collection

### Changes

- `MainView`へAPI Tester viewを追加し、activity barとcommand windowから開けるようにする。
- project groupごとのrequest collection、selected request、empty stateを追加する。
- 新規、複製、削除、request選択のUIを既存sidebar densityで実装する。

### Validation

- API Testerを2つの入口から開けることをmanual check。
- project groupを切り替え、collectionが混線しないことをmanual check。
- `npm run build`。

### Completion

- [ ] code
- [ ] tests
- [ ] relevant docs

## Slice 2: Request editor and curl preview

### Changes

- method、URL、query、headers、bodyを編集・保存できるeditorを追加する。
- `buildCurl`とshell escapingを実装し、現在のdraftと同期したpreviewを表示する。
- Copy curlとclipboard failure noticeを追加する。
- localStorageのversioned state、normalization、safe fallbackを追加する。

### Validation

- 各request fieldが保存・再選択後に復元されることをmanual check。
- query/header/bodyを含むcurlがpreviewと一致することをunit/component check。
- malformed storageで既存workspace stateを壊さずempty stateになることをmanual check。
- `npm run build` と `git diff --check`。

### Completion

- [ ] code
- [ ] tests
- [ ] relevant docs

## Slice 3: Mock send and response inspector

### Changes

- 外部networkを呼ばないmock executorを追加する。
- status、elapsed、response headers、body、`MOCK RESPONSE`表示を追加する。
- invalid URL / mock error、request deletion後のselection、project切替時のresponse resetを扱う。

### Validation

- GET/POST相当のsample requestでSend結果を確認。
- responseのstatus、elapsed、headers、bodyが表示されることをmanual check。
- invalid URL、empty collection、project switchをmanual check。
- `npm run build`、`npm run lint`、`git diff --check`。

### Completion

- [ ] code
- [ ] tests
- [ ] relevant docs

## Slice 4: Native handoff and release verification

### Changes

- mock-onlyの制約とnative未決事項がdocsへ反映されていることを確認する。
- private Sites previewへ公開し、既存workspaceの主要操作に回帰がないことを確認する。

### Validation

- desktop viewportで既存のworkspace、Search、Git、Agents、Debug、Historyを開いて回帰確認。
- `npm run build`、`npm run lint`、`git diff --check`、HTTP 200。
- 公開後のstable URLでAPI TesterのCRUD、curl preview、mock responseを再確認。

### Completion

- [ ] code
- [ ] tests
- [ ] relevant docs

## Final verification

- [ ] 全acceptance criteriaにvalidation evidenceがある
- [ ] relevant test、build、format、static checkが通る
- [ ] regressionまたは既知制約が記録されている
- [ ] architectureとrunbookが実装を表している
- [ ] unrelated diffがない

## Deferred follow-ups

- native HTTP executionとpermission / timeout / cancellation policy。
- Keychainを含むsecret保護とenvironment variable model。
- OpenAPI import、assertion、request chain、team collection sync。
