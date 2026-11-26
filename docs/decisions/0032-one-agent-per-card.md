---
id: ADR-0032
title: "看板の工程を外し、カード1枚を agent 1体に任せる"
status: accepted
date: 2026-11-26
deciders:
  - Daiki
related_projects: []
related_issues:
  - "#82"
supersedes:
  - ADR-0028
superseded_by: []
---

# ADR-0032: カード1枚 = agent 1体

## Context

ADR-0028 で看板の列を工程(Inbox / Plan / Impl / Review / Done)にし、列ごとに agent と skill を起動し、ADR-0030 で
Plan → Impl → Review を自動で進めた。オーナーは依頼を基本すべて agent に任せたく、受け取りたいのは「できたか /
できなかった理由 / 自分の判断が要るか」だけで、中身は気になったときに Clair で見られればよい(2026-11-26、#82)。
工程を分ける仕組みは機能としてやりすぎで、コンシェルジュのチャットは会話が1つにまとまって文脈が混ざり、壁打ちが
できなかった。ADR-0031 でボード画面は看板だけになり、会話は IDE のターミナルに移った。

## Decision drivers

- 依頼から結果までをオーナーの操作なしで進め、結果を短く受け取ること
- 依頼ごとに会話が分かれ、あとから同じ会話を続けられること
- 仕組み(列ごとの起動、自動遷移、列の skill、コンシェルジュ)を減らすこと

## Options considered

- 工程の列を残し、自動遷移を Review → Done まで広げる: 列ごとの agent・skill・受け渡しのファイルは残り、
  1つの依頼の文脈が agent ごとに切れる。
- カード1枚に agent 1体(採用): 1体が調査から確認まで持つ。列は状態になり、人が列を動かす操作が無くなる。

## Decision

- 看板の列は工程ではなく状態にする: Inbox(agent が無い)/ 実行中(running)/ 判断待ち(blocked: 未回答の判断シートか
  承認待ち)/ 完了(`result=ok`、またはチェック済みの TODO)/ 未完了(`result=failed`、異常終了、報告せずに止まった・
  pane が無くなった)。状態は `TodoBoardCard.State` のまま。カードはドラッグで動かさない。
- `todo.run path`(AI 不可、GUI 専用)がカードの agent を1体起動する。カードの Project で対話モードの `claude` を
  worktree なしで起動し、起動プロンプトはカードのタイトル・本文と同梱の skill `clair-card` の指示・判断シート・
  報告の1行。agent が動いている間は起動し直さない。カードに会話(`session`)があれば `--resume` で続きから起動する。
- agent の完了報告は `todo update result=ok|failed note=<1行>`。カードの表には 結果(完了 / 未完了)・理由(`note`)・
  判断(判断シートが出ているか)の3点だけを出す。
- agent が hooks で報告する provider の session id を、カードの `session` に記録する(pane を閉じても会話を続けられる)。
- ボードの入力欄に1行の依頼と Project を入れて Return でカードを作って起動する(⌘Return は Inbox に置くだけ)。
  その Project の workspace には切り替えない。カードのクリックで、その agent のターミナルをクイックルックで開き、
  そのまま会話を続ける。pane が無ければ `todo.run` で会話を開き直してから開く。
- 判断シート(ADR-0030)は残す。agent がユーザーに聞く手段は判断シートだけで、聞けるのはそのカードの agent だけ。
  ADR-0030 の自動進行と plan.md は無くなる。
- 外すもの: 列ごとの起動(`todo.move`)、自動遷移(`autoAdvance`)、列の skill(`clair-research` / `clair-plan` /
  `clair-impl` / `clair-review`、`todo.skill`、`~/.clair/todo/.skills.json`)、ADR-0031 で残したコンシェルジュ agent の
  バックエンド(`concierge.*`、`settings.concierge`、起動上限、看板のニュース)。ADR-0031 の「ファクトリーの仕組みは
  変えない」を取り消す。
- 古いカードの `stage` / `lane` / `retry` / `difficulty` は読み込んでも無視し、ファイルには残す。

## Rationale

1体が最後まで持てば工程間の受け渡し(plan.md・review.md)と、遷移の判断・起動の上限が要らない。列が状態なら、
オーナーが見るべきもの(判断待ちと未完了)がそのまま列になる。会話はカードの agent のターミナルなので、依頼ごとに
分かれ、Claude Code の session でいつでも続けられる。

## Consequences

### Positive

- オーナーの操作は「依頼する」「判断シートに答える」「気になったカードを開く」になる。
- コンシェルジュの承認・起動上限・指紋の仕組みが無くなり、agent を起動できるのは GUI(と承認カード)だけになる。

### Negative

- 同じ Project の複数のカードの agent は同じ作業ツリーで動く(worktree を作らない)。衝突しそうなら agent が自分で
  branch / worktree を切る。
- モデルはカードごとに選ばない(Claude Code の既定)。
- 以前の設定で入れた列の skill(`~/.claude/skills/clair-plan` など)は自動では消えない。
- 動いていたコンシェルジュの daemon の shell は layout から外れ、Clair からは閉じられない(daemon の再起動で消える)。

## Validation

- unit test: 状態から列への対応、`todo.run` が1体を起動してカードに記録すること、会話のあるカードは resume すること、
  古いキーのカードを読めること、`todo.run` が AI 不可で、外したコマンドが残っていないこと。
- 実アプリで、入力欄から Project を切り替えずに依頼してカードと agent ができ、カードから会話を続けられること。

## References

- Issue: #82
- 置き換える ADR: [ADR-0028](0028-concierge-control-plane.md)。改める ADR: [ADR-0030](0030-decision-sheet.md)(自動進行と plan.md)、
  [ADR-0031](0031-board-screen.md)(ファクトリーの仕組みとコンシェルジュのバックエンドを残す部分)
