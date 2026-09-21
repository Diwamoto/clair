# Clair

> エディタ、ターミナル、AIエージェント、Gitを、Project単位のmacOSネイティブワークスペースにまとめるIDE。

Clairは、cceditの後継として(cceditは2026-09-21に廃止、復元はarchive tagから)開発している個人用のmacOSネイティブIDEです。
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
make dev       # macOSアプリをビルドして起動する（Ctrl-Cで停止）
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

### リポジトリ内の開発フロー

実装の目的・要件・設計・検証手順は、必要に応じて`docs/projects/`のproject bundleへ残します。
Project bundleを使う作業では、次のproject-local Codex skillを利用できます。

- `$issue-to-project-docs <GitHub issue>` — issueから実装可能なproject文書を作成する
- `$project-implementer <project code>` — 文書化済みprojectを実装・検証する
- `$clair-issue-executor P01`または`$clair-issue-executor next` — PoC queueの一項目を実装する
- `$clair-session-commit` — 完了したsliceを分離・検証してcommitする
