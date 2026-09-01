# Clair product scope

## Terminology

- **Project**: Clairが開くlocal folder。Git repositoryでなくてもよい。
- **Workspace**: Projectに保存されたpane/tab/sidebarのlayoutと表示state。
- **Pane**: editor、terminal、diffを混在できるtab group。任意にsplitできる。
- **Agent terminal**: launch profileから起動したClaude Code、Codex、OpenCodeのraw-terminal session。
- **Managed worktree**: Git Projectに対してClairがlocal管理領域へ作る任意のisolated checkout。
- **Command**: UI、CLI、MCPから共通利用するtyped operation。

## ccedit cutover scope

次の項目を満たしたとき、ClairでClairの開発を開始し、cceditを廃止する。

### Native application and Project workspace

- macOS専用のSwiftUI application shellとAppKit high-frequency view。
- 一つのClair processで複数Projectを保持し、Project全体を切り替える。
- Gitの有無を問わずlocal folderをProjectとして開く。
- Projectごとにworkspace、terminal、agent、notification、local settingsを保持する。
- editor、terminal、diffを同じtab groupへ置ける任意split。
- paneのfocus、移動、close、最大化、幅均等、高さ均等、全体均等。
- file tree、search、Git等のsidebarと、paneへ開く補助view。

### Native editor

- 複数file、複数editor pane、file tree、Quick Open、全文検索・置換。
- code editing、multi-cursor、symbol/navigation UIを拡張できるeditor基盤。
- agentによるdisk変更のlive reload。未保存bufferはdisk変更で破棄する。
- file単位のlocal historyと復元。
- branch diff editorとthree-way merge editor。
- Swift/Rustのlanguage intelligenceやintegrated debuggingはcutover条件にしない。

### Terminal and agent workflow

- 通常shellとして使えるGhostty-class terminal surface。
- terminal tab、任意split、focus/navigation、layout復元。
- Claude Code、Codex、OpenCodeをraw terminalとして利用する。
- command palette等からagent type、cwd、managed worktree使用有無を選んで起動する。
- 一つのProject/worktreeで複数terminal、複数agentを許可する。
- Project切替中もterminal/agentはbackgroundで動作する。
- app windowを閉じてもbackground serviceは継続し、明示的なClair終了で停止する。
- update再起動中はPTY/sessionを維持して新processへreattachする。

### Git and worktree workflow

- diff、stage/unstage、commit、branch/worktree作成・切替を組み込む。
- worktreeを使わないagent起動を第一級として扱う。
- managed worktreeはrepository外のClair管理領域へ置く。
- branch reviewはbaseに対する全差分を表示し、commit済みと未commit/untrackedを分ける。
- adoption前にagentまたは利用者によるcommitを要求する。
- review承認後はmerge commitで統合する。
- conflictはnative merge editorまたは対象worktreeのagentで解決する。
- 採用後のworktree/branch削除は個別に確認する。

### Commands, CLI, MCP, and notification

- Command interfaceは[ADR-0007](../decisions/0007-unify-operations-in-a-typed-command-registry.md)に従う。
- すべての操作をtyped Command Registryへ登録する。
- command paletteからaction、Project、file、symbolへ到達できる。
- shortcutは任意commandへユーザーが割り当てる。
- `clair open path:line:column`はpathを所有するopen Projectのactive paneへfileを開く。該当Projectがなければ新規Projectとして開く。
- 起動中Clairを操作するCLIを提供し、後にbackground service操作へ拡張する。
- `clair mcp serve`のstdio adapterでAI向けcommandを公開する。
- command riskは固定metadataとruntime preflightで判定し、必要な承認をClair GUIへ表示する。
- Project badge、Clair内notification history、macOS notificationを提供する。
- Project/terminal単位でnotificationをmuteできる。

### Development and update loop

- Clair StableとClair Devを別bundle ID、別settings領域で並行起動する。
- StableからClair sourceを開き、terminal/agentでDevをbuild・起動し、変更を確認できる。
- GitHub ActionsでStable artifactにClair updater署名を付け、公開GitHub Releaseへ発行する。
  Apple Developer ID signingとnotarizationは、正式な一般配布が必要になるまで後続判断とする。
- cceditと同様にapp内でupdateを表示し、利用者のclickでdownload・reattach・restartする。
- cceditより明確に快適だと利用者が体感できる。

## After cutover

### Go editor support

generic LSP基盤をgoplsで第一級にする。補完、診断、定義ジャンプ、参照検索、rename、code action、format、symbol検索を日常利用可能にする。Swift/Rustを第一級にすることはClair v2の約束に含めない。

### Mobile MVP

- native iPhone/iPad appをprivate TestFlight internal buildとして配布する。
- GitHub Actionsの`main`、manual、30日scheduleでbuildを自動発行する。
- Cloudflare One ClientとCloudflare Tunnel private network routeを初期transportにする。
- MacのQRを使うdevice-key pairingと端末単位のrevokeを行う。
- APNsで内容を秘匿したattention notificationを送る。
- Project/terminal選択、current screenとbounded scrollback、raw terminal入力、registered agent profile起動を提供する。
- Macとmobileの入力はbroker到着順で同じPTYへ適用する。
- mobileにはterminal outputやdiffを永続cacheしない。
- Mac GUIを閉じてもbackground serviceを継続する。
- agent実行中は電源接続時にidle system sleepを標準で防ぎ、battery時の抑止は設定で選べる。

### Debugger

DAPを共通基盤とし、Go/Delveを最初の第一級debuggerにする。Mobile MVPとの実装順序は固定しない。

### Mobile branch review

Mobile MVPの後にbranch全体のdiff reviewとmerge承認を追加する。mobileへfull source editorやnative merge editorを移植することは必須にしない。

### Dev Container

後段で既存`.devcontainer/devcontainer.json`を検出・起動し、container内でeditor、terminal、agentを利用できるようにする。devcontainer作成UIや独自環境定義は対象外とする。

### First-party additions

API tester等はcutover後の密結合first-party機能として追加できる。third-party plugin runtimeや互換性contractは作らない。

## Out of scope

- Windows/Linux frontend。
- VS Code extension、`tasks.json`の互換実行。
- third-party plugin SDK、marketplace。
- team workspace、共同編集、role、organization audit。
- Clair account、設定同期、hosted agent、cloud/VM provisioning。
- mobile full IDE、mobile source editor、汎用remote shellの新規起動。
- Clair独自task runner。build/test/run/lintはterminalまたはagentが実行する。
- agent TUIのscreen scrapingによるsemantic status/approval推測。
- terminal transcriptのsession終了後保存。
