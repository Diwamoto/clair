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
