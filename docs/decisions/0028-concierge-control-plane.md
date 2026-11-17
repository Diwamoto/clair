---
id: ADR-0028
title: "コンシェルジュを看板中心のコントロールプレーンにし、工程は人が列を移して進める"
status: accepted
date: 2026-11-13
deciders:
  - Daiki
related_projects: []
related_issues: []
supersedes:
  - ADR-0020
superseded_by: []
---

# ADR-0028: コンシェルジュを看板中心のコントロールプレーンにする

## Context

ADR-0020 はコンシェルジュを「チャット + 子 agent のタイル + 読み取り専用のボード」とし、工程(`stage`)の遷移ルールを
利用者のプロンプトと skill に任せた。オーナーが使うと、ファイルを見る場所がない、子が動いているのが見えない、
チャットが狭い、工程が各列で止まる、看板が操作できない、という問題が起きた。工程が止まる原因は、遷移を担う
skill が `~/.clair/concierge` に無く、Clair も遷移させないので、誰も `stage` を進めないことだった。
2026-11-13 にオーナーと設計を詰め直した(Q1–Q31)。詳細は [計画](../plans/concierge-control-plane.md)。

## Decision drivers

- コンシェルジュ画面だけで、すべての Project の仕事の状態が見え、操作できること
- LLM のループでトークンを消費しないこと
- リポジトリごとに違う実装の流儀(skill)を使えること
- 承認なしの操作が、承認の要る操作の抜け道にならないこと

## Options considered

### 工程を進める主体

- Clair が自動で遷移させる: 止まらないが、終わるたびに次の agent が起動してトークンを消費し続ける。
- コンシェルジュ(LLM)が skill に従って遷移させる(ADR-0020): skill が無いと止まる。遷移の判断にもトークンを使う。
- 人が列を移し、移したときに Clair がその列の agent を起動する(採用)。

### 列の agent の起動環境

- Impl だけ sandbox(`sbx` + `claude -p`): 対話できず skill の承認ができない。`~/.clair` と `~/.claude` が見えず、
  結果報告と skill の受け渡しに別の仕組みが要る。動作検証にローカルの環境が要る作業に向かない。
- すべて Mac 上の対話モードの `claude`(採用)。

## Decision

- コンシェルジュ画面を Clair の入口にする。画面は `チャット | 看板 | エディタ` の3列で、Project の workspace は
  詳細画面になる。titlebar 右端のボタンと ⌃⌘0 で切り替える。
- 看板の列は Inbox / Plan / Impl / Review / Done。列を移すのは人で、Plan / Impl / Review に移すと Clair が
  その列の agent を新しく起動する。終わったらその列で止まり、次へは人が移す(2026-11-18 [ADR-0030](0030-decision-sheet.md) で
  Plan→Impl→Review を自動にした)。工程間の受け渡しは
  `plan.md`・`review.md`・diff だけ。
- カードの実体は `~/.clair/todo/*.md` のまま。TODO の UI(サイドバーと activity bar)は削除する。
- 列の skill は Clair が既定を同梱する。Project×列ごとに、agent がリポジトリの skill を調べて提案し、人が承認した結果を記録する。
- コンシェルジュは依頼の意図を判断して、カードを作り列に置いて起動する。溜めておく意図なら Inbox に置き、
  意図が不明なときと危険な操作を伴うときは Inbox に置いて聞く。コンシェルジュの子は必ずカードになる。
- 承認: `todo.add` / `todo.update` は既定で承認なし。GUI の操作と、`caller` がコンシェルジュの terminal の
  `todo.update` による `stage` の変更だけが列の agent を起動し、承認カードを出さない。それ以外の呼び出し元からの
  `stage` の変更は記録だけする。
- 列の agent は Mac 上の対話モードの `claude` で起動する。
- コンシェルジュは `--disallowedTools WebFetch,WebSearch` で起動する。承認なしで起動できるのは、チャットの依頼1件につき
  3体まで。超えたら承認カードを出す。

## Rationale

人が列を移す方式なら、工程が進むかどうかはオーナーの判断と一致し、止まっている理由が見て分かる。
agent は列ごとに一度だけ起動するので、トークンの消費は移した回数に比例し、ループで増えない。
`todo.update` を承認なしにすると、子 agent も `stage` を書けるので、起動の可否を呼び出し元で分けないと、
承認なしで agent を増やせてしまう。起動できる呼び出し元を GUI とコンシェルジュに限ると、承認なしで起動できる
範囲はオーナーの操作とオーナーが承認したプロンプト(ADR-0020 の #76)で動くコンシェルジュに留まる。

## Consequences

### Positive

- コンシェルジュ画面で、すべての仕事の状態と agent の画面が見える。
- 工程が止まる原因(遷移の担い手の不在)がなくなる。

### Negative

- 列を進めるたびに人の操作が要る。
- コンシェルジュは承認なしで agent を起動できる。コンシェルジュのプロンプトと cwd の内容は ADR-0020(#76)の
  承認で守られるが、コンシェルジュが読む外部の内容(Web、リポジトリのファイル)によって意図しない起動が起きうる。
  Web を読めなくし、依頼1件あたりの承認なしの起動を3体に限ることで、誘導される機会と起動できる数を絞る。
  完全には防げないが、誘導されて起動した子も Claude Code の権限確認を通るので、書き込みと実行には人の操作が要る。
  sandbox(#75)は子の被害の範囲を絞る別の層で、コンシェルジュの起動そのものは防がない。
- ADR-0020 のうち、raw PTY + transcript のチャット、承認済みのプロンプトと cwd、子の出力を中継しないことは引き継ぐ。
  ボードとタイル、遷移をプロンプトに任せる部分を置き換える。

## Validation

- 実アプリで、カードを列に移すと agent が起動し、終わると止まって状態が出ること。
- 子 agent の `clair todo update stage=impl` で agent が起動しないこと(unit test)。

## Revisit conditions

- 列を移す操作が多すぎて負担になったとき(特定の遷移だけ自動にするかを検討する)。
- sandbox の中の対話モードの agent から hook の報告(状態と `result`)を Clair に届けられるようになったとき(Impl を sandbox に戻す)。

## References

- Plan: [docs/plans/concierge-control-plane.md](../plans/concierge-control-plane.md)
- 置き換える ADR: [ADR-0020](0020-concierge-agent.md)。承認の既定値: [ADR-0027](0027-agent-auto-approve.md)
