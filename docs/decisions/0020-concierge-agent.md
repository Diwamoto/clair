---
title: "Project ごとのコンシェルジュ agent を raw PTY + transcript の GUI チャットで出す"
status: accepted
date: 2026-09-30
---

# ADR-0020: コンシェルジュ agent

## 決定

各 Project に一つ、Clair の操作と子 agent の管理を任せるコンシェルジュ agent を置く。
activity bar の 5 つ目「コンシェルジュ」から sidebar に開く。

- 本体は既定 Agent の CLI を通常の agent launch と同じく raw PTY で起動する。
  cwd は Project root、承認境界も `agent.launch` と同じ。
- GUI はその session の provider 公式 transcript(Claude Code / Codex の JSONL、
  OpenCode の DB。`AgentHistoryReader` が読むもの)をチャットとして描画する。
  送信欄の入力はその PTY に書き込む。TUI の画面は解析しない。
- 子 agent は `parent` にコンシェルジュの terminal key を持つ通常の agent terminal。
  チャットと sidebar はその状態(process の事実)と pane へのリンクを出し、
  子の出力をコンシェルジュへ中継しない。要約が必要なときだけコンシェルジュが
  `agent.output` で末尾を読む。
- Project ごとの指示は `.clair/concierge.md` に置き、起動時に渡す。

## 理由

spec §1 と原則 3 は agent 固有の chat UI を正本にしないことと、TUI の screen
scraping をしないことを求める。この決定では raw PTY が正本のまま残る。GUI は公式
transcript という根拠のある情報だけを描画する追加層になる(ADR-0002)。子の出力を
中継せずリンクで済ませると、マネージャー役のトークン消費が子の数や出力量に比例しない。

## 比較

- headless モード(`claude -p --output-format stream-json` など)を GUI 専用に使う:
  raw terminal を開けず、原則 3 の例外が大きくなるので採らない。
- 子の出力をすべてコンシェルジュの context に流す: トークン消費が大きいので採らない。
