---
id: ADR-0033
title: "HTML ツール: 生成した HTML をサイドバーに登録し、ペインで開く"
status: accepted
date: 2026-11-27
deciders: [Diwamoto]
related_projects: []
related_issues: []
supersedes: []
superseded_by: []
---

# ADR-0033: HTML tools

## Context

オーナーは長い Terraform の plan を一つずつ選んで apply したい(2026-11-27)。それは plan を貼ると
リソースごとに並べて `-target` 付きのコマンドを作る 1 枚の HTML で足りる。こうした「AI に作らせた HTML の
道具」を Clair の中で置いておき、いつでも開けるようにしたい。HTML プレビュー(ADR-0018)はファイルを
エディタで開いた横に出すもので、道具の置き場所も入口も無い。

オーナーの選択(2026-11-27): 一覧はサイドバーのパネル、クリックで新しいペインに HTML だけを開く、
ドロップした HTML は `~/.clair/tools` にコピー、Terraform の道具を標準で同梱、agent も CLI と skill で使える。

## Decision

- activity bar の `</>` でサイドバーに「HTML ツール」を出す。**標準** は Clair に同梱したページ(Clair の
  更新で置き換わる。チャンネルのデータフォルダの `tools/` に書き出してから開く)、**マイツール** は
  `~/.clair/tools` 直下の `.html` / `.htm`(名前順)。
- 行のクリックで、フォーカス中のペインを分割した新しいペインにそのページだけを開く(HTML プレビューと同じ
  WebView と制限。ソースは出さない)。既に開いているツールはそのペインにフォーカスする。ペインは `.preview`
  の葉で、対象は絶対パス。エディタで開いていない HTML のプレビューはディスクの内容を出す。
- パネルへ `.html` をドロップすると `~/.clair/tools` にコピーする(同名は上書き。作り直した HTML はもう一度
  ドロップする)。マイツールの右クリックは 開く / Finder で表示 / ゴミ箱に入れる。
- command: `tool.list`(read、AI 可)、`tool.add path [open]`(additive、AI 不可。コピーして既定で開く)、
  `tool.open name`(additive、AI 不可。ファイル名か絶対パス)。`tool.add` / `tool.open` は `file.preview` と同じく
  CLI からは GUI の承認カードを通り、MCP には出さない(ページは JavaScript を実行する)。
- `clair-preview` skill は生成した HTML を `clair tool add path=…` で見せるよう案内する。
- 標準の最初の 1 つは Terraform Plan Picker: `terraform` / `terragrunt plan` の出力(ANSI 色・terragrunt の行頭は
  そのまま)を貼ると、リソースごとの差分と作成/変更/置換/削除の絞り込みを出し、選んだものの `-target` 付き
  コマンドをコピーする。apply は人が terminal で打つ。

## Consequences

- 道具は Clair の機能ではなくページなので、Clair 側は置き場所と開き方だけを持つ。§14 の「Clair 独自 task
  runner」は作らない(コマンドはコピーまでで、実行は terminal)。
- 複数ファイルの道具(別ファイルの CSS / JS)は `~/.clair/tools` の中で共有になる。1 ファイルの HTML を勧める。
- パネルは表示時と自分の操作のあとに一覧を読み直す。表示中の `clair tool add` は次に表示したときに出る。
