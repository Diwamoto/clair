# Design

## Current state

- `WorkspaceActivity.debug` はnative sidebarの描画対象に入り、Projectごとに
  `DebugSessionModel` が所有されている。
- `ContentView` はdebug sidebar、control toolbar、start card、consoleを表示し、
  `Debugging.swift` は初期のDelve/DAP transportとlaunch/attach、breakpoint store、
  stack/variables/evaluateのstate mappingを持つ。
- CodeMirror editorのgutter callbackとsource path/lineのProject内ファイルへの
  revealはnative接続済み。まだfake-server lifecycle tests、reconnect、AppKit
  native editor fallback parityが残っている。Workbenchは動くUIモックであり、
  DAP/Delveへ接続しない。
- `prototypes/clair-interaction-lab/app/canvas-screens.ts` のDebug artboardと `prototypes/clair-workbench/src/screens/Debug.tsx` は、sidebar、toolbar、source editor、consoleのUIと基本操作を定義している。ただしWorkbenchは動くUIモックであり、DAP/Delveへ接続しない。
- roadmap M3Bは「DAP lifecycle、breakpoint、continue/step、stack、variables、console」をexit criteriaにしている。#27はこのroadmapへ移管されたためclosedであり、完了ではない。
- Swift native control planeとdomain migrationの基準は [ADR-0010](../../decisions/0010-m1-control-plane-swift-with-selective-rust-migration.md) にある。現在のRust C ABIはbootstrap smokeに限定され、debug domainの実装は存在しない。

## Proposed design

### Project-scoped model

`ProjectSurfaceModel` に `DebugSessionModel` を1つ持たせる。session、breakpoint、selected frame、console、source mappingはProject surfaceの寿命に束ね、Project切替で別surfaceのstateを参照しない。workspace snapshotには実行中のDAP stateを保存せず、`workspaceActivity` の `debug` だけを既存のpersisted activityとして扱う。

`DebugSessionModel` はUI向けの状態を `@Published` で公開する。外部プロセスとのIOとrequest correlationは内部の非MainActor transportへ分離し、MainActorでは状態遷移と表示用snapshotの適用だけを行う。

### Delve/DAP boundary

native appがProject rootをworking directoryとしてDelve DAP serverを起動し、local loopbackのDAP connectionを確立する。launchはprogram、args、cwd、environmentをDAP launch argumentsへ変換し、attachはPIDをDAP attach argumentsへ変換する。DelveのpathをPATHまたは明示的なdebug configurationから解決し、Clairからインストールしない。

DAP wire layerはContent-Length framed JSONを扱う小さなtransportとする。request sequenceを内部で採番し、pending requestごとにresponse/errorを相関する。eventはresponseとは独立して受信し、`initialized`、`stopped`、`continued`、`exited`、`terminated`、`output`、`breakpoint` をsession eventへ写像する。

標準requestの初期順序は次のとおりとする。

```text
start Delve -> connect DAP -> initialize
  -> launch/attach -> initialized event
  -> setBreakpoints per source -> configurationDone
  -> stopped/continued events and control requests
  -> disconnect/terminate
```

### Native UI mapping

- `WorkspaceActivity.debug` をnavigationCasesへ追加し、SF Symbolはbug glyphに相当する `ladybug` 系を使う。
- debug sidebarはブレークポイント、call stack、variables/scopesを上から表示する。選択操作は `DebugSessionModel` に渡す。
- main headerはcontinue、next、step in、step out、restart、stopを表示する。現在停止位置はtitlebar/statusのdebug badgeとeditor current-lineで示す。
- main editorは既存のProject editorを再利用し、source path/lineを開く。debug consoleはeditor下部のpaneとして表示し、bounded entriesの末尾を表示する。
- gutter操作は既存のCodeMirror bridgeにdebug breakpoint toggle eventを追加し、native modelへsource/lineを返す。NativeEditor engineを利用する場合は同じcallback contractへ適合させる。
- UIのコピー、spacing、debug blue、danger、panel orderingはInteraction Lab/WorkbenchのDebug screenから取り、DAP stateの無い画面だけをnative側で独自に補わない。

