<div align="center">

<img src="packages/ClairApps/Sources/ClairMacApp/Resources/AppIcon.png" width="128" alt="Clair">

# Clair

**エディタ、ターミナル、AI エージェント、Git を、Project ごとの macOS ネイティブ workspace に。**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)
![Swift](https://img.shields.io/badge/Swift-6-orange.svg)
[![Release](https://img.shields.io/github/v/release/Diwamoto/clair)](https://github.com/Diwamoto/clair/releases/latest)

[English](README_en.md)

</div>

<!-- screenshot: docs/images/workspace.png — editor + terminal で agent が動いている全体像(hero) -->

Clair は、エディタとターミナルと AI エージェントを行き来する毎日の開発を、
**ひとつの Project workspace** にまとめる macOS ネイティブ IDE です。
VS Code のような編集・検索・Git の統合と、Ghostty のターミナルを、
Electron も WebView も使わずに Swift で組み上げています。

AI エージェントは専用チャット UI に閉じ込めません。Claude Code、Codex、OpenCode を
**普通のターミナル**として起動し、そのまま並べて、切り替えて、iPhone から様子を見られます。

> [!NOTE]
> 個人開発中のプロジェクトです。日常の開発に必要な機能は揃っていますが、UI の磨き込みは続いています。

## インストール

Apple Silicon の Mac で、ターミナルに 1 行貼るだけです。

```sh
curl -fsSL https://raw.githubusercontent.com/Diwamoto/clair/main/scripts/install.sh | sh
```

最新の Release を取得してチェックサムを確かめ、`/Applications/Clair.app` に置いて起動します。
以降の更新はアプリ内に通知され、クリックひとつで適用されます(署名検証つき、開いているターミナルは切れません)。

## 特徴

### ⚡ ネイティブで速いエディタ

<!-- screenshot: docs/images/editor.png — syntax highlight・診断・補完 popup -->

- rope ベースのバッファで 10 MiB 級のファイルも一瞬で開いて編集
- 日本語 IME、絵文字、マルチカーソル、矩形選択、折りたたみ、折り返し
- tree-sitter による syntax highlight(Go、TypeScript/JavaScript、Python、Rust、Swift、Ruby、PHP、Java、Terraform、Shell、JSON、Markdown)
- 言語サーバー連携: 診断、補完、⌘+click / F12 で定義へ移動、参照検索、シンボル検索、⌃- で戻る
- Markdown のライブプレビュー(⌘⇧V)、行ごとの git blame

### 🖥️ Ghostty のターミナル

<!-- screenshot: docs/images/terminal.png — 分割したペインで複数の agent が動いている様子 -->

- [libghostty](https://github.com/ghostty-org/ghostty) による GPU 描画のターミナル
- ペインを自由に分割・移動・最大化。editor / terminal / preview / commit graph を同じ画面に
- shell は常駐 daemon が持つので、ウィンドウを閉じてもアップデートで再起動しても、作業中のセッションはそのまま

### 🤖 AI エージェントをターミナルのまま

- Claude Code / Codex / OpenCode を Project root や専用 worktree で並べて起動
- エージェントの完了・通知要求を拾って macOS 通知、Project ごとのバッジ
- 「このファイルをレビュー」「この Project をレビュー」をワンクリックで依頼
- エージェントの会話履歴を provider ごとに一覧、使用状況を日別に集計

### 🌿 Git と worktree

<!-- screenshot: docs/images/git.png — 変更一覧・diff・commit graph -->

- 変更一覧、stage / unstage、commit、pull / push、ブランチ切り替え
- 行単位のレビューコメントと、エージェントからの修正提案の適用 / 却下
- commit graph で branch と merge を辿り、commit からそのまま diff へ
- 管理 worktree を作って別ブランチで並行作業し、merge commit で取り込み

### 🔌 すべての操作をコマンドに

- メニュー、⌘K のコマンドパレット、ショートカット、`clair` CLI、MCP が同じ型付きコマンドを実行
- ショートカットは任意のコマンドに割り当て可能
- エージェントから Clair を操作するときも、危険度に応じて GUI で承認

### 📱 iPhone からエージェントを見守る(実験的)

- 自分の Mac 上のエージェントの出力を iPhone / iPad で確認し、入力を返せる
- Mac 側で表示する QR コードでペアリング

## ソースからビルドする

必要なもの: macOS 14 以降、Xcode 16 以降(Command Line Tools ではなく Xcode 本体)

```sh
make doctor    # 環境チェック
make dev       # Clair Dev をビルドして起動(Swift の変更で自動で再ビルド)
make test      # ユニットテスト
```

Dev ビルドは Stable と別の bundle・別のデータ領域で動くので、インストール版と並べて使えます。
その他のコマンドは `make help`、手動確認の手順は[ローカル検証手順](docs/runbooks/clair-verification.md)を参照してください。

## ドキュメント

- [仕様](docs/clair-spec.md) — 何を作るか、何を作らないか
- [タスク一覧](docs/clair-tasks.md) / [カンバン](docs/clair-kanban.html) — 進捗
- [リリースと更新配信](docs/runbooks/release.md)
- [ドキュメント案内](docs/README.md)

開発はタスク一覧をキューにして、AI エージェント用の skill `/clair-task`
(`.agents/skills/clair-task/`)で一件ずつ進めています。

## スコープ外

Windows / Linux 版、チームでの共同編集、VS Code 拡張の互換、独自プラグイン、ホスト型エージェントは扱いません。

## コントリビューション

バグ報告とバグ修正の Pull Request は歓迎です。大きな機能追加は、先に Issue で相談してもらえると助かります。
脆弱性の報告は [SECURITY.md](SECURITY.md) を参照してください。

## ライセンス

[MIT](LICENSE)。第三者コンポーネントは [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) に記載しています。
