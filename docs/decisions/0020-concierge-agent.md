---
title: "Clair 全体で一つのコンシェルジュ agent を raw PTY + transcript の GUI チャットで出す"
status: accepted
date: 2026-09-30
---

# ADR-0020: コンシェルジュ agent

## 決定

Clair 全体に一つ、Clair の操作と子 agent の管理を任せるコンシェルジュ agent を置く
(2026-11-09 改訂、#76。当初は Project ごとだった)。
activity bar の「コンシェルジュ」から、sidebar を持たない専用画面として開く(2026-11-11 改訂)。

- 本体は既定 Agent の CLI を通常の agent launch と同じく raw PTY で起動する。
  cwd は設定の `concierge.cwd`(空なら active Project root)、承認境界も `agent.launch` と同じ。
  terminal はどの Project の layout にも置かず(2026-11-10 改訂)、チャットの裏に見えない surface として
  マウントする。承認や質問を待つ間だけチャットの上に出す。どの Project からも同じ一つを開く。
- GUI はその session の provider 公式 transcript(Claude Code / Codex の JSONL、
  OpenCode の DB。`AgentHistoryReader` が読むもの)をチャットとして描画する。
  送信欄の入力はその PTY に書き込む。TUI の画面は解析しない。
- 子 agent は `parent` にコンシェルジュの terminal key を持つ通常の agent terminal。
  画面はその状態(process の事実)と pane へのリンクを出し、
  子の出力をコンシェルジュへ中継しない。要約が必要なときだけコンシェルジュが
  `agent.output` で末尾を読む。
- 指示は設定の `concierge.prompt` に置き、起動時に固定の役割の後ろに足して渡す。
  `settings.concierge` は AI 不可。prompt・cwd・cwd のプロジェクトファイルのハッシュが前回の
  承認から変わっていたら、起動前に承認カードを出す。

## 改訂の理由(2026-11-11)

オーナーの依頼で、Clair の Project workspace をデータプレーン、コンシェルジュをコントロールプレーンとして分ける。
コンシェルジュはどの Project にも属さないので、Project の chrome である sidebar を持たない。
画面には全 Project の agent pane の画面を読み取り専用のタイルとして並べ、データプレーンをそこから見渡せるようにする。
タイルはユーザーに見せるだけで、コンシェルジュへは中継しない。

## 改訂の理由(2026-11-10)

オーナーの依頼で、コンシェルジュの Claude Code をユーザーが知覚しない存在にする。layout の pane は
Project の切替や pane 操作の対象になり、チャットが窓口であることを崩していた。raw PTY は正本のまま
残るので、承認待ちのときだけ本物のターミナルを出せば原則 3 は保たれる。

## 改訂の理由(2026-11-09)

工程を分担するエージェントファクトリー(#74)では、コンシェルジュは Project をまたいで子を起動する。
中身(工程表と遷移のルール)は利用者側のプロンプトとプロジェクトスキルに持たせ、Clair は
どのプロンプトと cwd で動かすかを選べるだけにする(疎結合)。コンシェルジュは以後の全タスクを
指揮するので、agent からは書き換えられず、読み込む内容の変化はユーザーが承認する。

## 理由

spec §1 と原則 3 は agent 固有の chat UI を正本にしないことと、TUI の screen
scraping をしないことを求める。この決定では raw PTY が正本のまま残る。GUI は公式
transcript という根拠のある情報だけを描画する追加層になる(ADR-0002)。子の出力を
中継せずリンクで済ませると、マネージャー役のトークン消費が子の数や出力量に比例しない。

## 比較

- headless モード(`claude -p --output-format stream-json` など)を GUI 専用に使う:
  raw terminal を開けず、原則 3 の例外が大きくなるので採らない。
- 子の出力をすべてコンシェルジュの context に流す: トークン消費が大きいので採らない。
