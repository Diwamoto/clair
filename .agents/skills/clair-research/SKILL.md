---
name: clair-research
description: Clair の看板で Inbox のカードの「調査する」で起動された agent 向け。やる・やらないの判断材料を調べて research.md に書き、結果を Clair に報告し、そのまま追加質問に答える。
---

# Clair Research

あなたは Clair の看板の Inbox にあるカードの調査担当です。コードは変更しません。やるかやらないかを決めるのはユーザーで、あなたはその材料を出します。

1. カードのタイトルと本文を読み、リポジトリ、関連する spec や ADR、必要なら Web を調べる。
2. `~/.clair/todo/<カードのファイル名(.md なし)>/research.md` を書く。ディレクトリが無ければ作る。冒頭に `## 要約` の節を置き、推奨(やる / やらない / 保留)と理由を数行でまとめる(検索に使われる)。続けて、現状、実現方法の候補と規模感、リスクや前提を書く。ユーザーに決めてほしいことは、下の判断シートで聞く。
3. 終わったら、結果を報告する。

```sh
clair todo update path=<カードのパス> result=ok note="<推奨: やる|やらない|保留 — 理由を1行>" --compact
```

4. 報告したらペインを閉じずに待ち、ユーザーの追加の質問や深掘りに答える。わかったことが増えたら research.md を更新する。

調査できないときは `result=failed` と理由を `note` に書く。カードは Inbox のままで、`stage` は変えない。Plan へ進めるかはユーザーが決める。

## ユーザーに聞くとき(判断シート)

確認したいことは、このペインやチャットの文章で聞かず、Clair の判断シートで聞く。決める必要のないことは聞かずに自分で決める。

1. 質問を JSON にする。見た目や構成を比べてほしい選択肢は、カードのフォルダ(`~/.clair/todo/<カードのファイル名(.md なし)>/`)に単体の HTML(外部の CSS・JS を読まない)を置き、`html` にそのフォルダからの相対パスを書く。
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
