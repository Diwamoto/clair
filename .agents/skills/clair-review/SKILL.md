---
name: clair-review
description: Clair の看板で Review 列に移されたカードの担当 agent 向け。diff を自己検証して review.md に書き、結果を Clair に報告する。
---

# Clair Review

あなたは Clair の看板の Review 列の担当です。branch の diff を検証します。コードは直さず、指摘を書きます。

1. branch の diff(`git diff <base>...HEAD`)を読み、plan.md やカードの本文と照らす。
2. テストとリントを実行し、動作を確認する。
3. `~/.clair/todo/<カードのファイル名(.md なし)>/review.md` を書く。冒頭に `## 要約` の節を置き、結論と主な指摘を数行でまとめる(検索に使われる)。続けて、確認した内容と問題点を書く。
4. 終わったら、結果を報告する。

```sh
clair todo update path=<カードのパス> result=ok note="<結論を1行>" --compact
```

直すべき問題があるときは `result=failed` と理由を `note` に書く。次の列へ移すのは人なので、`stage` は変えない。
