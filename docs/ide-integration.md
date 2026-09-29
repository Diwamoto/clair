# Agent と Clair のエディタ連携

Clair が起動している間、`clair mcp serve` は stdio MCP server として動く。Clair の設定 › 連携で `clair` コマンドをインストールしてから、利用する Agent に登録する。

Claude Code では次を一度実行する（[公式の stdio MCP 登録方法](https://code.claude.com/docs/en/mcp)）。

```sh
claude mcp add --scope user --transport stdio clair -- clair mcp serve
```

ほかの MCP 対応 Agent には、command `clair`、args `["mcp", "serve"]` の stdio server として登録する。登録した Agent から次の tool を使える。

- `editor.context`: 現在のファイル、1 始まりの行・0 始まりの UTF-16 桁、選択テキストを取得する。未選択時は位置だけ。選択が 16 KiB を超える場合はテキストを返さない。
- `file.open`: Clair で既に開いている Project 内のファイルを開き、指定された行・桁へ移動する。Project 外のファイルは拒否する。

Agent が選択内容を使うときは `editor.context` を呼ぶ。選択内容は Agent へ渡るが、Clair の workspace file には保存されない。`file.open` はユーザーの画面を切り替える。Clair 内の terminal からは従来どおり `clair open /absolute/path:line:column` も利用できる。