## Components and responsibilities

| Component | Responsibility | Changed interface |
|---|---|---|
| `DebugSessionModel` | Project-scoped lifecycle、breakpoint、stack/variables/consoleの表示state | internal Swift model |
| `DebugDAPClient` | DAP request/response/event、sequence、timeout、cancel | internal async client |
| `DelveProcess` | `dlv dap` processの解決、起動、終了、stderr diagnostics | internal process adapter |
| `ProjectSurfaceModel` | debug modelの所有とProject isolation | `debugSession` |
| `WorkspaceActivity` / `ContentView` | navigationとDebug UIのnative projection | new `.debug` activity and views |
| CodeMirror/native editor bridge | breakpoint gutter、source/line reveal | versioned internal editor message |
| `ClairTests` | wire、lifecycle、UI-facing state、isolationの検証 | new focused XCTest cases |

## Data and control flow

1. 利用者がProjectの「実行とデバッグ」を選ぶと、そのProject surfaceの`DebugSessionModel`を表示する。
2. launch/attachを押すとmodelが設定を検証し、`DelveProcess`を起動する。
3. `DebugDAPClient`がinitializeとlaunch/attachを送信し、受信eventをmodelへ返す。
4. stopped eventではthread/stack/scopesを順に取得し、source mapping後にeditorへfile/line revealを依頼する。
5. gutter変更はmodelのbreakpoint storeを更新し、sessionがrunning/stoppedなら対応sourceのsetBreakpointsを再送する。
6. stop、disconnect、process exit、cancelはいずれもtransportを閉じ、pending requestを失敗させてterminal stateへ遷移する。

## Interfaces and contracts

- DAP payloadはUTF-8 JSON、headerは`Content-Length`を必須とする。最大frame sizeを超える入力は破棄してsessionをfailedへ遷移させる。
- requestのresponseはsequenceで相関し、未相関responseはdiagnosticへ送るがMainActorをクラッシュさせない。
- DAP eventはsession generationに紐づける。古いsessionの遅延eventは現在のProject surfaceへ適用しない。
- source pathはstandardized URLで正規化し、Project root外のpathは表示・open前に拒否する。
- console/outputは件数またはUTF-8 byte数でboundedにし、古いentryからdropする。
- Delveのstderr、DAP error、process exit statusはuser-facing failure messageとdebug diagnosticへ分離する。

## State, persistence, and migration

実行中session、frame、variables、console、breakpoint verificationは永続化しない。`WorkspaceActivity.debug` は既存snapshotの文字列として保存でき、旧snapshotは未知値を`.files`へfallbackする既存挙動を維持する。新しいbreakpoint/configuration persistenceはこのprojectでは追加しないためmigrationは不要である。

## Failure handling and recovery

- Delveが見つからない場合は実行せず、インストール場所/設定を案内する。
- launch/attachが失敗した場合はsessionをfailedへ移し、再試行可能なstart actionを残す。
- DAP framing、JSON decode、timeout、unsupported responseはsessionを安全に停止し、原因をconsoleへ記録する。
- Delveが異常終了した場合は`exited`を表示し、終了後の遅延eventを無視する。
- connection dropは一度だけbounded reconnectを試し、再接続できなければ状態をexited/failedへ戻す。再接続で実行中debug processを二重起動しない。
- Project closeまたはapp terminationではsessionをdisconnectし、process groupを残さない。

## Security and privacy

debuggerはProject root配下のprogramと利用者が指定したPIDだけを対象とする。DAP endpointはloopback/local processだけに限定し、外部ネットワークへ接続しない。environmentはDelveへ渡るため、UIのdiagnosticやconsoleに値を自動表示しない。source/variablesは現在のProject surfaceにのみ表示する。

## Observability

diagnosticにはProject ID、session generation、DAP request name、sequence、duration、終了理由だけを記録し、environment値やsource内容は記録しない。UIのdebug consoleにはDelve stderrとDAP errorを利用者が確認できる形でbounded表示する。

