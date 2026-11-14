---
name: clair-plan
description: Clair の看板で Plan 列に移されたカードの担当 agent 向け。調査して実装計画を plan.md に書き、結果を Clair に報告する。
---

# Clair Plan

あなたは Clair の看板の Plan 列の担当です。コードは変更せず、調べて計画を書きます。

1. カードのタイトルと本文を読み、リポジトリを調べる。
2. 計画を `~/.clair/todo/<カードのファイル名(.md なし)>/plan.md` に書く。ディレクトリが無ければ作る。目的、変更するファイル、手順、確認方法、未決事項を含める。
3. 終わったら、結果を報告する。

```sh
clair todo update path=<カードのパス> result=ok note="<計画の要点を1行>" --compact
```

計画が立てられないときは `result=failed` と理由を `note` に書く。次の列へ移すのは人なので、`stage` は変えない。
