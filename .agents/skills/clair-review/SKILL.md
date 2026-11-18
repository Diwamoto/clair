---
name: clair-review
description: Clair の看板で Review 列に移されたカードの担当 agent 向け。diff を自己検証して review.md に書き、結果を Clair に報告する。
---

# Clair Review

あなたは Clair の看板の Review 列の担当です。branch の diff を検証します。コードは直さず、指摘を書きます。

1. branch の diff(`git diff <base>...HEAD`)を読み、plan.md・decisions.md・カードの本文と照らす。
2. テストとリントを実行し、動作を確認する。
3. `~/.clair/todo/<カードのファイル名(.md なし)>/review.md` を書く。冒頭に `## 要約` の節を置き、結論と主な指摘を数行でまとめる(検索に使われる)。続けて、確認した内容と問題点を書く。ユーザーの判断が要る指摘は、下の判断シートで聞く。
4. 終わったら、結果を報告する。

```sh
clair todo update path=<カードのパス> result=ok note="<結論を1行>" --compact
```

直すべき問題があるときは `result=failed` と理由を `note` に書く。Done へ移すのはユーザーなので、`stage` は変えない。

## ユーザーに聞くとき(判断シート)

確認したいことは、このペインやチャットの文章で聞かず、Clair の判断シートで聞く。決める必要のないことは聞かずに自分で決める。

1. 質問を JSON にする。シートは図で答えてもらう前提で作る。選択肢ごとに、違いが一目で分かる図(画面のモック、構成図、流れ、before/after の比較)を単体の HTML(外部の CSS・JS を読まない。幅 380px・高さ 180px に収める)にしてカードのフォルダ(`~/.clair/todo/<カードのファイル名(.md なし)>/`)に置き、`html` にそのフォルダからの相対パスを書く。図で示せることを `prompt` / `context` / `detail` の文章で説明しない。文章は図だけでは伝わらない要点を 1 行で書く。
2. 出す。JSON が長いときはファイルに書いて `questions="$(cat <ファイル>)"` で渡す。

```sh
clair ask post card=<カードのパス> questions='<JSON>' --compact
```

3. ターンを終えて待つ。回答は `[判断シートの回答] …` の 1 行でこのペインに届き、カードのフォルダの `decisions.md` にも残る。回答の無い質問は自分で決めてよい。

```json
{"title":"<短い見出し>","questions":[
  {"id":"approach","kind":"single","prompt":"この方式で進めます","context":"<選んだ方式を2〜3行>",
   "options":[{"id":"go","label":"この方式で進める"},{"id":"alt","label":"<退けた案>","detail":"退けた理由: …"}],"recommended":"go"},
  {"id":"layout","kind":"single","prompt":"<決めてほしいこと>",
   "options":[{"id":"a","label":"…","detail":"…","html":"layout-a.html"},{"id":"b","label":"…"}],"recommended":"a"},
  {"id":"note","kind":"text","prompt":"<自由記述で聞きたいこと>"}]}
```

`kind` は `single`(1 つ選ぶ)/ `multi`(複数選ぶ)/ `text`(自由記述)。`recommended` は選択肢の `id`(multi は配列)で、シートはその選択肢を選んだ状態で開く。
