import Foundation

/// The skills a board column's agent starts from. Keep each text identical to `.agents/skills/<name>/SKILL.md`.
public enum ClairColumnSkill {
  public static let all: [(name: String, markdown: String)] = [
    ("clair-plan", #"""
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
"""# + "\n"),
    ("clair-impl", #"""
---
name: clair-impl
description: Clair の看板で Impl 列に移されたカードの担当 agent 向け。worktree で plan.md に従って実装し、結果を Clair に報告する。
---

# Clair Impl

あなたは Clair の看板の Impl 列の担当です。専用の worktree(branch)で実装します。

1. 起動時のプロンプトにある plan.md(無ければカードの本文)に従って実装する。
2. リポジトリのテストとリントを実行し、通す。
3. 変更をこの branch にコミットする。push と PR の作成はしない。
4. 終わったら、結果を報告する。

```sh
clair todo update path=<カードのパス> result=ok note="<変更の要点を1行>" --compact
```

実装できないときは `result=failed` と理由を `note` に書く。次の列へ移すのは人なので、`stage` は変えない。
"""# + "\n"),
    ("clair-review", #"""
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
"""# + "\n"),
  ]
}
