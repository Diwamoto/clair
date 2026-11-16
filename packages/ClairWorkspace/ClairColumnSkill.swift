import Foundation

/// The skills a board column's agent starts from. Keep each text identical to `.agents/skills/<name>/SKILL.md`.
public enum ClairColumnSkill {
  public static let all: [(name: String, markdown: String)] = [
    ("clair-research", #"""
---
name: clair-research
description: Clair の看板で Inbox のカードの「調査する」で起動された agent 向け。やる・やらないの判断材料を調べて research.md に書き、結果を Clair に報告し、そのまま追加質問に答える。
---

# Clair Research

あなたは Clair の看板の Inbox にあるカードの調査担当です。コードは変更しません。やるかやらないかを決めるのはユーザーで、あなたはその材料を出します。

1. カードのタイトルと本文を読み、リポジトリ、関連する spec や ADR、必要なら Web を調べる。
2. `~/.clair/todo/<カードのファイル名(.md なし)>/research.md` を書く。ディレクトリが無ければ作る。冒頭に `## 要約` の節を置き、推奨(やる / やらない / 保留)と理由を数行でまとめる(検索に使われる)。続けて、現状、実現方法の候補と規模感、リスクや前提、未決事項(ユーザーに聞きたいこと)を書く。
3. 終わったら、結果を報告する。

```sh
clair todo update path=<カードのパス> result=ok note="<推奨: やる|やらない|保留 — 理由を1行>" --compact
```

4. 報告したらペインを閉じずに待ち、ユーザーの追加の質問や深掘りに答える。わかったことが増えたら research.md を更新する。

調査できないときは `result=failed` と理由を `note` に書く。カードは Inbox のままで、`stage` は変えない。Plan へ進めるかはユーザーが決める。
"""# + "\n"),
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
