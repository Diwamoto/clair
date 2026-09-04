# Clair

> エディタ、ターミナル、AIエージェント、Gitを、Project単位のmacOSネイティブワークスペースにまとめるIDE。

Clairは、cceditの後継として開発している個人用のmacOSネイティブIDEです。
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
- rustupで管理された、リポジトリ指定のRust 1.98.0 toolchain
- Rustの`rustfmt`と`clippy`コンポーネント

前提環境は、リポジトリのルートで次のコマンドから確認できます。

```sh
make doctor
```

`make doctor`でfull Xcodeが選択されていないと表示された場合は、環境に合わせて次を実行します。

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Rust componentが不足している場合は、次を実行します。

```sh
rustup component add rustfmt clippy
```

### 開発版を起動する

開発中はDevチャンネルを使います。次のコマンドが、Devアプリを初回ビルド・起動し、
その後はネイティブソースを監視します。

```sh
make run-dev
```

起動後、Projectsサイドバーの **Open Folder** から開きたいローカルフォルダを選びます。
Git repositoryと通常のフォルダを同じProject modelで扱えます。

これはホットリロードではなくホットリスタートです。ソースを変更すると自動でビルドとアプリの再起動を行います。
再起動のたびに通常のアプリ終了が発生するため、
未保存の編集内容と実行中のターミナルセッションは保持されません。必要な内容を保存してから利用してください。
`CLAIR_WATCH_INTERVAL`で監視間隔（秒、デフォルトは1秒）を変更できます。
監視中はコマンドがフォアグラウンドで動作するため、終了するときは`Ctrl-C`を押します。
`make watch-dev`は`make run-dev`の互換エイリアスです。

### StableとDevを同時に起動する

ローカルのStableチャンネルを起動する場合は、次を使います。

```sh
make run-stable
```

StableとDevは別バンドル・別のデータ領域なので、同時に起動できます。

```sh
make run-stable
make run-dev
```

同じチャンネルをもう一度起動した場合は新しいプロセスを増やさず、既存のプロセスを前面に表示します。
ローカルのStable/Devビルドはいずれも署名なしのDebugビルドです。

## よく使う開発コマンド

| コマンド | 内容 |
| --- | --- |
| `make build-dev` | Devアプリをビルドする |
| `make build-stable` | Stableアプリをビルドする |
| `make run-dev` | ネイティブソースを監視し、変更時にDevをビルド・再起動する |
| `make test` | RustとSwiftのテストを実行する |
| `make test-mobile` | iOS/macOS共有のモバイルプロトコルテストを実行する |
| `make lint` | Rust/Swiftのフォーマット、Clippy、Xcode解析、workspace検証を実行する |
| `make smoke` | test、Swift-Rustリンク、bundle、artifactの一連のsmoke checkを実行する |
| `make ci` | `lint`と`smoke`をまとめて実行する |
| `make clean-artifacts` | 破棄可能なビルド成果物だけを削除する |

詳細な手動確認、出力先、復旧方法は[ローカル開発手順](docs/runbooks/local-development.md)にまとめています。

## Native CLI

Rust製の`clair` CLIはRust workspaceからビルドされ、DebugアプリとStable releaseへ同梱されます。
アプリバンドル内では`Clair.app/Contents/Resources/clair`、ソースツリーでは`target/debug/clair`から利用できます。
CLIはSwift側のCommand Registryへ接続する薄いクライアントで、agentの状態と操作権限はClair本体が所有します。

```sh
target/debug/clair --channel dev agent list
target/debug/clair --channel dev agent status <SESSION_ID>
target/debug/clair --channel dev agent input <SESSION_ID> --text $'continue\n' --yes
```

アプリが起動していない場合は、ビルド済みアプリを自動起動します。`--no-launch`で起動せずに確認でき、
`--app PATH`または`CLAIR_APP_PATH`で起動対象を指定できます。

## リポジトリの構成

```text
apple/       SwiftUI/AppKitのmacOSアプリとSwiftテスト
packages/    iOS/macOS共有Swift package（mobile control/host/client）
crates/      Rust core、native CLI、local PTY host
scripts/     build、run、test、smoke用の補助スクリプト
docs/        product、architecture、decision、roadmap、runbook
```

ClairのM1は個人利用を中心とし、macOS専用のdesktopと自所有iPhone/iPad向けのearly mobile controlを対象にします。
Windows/Linux版フロントエンド、team collaboration、VS Code extension互換、third-party plugin marketplace、
hosted agentは対象にしません。Goのlanguage intelligence、debugger、Dev Containerなどは後続roadmapで扱います。

## ドキュメント

- [ドキュメント案内](docs/README.md)
- [製品ビジョン](docs/product/vision.md)
- [製品スコープ](docs/product/scope.md)
- [現在のworkspace architecture](docs/architecture/development-workspace.md)
- [ローカル開発手順](docs/runbooks/local-development.md)
- [Clair v2 roadmap](docs/plans/clair-v2-roadmap.md)
- [PoC feature queue](docs/plans/clair-poc-queue.md)

### リポジトリ内の開発フロー

実装の目的・要件・設計・検証手順は、必要に応じて`docs/projects/`のproject bundleへ残します。
Project bundleを使う作業では、次のproject-local Codex skillを利用できます。

- `$issue-to-project-docs <GitHub issue>` — issueから実装可能なproject文書を作成する
- `$project-implementer <project code>` — 文書化済みprojectを実装・検証する
- `$clair-issue-executor P01`または`$clair-issue-executor next` — PoC queueの一項目を実装する
- `$clair-session-commit` — 完了したsliceを分離・検証してcommitする
