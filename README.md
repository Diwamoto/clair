# Clair

[English version here](README_en.md)

> エディタ、ターミナル、AIエージェント、Gitを、Project単位のmacOSネイティブワークスペースにまとめるIDE。

Clairは、個人で開発しているmacOSネイティブIDEです。
VS Codeのような編集・検索・Gitの統合体験と、Ghosttyのような使い慣れたターミナル操作を、
別々のアプリを行き来せずに一つのProject workspaceで扱えるようにします。

一つのClairプロセスで複数のProjectを開き、Projectごとにファイルツリー、エディタ、ターミナル、
エージェント、Git状態、ペイン構成を切り替えられることが中心設計です。AIエージェントは専用の
チャットUIに閉じ込めず、Claude Code、Codex、OpenCodeなどを通常のターミナルとして起動します。

現在は開発中のPoC・統合フェーズです。主要なローカル開発機能は実装済みですが、Clair自身を
Clairで開発する最終的なdogfood cutoverと、UIの統合・磨き込みは継続中です。

## 何を実現しているか

| 領域 | Clairでできること |
| --- | --- |
| Project workspace | Git repositoryかどうかを問わずローカルフォルダをProjectとして開き、複数Projectを切り替える。Projectごとのファイルツリー、タブ、ペイン構成を保持する。 |
| Native editor | 複数ファイルの編集、Unicode/IME入力、保存、Undo/Redo、外部変更の反映、ローカル履歴の復元を行う。Quick Open、全文検索、置換にも対応する。 |
| Terminal / agent | macOSネイティブのターミナルでshellを動かし、CJK/IME、resize、scrollback、selectionを扱う。Claude Code、Codex、OpenCodeをProject rootまたはmanaged worktreeで複数起動できる。 |
| Mobile agent control | 自所有Mac上のregistered agentをiPhone/iPadから確認・raw inputできる初期vertical sliceを、private networkとprivate TestFlight向けに実装する。 |
| Git / review | `status`、`diff`、`stage/unstage`、`commit`、`branch switch`をProject単位で扱う。必要に応じてmanaged worktreeを作成し、branch全体のreviewと採用までつなげる。 |
| Command automation | Command Window、menu、keyboard shortcut、ローカルCLI、stdio MCPが同じtyped commandを実行する。操作のriskと利用可否はClair側で判定する。 |
| Lifecycle | StableとDevを別bundle・別データ領域で並行起動できる。window closeや更新再起動をまたいで、実行中のlocal terminal sessionへ再接続できる。 |

## ローカルで起動する

### 必要な環境

- macOS 14.0以降
- full Xcode 16以降（Command Line Toolsではなく、Xcode本体が選択されていること）

```sh
make doctor
```

### 起動する

```sh
make dev       # macOSアプリをビルドして起動する（Swift変更で自動再ビルド＆再起動、Ctrl-Cで停止）
make dev-ios   # iOS Simulatorで起動する
```

起動後、Projectsサイドバーの **Open Folder** から開きたいローカルフォルダを選びます。

## よく使う開発コマンド

| コマンド | 内容 |
| --- | --- |
| `make test` | 高速なcore/appユニットテストを実行する |
| `make test-integration` | 実subprocess/PTY/daemonの遅いテストを実行する |
| `make foundation` | package graph検証、全build、全テストを実行する |
| `make lint` | Swiftのフォーマットを検査する |
| `make ci` | `lint`、`foundation`、iOS Simulator buildをまとめて実行する |

詳細な手動確認、出力先、復旧方法は[ローカル開発手順](docs/runbooks/clair-verification.md)にまとめています。

## リポジトリの構成

```text
apple/       iOSアプリ(ClairMobile)とそのテスト
packages/    Swift package(ClairCore、ClairApps)
scripts/     build、run、test用の補助スクリプト
docs/        仕様、タスク、architecture、decision、runbook
```

ClairのM1は個人利用を中心とし、macOS専用のdesktopと自所有iPhone/iPad向けのearly mobile controlを対象にします。
Windows/Linux版フロントエンド、team collaboration、VS Code extension互換、third-party plugin marketplace、
hosted agentは対象にしません。Goのlanguage intelligence、debugger、Dev Containerなどは後続roadmapで扱います。

## ドキュメント

- [仕様(正本)](docs/clair-spec.md)
- [タスク一覧](docs/clair-tasks.md) / [カンバン](docs/clair-kanban.html)
- [ドキュメント案内](docs/README.md)
- [現在のworkspace architecture](docs/architecture/development-workspace.md)
- [ローカル検証手順](docs/runbooks/clair-verification.md)

### 開発の進め方

開発は[タスク一覧](docs/clair-tasks.md)をキューとして、AIエージェント用skill `/clair-task`
(`.agents/skills/clair-task/`)で一件ずつ進めています。仕様は[`docs/clair-spec.md`](docs/clair-spec.md)を正本とし、
各タスクの結果・計測・残課題はタスク一覧の行に記録して、[カンバン](docs/clair-kanban.html)を再生成します。

## コントリビューション

個人プロジェクトですが、バグ報告やバグ修正のPull Requestは歓迎です。
大きな機能追加は、先にIssueで相談してもらえると助かります。

## セキュリティ

脆弱性の報告方法は[SECURITY.md](SECURITY.md)を参照してください。

## ライセンス

[MIT](LICENSE)。第三者コンポーネントは[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)に記載しています。
