# Implementation plan

## Acceptance mapping

| Acceptance criterion | Implementation slices | Validation |
|---|---|---|
| `AC-01` | Slice 1 | `WorkspaceActivity` unit checks、Dev build、manual navigation |
| `AC-02` | Slice 2 | fake DAP lifecycle tests、Delve manual launch/attach |
| `AC-03` | Slice 2, Slice 3 | DAP request tests、toolbar smoke、manual step/stop |
| `AC-04` | Slice 3 | state/model tests、manual stack/variables/watch/console |
| `AC-05` | Slice 3 | source mapping/gutter tests、manual editor reveal |
| `AC-06` | Slice 4 | isolation/generation/recovery tests、manual abnormal exit |
| `AC-07` | Slice 1–4 | focused XCTest、Dev build、format/static checks |

## Dependencies

- [M1 cutover](../../plans/clair-v2-roadmap.md) のnative Project/editor shell。現行コードで利用可能。
- [M2/#26 Go editor](https://github.com/Diwamoto/clair/issues/26) はdebuggerのhard dependencyではない。DAP source/lineを使うため並行実装できる。
- 利用者のmacOS環境にDelveがあること。無い環境でもfake DAPとUIの自動検証は実行する。

## Slice 1: Native debug destination and Project-scoped shell

### Changes

- `WorkspaceActivity.debug`、navigationCases、title/accessibility/iconを追加する。
- `ProjectSurfaceModel`にdebug session stateの所有点を追加し、Project切替で混線しないようにする。
- Interaction Lab/WorkbenchのDebug screenに対応するsidebar、main header、empty/idle state、console shellを追加する。
- debug screenからstart/stop/clear actionsへ到達できるが、DAPが無い場合も既存workflowを壊さない。

### Validation

- `WorkspaceActivity`のnavigation orderとnavigationEntryのXCTest。
- `ruby scripts/validate-xcode-project.rb`。
- `make test-swift`またはdebug関連のproject-scoped XCTest。
- macOS Dev appでProjectを開き、sidebarの虫アイコンと画面遷移をmanual確認する。

### Completion

- [x] code
- [x] tests
- [x] relevant docs

The native entry point, Project-scoped shell, source reveal, and CodeMirror
breakpoint gutter are complete. The initial DAP transport is present in the
same vertical slice, but its integration evidence is tracked in Slice 2 and is
not considered complete here.

## Slice 2: DAP wire/client and Delve lifecycle

### Changes

- Content-Length framing、JSON request/response/event、sequence correlation、timeout、bounded outputを実装する。
- Delve executable resolver/process adapterを実装し、local loopback DAP接続を確立する。
- initialize、launch、attach、configurationDone、disconnect、process exitをsession stateへ接続する。
- fake DAP server fixtureを追加し、Delve未導入環境でもlifecycleを検証できるようにする。

### Validation

- DAP framing/request/event/error/cancel unit tests。
- fake serverとのlaunch/attach/disconnect integration tests。
- `swift format lint --recursive --parallel --strict apple`。
- Delve導入環境でrepresentative Go programをlaunch/attachするmanual smoke。

### Completion

- [ ] code
- [ ] tests
- [ ] relevant docs

## Slice 3: Breakpoints, execution controls, and inspection UI

### Changes

- sourceごとのbreakpoint、setBreakpoints response、gutter toggleを実装する。
- continue、pause、next、stepIn、stepOut、restart、stopをtoolbarとsession modelへ接続する。
- stopped eventからthreads/stackTrace/scopes/variables/evaluateを取得し、sidebarとconsoleへ表示する。
- source path/line mappingとeditor reveal/selectionをCodeMirror/native editor bridgeへ接続する。

### Validation

- breakpoint/state transition/source mapping tests。
- fake serverでstack/variables/evaluateとstale eventを検証する。
- Dev appでgutter breakpoint、step、frame選択、watch/consoleをmanual確認する。

CodeMirrorのgutter toggleとsource reveal bridgeは実装済み。DAPの実セッション
連携とAppKit native editor fallbackは未完了のため、Slice 3全体は未完了とする。

### Completion

- [ ] code
- [ ] tests
- [ ] relevant docs

## Slice 4: Recovery, isolation, and completion evidence

### Changes

- Project切替、session generation、cancel、Delve異常終了、connection drop、bounded reconnectを仕上げる。
- Project close/app termination時のprocess cleanupを検証する。
- architecture、PoC queue、feature parity matrix、project READMEへ実装結果とevidenceを反映する。

### Validation

- Project isolation、generation guard、malformed frame、timeout、abnormal exit、cleanup tests。
- 関連Swift testsとDev build。
- Delve manual smoke: launch/attach、breakpoint stop、continue/step、stack/variables/console、異常終了。
- `git diff --check` と関連docsのlink確認。

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

- Debug + AI integration (`DebugAgent`)。
- conditional/logpoint、exception breakpoint、reverse debugging。
- CLI/MCP command projectionとdebug configuration persistence。
- Swift/Rustやremote/mobile debugger。
