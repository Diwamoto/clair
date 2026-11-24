---
id: ADR-0031
title: "コンシェルジュ画面を看板だけのボード画面にし、会話は IDE のターミナルに一本化する"
status: accepted
date: 2026-11-24
deciders:
  - Daiki
related_projects: []
related_issues: []
supersedes:
  - ADR-0029
superseded_by: []
---

# ADR-0031: ボード画面

## Context

コンシェルジュ(ADR-0020 → 0028 → 0029)は、Clair のコントロールプレーンとソフトウェアファクトリーのために生まれた。
ADR-0029 で会話を Claude Code のターミナルそのものにした結果、コンシェルジュ画面の会話の列は IDE の terminal pane と
ほぼ同じものの二重持ちになった。オーナーが使うと、agent を気軽に呼んで操作するのは IDE の方が良く、
コンシェルジュ画面に欲しいのは TODO(看板)が見えることだった(2026-11-24)。

## Decision

- コンシェルジュ画面は看板だけの「ボード」画面にする。会話の列・会話一覧・チャット UI(`conciergeChatUI`)・
  設定画面の「コンシェルジュ」欄を外す。titlebar の切り替えボタン(⌃⌘0)は IDE とボードを切り替える。
- agent との会話は IDE のターミナルで行う。カードの「コンシェルジュに頼む」「PR を作る」は IDE に戻り、
  フォーカス中の terminal pane(無ければ最初の terminal pane、それも無ければクリップボード)に入力する(送信しない)。
- ファクトリーの仕組み(列を移すと列の agent を起動、Plan → Impl → Review の自動遷移、判断シート、`clair-*` skill、
  ⌥⌘Y / ⌥⌘N、クイックルック、エディタ列、⌘J の一時ターミナル)は変えない。
- コンシェルジュ agent のバックエンド(`concierge.*`、`settings.concierge`、起動上限、看板のニュース)は今回は残す。
  GUI から起動しなくなったので、使われないと確かめたら別に外す。

## Consequences

- IDE のターミナルの agent は `todo.update` で `stage` を変えても agent を起動しない(コンシェルジュの caller に限るため、
  ADR-0028 の境界のまま)。列を移すのは人がボードで行う。
- ⌘D / ⌘B などのペイン操作はボード画面では IDE 側(見えない)に効く。ボード画面の ⌘W は列のファイルタブがあれば閉じ、
  無ければ何もしない。
- Design canvas の Concierge アートボードはまだ会話の列を描いている。次の canvas 同期で外す。
