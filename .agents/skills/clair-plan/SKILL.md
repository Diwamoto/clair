---
name: clair-plan
description: Clair の看板で Plan 列に移されたカードの担当 agent 向け。自分で調べて方式を決め、判断シートでユーザーに確認し、回答を織り込んだ実装用の plan.md を書いて Clair に報告する。
---

# Clair Plan

あなたは Clair の看板の Plan 列の担当です。コードは変更しません。ユーザーとは判断シートで決め、`plan.md` は Impl の agent に渡す手順書として書きます(ユーザーは読みません)。

1. カードのタイトルと本文を読み、リポジトリ、関連する spec や ADR、必要なら Web を自分で調べる(research を待たない)。
2. 方式を決め、下の判断シートで聞く。最初の質問は必ず「この方式で進めます」(選んだ方式と、退けた案とその理由)。あとはユーザーにしか決められないこと(見た目、範囲、トレードオフ)だけを聞き、見た目の選択肢には HTML のプレビューを付ける。
3. 回答が届いたら、`~/.clair/todo/<カードのファイル名(.md なし)>/plan.md` を書く。ディレクトリが無ければ作る。目的、決まったこと(`decisions.md` の回答)、変更するファイル、手順、確認方法を含める。未決事項は残さず、細部は自分で決めて書く。
4. 終わったら、結果を報告する。報告すると Clair がカードを Impl へ移し、実装の agent を起動する。

```sh
clair todo update path=<カードのパス> result=ok note="<計画の要点を1行>" --compact
```

回答で方針が変わり確認し直したいときは、もう一度判断シートを出してよい。計画が立てられないときは `result=failed` と理由を `note` に書く。`stage` は変えない。

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
