# Agent と Clair のエディタ連携

Clair が起動している間、`clair mcp serve` は stdio MCP server として動く。Clair の設定 › 連携で `clair` コマンドをインストールしてから、利用する Agent に登録する。

Claude Code では次を一度実行する（[公式の stdio MCP 登録方法](https://code.claude.com/docs/en/mcp)）。

```sh
claude mcp add --scope user --transport stdio clair -- clair mcp serve
```

Codex CLI では次を一度実行する。Codex app と CLI は同じ MCP 設定を使う（[OpenAI Docs](https://developers.openai.com/learn/docs-mcp)）。

```sh
codex mcp add clair -- clair mcp serve
```

ほかの MCP 対応 Agent には、command `clair`、args `["mcp", "serve"]` の stdio server として登録する。登録した Agent から次の tool を使える。

- `editor.context`: 現在のファイル、1 始まりの行・0 始まりの UTF-16 桁、選択テキストを取得する。未選択時は位置だけ。選択が 16 KiB を超える場合はテキストを返さない。
- `file.open`: Clair で既に開いている Project 内のファイルを開き、指定された行・桁へ移動する。Project 外のファイルは拒否する。
- `editor.diagnostics`: language server の診断(エラー・警告)を返す。`path` を省くと active Project で開いている全ファイル。Clair のエディタで開いたファイルだけが対象。
- `review.threads`: レビューコメントを、現在のファイル上の行と状態つきで返す。
- `review.comment`: ファイルの行(`line`〜`endLine`)にレビューコメントを付ける。ファイルは変更しない。
- `review.suggest`: 行 `line`〜`endLine` を `replacement` に置き換える提案を付ける。適用するかは利用者が diff で決める。active Project のファイルだけ。

`path` は絶対パスか active Project からの相対パスで、開いている Project 内の既存ファイルに限る。Clair の terminal からは同じことを `clair review.comment path=/abs/file line=12 body="…"` のように CLI でも実行できる。

Agent が選択内容を使うときは `editor.context` を呼ぶ。選択内容は Agent へ渡るが、Clair の workspace file には保存されない。`file.open` はユーザーの画面を切り替える。Clair 内の terminal からは従来どおり `clair open /absolute/path:line:column` も利用できる。
