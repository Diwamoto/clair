# Requirements

## Motivation

`prototypes/clair-interaction-lab` と `prototypes/clair-workbench` には「実行とデバッグ」画面とサイドバー入口が既に定義されているが、現行のネイティブ `ClairApp` は `files`、`git`、`activity` だけをナビゲーションに表示する。GitHub issue #27 はroadmapへ移管された後に閉じられ、実装完了を意味していない。デザインとネイティブ実装の差を解消し、Go開発で使えるdebuggerを提供する。

## Goals

- ネイティブmacOSワークスペースにProject単位の「実行とデバッグ」ナビゲーションを追加する。
- Go/DelveをDAP経由でlaunchまたはattachできるようにする。
- ブレークポイント、continue/pause、step over/into/out、restart、stopを提供する。
- call stack、scopes/variables、watch/evaluate、debug consoleを表示・操作できるようにする。
-停止位置からソースを開き、editorのgutterでブレークポイントを追加・削除できるようにする。
- Project切替、異常終了、再接続、キャンセル時にdebug stateを安全に扱う。
- DAP lifecycle、source mapping、Project isolationを自動テストで検証する。

## Non-goals

- Swift/Rustの第一級debugger対応。必要になった場合は別projectとする。
- mobile debugger、remote debugger、public relay、team debugging。
- generic LSP/goplsの実装。これはroadmap M2/#26の責務とする。
- Debug + AI統合。Workbenchの `DebugAgent` は検討中の別画面であり、このprojectでは実装しない。
- CLI/MCPからdebug sessionを操作するcommand surface。まずnative UIのvertical sliceを完成させ、別projectで共通Command化を判断する。
- 任意のthird-party debugger adapter runtimeやVS Code launch.json互換。

## User-visible behavior

- sidebarに虫アイコンの「実行とデバッグ」が表示され、Projectを開いた状態で選択できる。
- debug画面にはブレークポイント、call stack、変数のsidebar、実行制御toolbar、source editor、debug consoleが表示される。
- launch設定ではProject root、実行対象、引数、環境変数、stop-on-entryを指定できる。attachではPIDを指定できる。
- gutterクリックで現在のsource file/lineにブレークポイントを切り替えられる。
-停止イベントで現在行、frame、variables、consoleが更新され、frame選択でsource editorが該当位置へ移動する。
- Delve未導入、設定不備、プロセス異常終了、DAPエラーは、画面を壊さず利用者向けの説明として表示される。
- Projectを切り替えても、別Projectのsession、breakpoint、停止位置、consoleが混線しない。

## Requirements

### Functional

- `FR-01`: Project-scoped debug sessionをidle、launching、running、stopped、terminating、exited、failedの状態で管理する。
- `FR-02`: DAP initialize/configurationDone/launchまたはattach/disconnect lifecycleをDelveと完了できる。
- `FR-03`: sourceごとのline breakpointをset/clearし、verified/unverified状態を表示する。
- `FR-04`: continue、pause、next、stepIn、stepOut、restart、stopをDAP requestへ変換する。
- `FR-05`: stopped eventからthread、stack frame、scope、variableを取得し、選択可能な形で表示する。
- `FR-06`: evaluate requestによるwatch/debug consoleを実行し、結果またはDAP errorを表示する。
- `FR-07`: Delveのsource pathとProject rootを安全に対応づけ、停止位置からnative editorへ移動する。
- `FR-08`: DAP messageの順序、request/response相関、bounded output、disconnect/cancelを実装する。
- `FR-09`: debug navigationとstateをProjectごとに分離し、workspace再起動時に壊れたdebug stateを復元しない。

### Quality attributes

- `QR-01`: DAP受信データはサイズ上限を持ち、未処理のconsole/outputを無制限に保持しない。
- `QR-02`: DAP readerが応答を待つ間もMainActorをブロックせず、停止・終了・キャンセルがUIに戻る。
- `QR-03`: process終了、malformed message、request timeout、未対応capabilityを明示的な状態へ遷移させる。
- `QR-04`: UIは既存のWorkspaceChromeのdebug color/tokenとInteraction Labの画面構成に合わせる。
- `QR-05`: Project切替とsession lifecycleのintegration testが再現可能である。

## Constraints

- macOS native targetはSwiftUI/AppKitで構成し、control plane ownershipは [ADR-0010](../../decisions/0010-m1-control-plane-swift-with-selective-rust-migration.md) に従う。
- DelveはProject環境またはPATHから解決する外部実行ファイルで、Clairが自動インストールや外部送信を行わない。
- debug adapterとの通信はlocal process/loopbackに限定し、任意のremote endpointへ接続しない。
- 現行の未コミット変更はユーザー所有であり、実装では上書きしない。
- native UIは既存のProjectSurfaceModelとProjectWorkspaceModelのProject isolationを再利用する。

## Acceptance criteria

- `AC-01`: Projectを開いたときsidebarから「実行とデバッグ」を選択でき、debug panel/main/statusが表示される。
- `AC-02`: representative Go programをlaunchおよびattachし、DAP initializeからconfigurationDoneまで完了できる。
- `AC-03`: breakpointで停止し、continue/pause/step over/into/out/restart/stopを操作できる。
- `AC-04`: stopped stateでcall stack、variables/scopes、watch/evaluate、debug consoleをnative UIから確認できる。
- `AC-05`: source mappingにより停止位置とframe選択がProject内のeditor file/lineへ移動し、gutter breakpointが同期する。
- `AC-06`: Project切替、DAP error、Delve異常終了、cancel、reconnectで別Projectのstateを壊さず、回復可能な説明を表示する。
- `AC-07`: DAP wire/client、session lifecycle、state isolation、navigation、source mappingに自動テストがあり、macOS Dev buildと関連XCTestが通る。

## Out of scope

- ccedit V1のdebugger parity測定。feature parity matrixはM3Bのverification anchorとして残し、final benchmarkとは分離する。
- debug stateのプロセス再起動後永続化。workspace activityの選択だけを保存し、実行中processやframeを復元しない。
- user-defined conditional/logpoint、exception breakpoint、reverse debugging。必要性が明らかになった場合のfollow-upとする。

## Assumptions

- DelveのDAP serverはローカルで起動でき、Go programのlaunch/attachに必要な標準DAP requestを提供する。
- M2のgoplsが未完了でもdebuggerのsource/line navigationはabsolute/Project-relative pathを中心に動作する。
- 既存editor bridgeにline selection/navigationを追加できる。

## Open questions

None.