## Test strategy

- unit: Content-Length framing、JSON request encoding、sequence correlation、event decode、source mapping、bounded console。
- session integration: fake DAP serverを使い、initialize/launch/attach、breakpoint、stop/stack/scopes、continue/step、disconnect/errorを検証する。
- native model: Project surfaceごとのstate isolation、generation guard、workspace activity復元を検証する。
- UI-facing: navigationCases、Debug viewのaction routing、gutter breakpoint callbackの契約を既存XCTestの粒度で検証する。
- manual: Delveを導入したmacOSでrepresentative Go programのlaunch/attach、実停止、step、source reveal、異常終了を確認する。

## Options considered

### Option A: Swift-owned local Delve DAP adapter

- Advantages: Swift native control plane、Project lifecycle、既存editor/UIへ直接接続できる。Rust C ABIやCLI/MCPを同時に変更せずにM3Bのnative outcomeへ進める。
- Disadvantages: DAP clientとprocess lifecycleをSwiftで保守する必要があり、将来adapterが増えると抽象化が必要になる。
- Evidence: [ADR-0010](../../decisions/0010-m1-control-plane-swift-with-selective-rust-migration.md) がM1 control planeのSwift ownershipと選択的Rust移行を定めている。

### Option B: Rust coreへDAPを移植し、SwiftへFFIする

- Advantages: 将来front-endが増えた場合にdomainを共有できる可能性がある。
- Disadvantages: 現在のRust C ABIはbootstrap smokeのみで、versioned FFI、lifecycle、threading、cancellation、panic containmentを新設する必要があり、M3Bのnative vertical sliceを遅らせる。debug UIとのstate boundaryも増える。
- Evidence: 現行architectureとADR-0010は、domain migrationを実測と明示的contractがある場合に限定している。debuggerのRust実装は現時点で存在しない。

## Decision and rationale

Option Aをこのprojectの範囲で採用する。DAP adapterは`apple/ClairApp`内のinternal boundaryに留め、CLI/MCPやRust ABIへ広げない。既存のaccepted ADRに従い、まずSwift control planeで利用者が確認できるvertical behaviorを完成させる。別frontendまたは複数debuggerで共有価値が実証された場合だけ、選択的Rust移行を別ADRで判断する。

## Risks and mitigations

| Risk | Impact | Mitigation or exit condition |
|---|---|---|
| Delve CLIの出力/起動方式差 | launchできない | executable resolverとfake serverを分離し、実Delve manual smokeでpinned behaviorを確認する |
| DAP event順序の競合 | stale frameやUI混線 | generation guard、request sequence、Project-scoped modelを使う |
| editor engine差 | gutter breakpointが片方だけ動く | bridge contractを先にテストし、CodeMirror/native editorの両adapterで実装する |
| debug outputの増大 | UI/メモリ劣化 | frame/console/message sizeとtimeoutをboundedにする |
| M2 gopls未完了 | source navigation情報不足 | DAP source path/lineを直接使い、goplsへ依存しない |

## Rollout and rollback

実装後はdebug navigationとsessionをnative Dev buildで先に利用できるようにする。Delveが未導入の環境ではdebug画面自体は表示し、start actionだけを説明付きfailed stateにする。DAP processが不安定な場合はsessionをstopして既存editor/terminal/Git workflowへ影響を波及させない。workspace snapshot schemaは変更しないためrollbackで旧buildがactivity値を`.files`へfallbackできる。

## Documentation impact

- このproject完了時に `docs/architecture/development-workspace.md` のdebug boundary/lifecycleを更新する。
- [PoC queue](../../plans/clair-poc-queue.md) のM3B mappingと実装状態を更新する。
- [feature parity matrix](../../benchmarks/feature-parity-matrix.md) は自動/手動evidenceを追記する。
- 新しいcross-project decisionが発生した場合のみADRを追加し、既存ADRを改変しない。

## Open questions

None.
