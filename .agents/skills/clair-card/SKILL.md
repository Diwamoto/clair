---
name: clair-card
description: Clair の看板のカード1枚を任された agent 向け。調査から実装・確認まで1人で最後まで進め、ユーザーにしか決められないことだけを判断シートで聞き、result と note の1行で Clair に報告する。
---

# Clair Card

あなたは Clair の看板のカード1枚の担当です。カード1枚 = agent 1体で、工程(調査・計画・実装・確認)を分けず、別の agent も起動せず、あなたが最後まで進めます。ユーザーが受け取るのは「できたか / できなかった理由 / 判断が要るか」だけです。

1. カードのタイトルと本文が依頼。リポジトリの `AGENTS.md` / `CLAUDE.md` と、合う skill(`.claude/skills/` やユーザーの skill)があればそれに従う。
2. 自分で調べて方式を決め、実装し、テストや実行で確かめる。決める必要のある細部は自分で決める。
3. ユーザーに聞くのは、あなたにしか決められないことだけ(範囲や方針が分かれるとき、push・削除・公開・課金など戻せない操作)。聞き方は下の「判断シート」だけで、ペインの文章では聞かない。
4. 成果物(メモ、図、調査結果)を残すなら、カードのフォルダ `~/.clair/todo/<カードのファイル名(.md なし)>/` に置く。
5. 終わったら1行で報告する。長い文章は書かない。

```sh
clair todo update path=<カードのパス> result=ok note="<何をしたか1行: commit や PR、置いたファイル>" --compact
clair todo update path=<カードのパス> result=failed note="<できなかった理由1行>" --compact
```

6. 報告してもペインは閉じない。ユーザーはカードからこのペインを開いて会話を続ける。追加の依頼をこなしたら、もう一度報告する。

## ユーザーに聞くとき(判断シート)

1. 質問を JSON にする。シートは図で答えてもらう前提で作る。選択肢ごとに、違いが一目で分かる図(画面のモック、構成図、流れ、before/after の比較)を単体の HTML(外部の CSS・JS を読まない。幅 380px・高さ 180px に収める)にしてカードのフォルダに置き、`html` にそのフォルダからの相対パスを書く。図で示せることを `prompt` / `context` / `detail` の文章で説明しない。文章は図だけでは伝わらない要点を 1 行で書く。
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
