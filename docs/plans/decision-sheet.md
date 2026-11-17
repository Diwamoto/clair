# 判断シートと自動進行

Status: 実装済み(2026-11-18)。実アプリでの AC-01–03 / AC-05 の確認は未了
Decision: [ADR-0030](../decisions/0030-decision-sheet.md)

## 流れ

```
コンシェルジュに依頼 → カード作成 → Plan(agent が調査、方式を決める)
  → 判断シート「この方式で進めます / 決めてほしいこと」(HTML プレビュー付き)
  → オーナーがまとめて回答 → agent が plan.md(impl 専用)を書く → 自動で Impl → 自動で Review
  → オーナーが Review を見て Done
```

## シートの形式(`ask.post` の入力)

```json
{
  "card": "~/.clair/todo/login.md",
  "title": "ログイン画面の改修",
  "questions": [
    { "id": "approach", "kind": "single", "prompt": "この方式で進めます",
      "context": "既存の AuthStore を拡張する",
      "options": [
        { "id": "a", "label": "AuthStore を拡張", "detail": "変更 3 ファイル", "html": "approach-a.html" },
        { "id": "b", "label": "新しい AuthService を作る", "detail": "退けた理由: 重複が増える" }
      ],
      "recommended": "a" },
    { "id": "copy", "kind": "text", "prompt": "エラー文言の希望があれば" }
  ]
}
```

- `kind`: `single` / `multi` / `text`。`html` はカードのフォルダ(`~/.clair/todo/<card>/`)からの相対 path に限る。
- 回答は `decisions.md` に追記し、質問元のペインに「判断シートの回答: …」として入力する。

## 受け入れ基準

| AC | 検証 |
|---|---|
| AC-01 `ask.post` でカードが「あなた待ち」になり、クリックでエディタ列にシートが開く | 実アプリ |
| AC-02 選択肢の HTML がシート内でプレビューされ、推奨が既定で選ばれている | 実アプリ |
| AC-03 「まとめて回答」で質問元のペインに回答が入り、`decisions.md` に残る | unit test、実アプリ |
| AC-04 Plan の ok で Impl、Impl の ok で Review に自動で移り、failed と未回答で止まる | `TodoBoard` の unit test |
| AC-05 コンシェルジュと列の skill が確認をシートで聞く | プロンプト / skill の差分、実アプリ |
| AC-06 範囲外の HTML path、不正な JSON はエラーで、何も表示しない | unit test |

## Slices

0. canvas: シートのタブ、あなた待ちのカード(`clair-workbench-sync`)。ADR-0030 を accepted に。
1. `ask.post` と保存(`decisions.md`)、検証、回答のペインへの入力。
2. シートの UI(エディタ列のタブ、HTML プレビュー)とカードの状態。
3. 自動進行(Plan→Impl→Review)と起動上限の扱い。
4. コンシェルジュの固定の役割と `clair-plan` / `clair-research` / `clair-impl` / `clair-review` / `clair-agents` の書き換え。spec 更新。
