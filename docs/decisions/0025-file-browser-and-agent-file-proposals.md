---
id: ADR-0025
title: "Finder のカラム表示をタブで持ち、Agent のファイル操作は提案として承認する"
status: accepted
date: 2026-10-19
deciders: [Diwamoto]
related_projects: []
related_issues: []
supersedes: []
superseded_by: []
---

# ADR-0025: File browser and agent file proposals

## Context

オーナーは Clair を「better Finder」にし、AI と統合したい(2026-10-19)。既存の explorer は VS Code 型の
ツリーで、Project の中しか見せず、Project を開いたときに全体を走査する。Claude Code などのターミナルに
ファイルを渡すにはパスを手で打つしかなく、macOS の Finder からターミナルへのドラッグ&ドロップも Clair の
terminal では受け付けていなかった。

オーナーの選択(2026-10-19): 配置は pane のタブ、範囲は任意のフォルダ、入口はサイドバー。Finder のように
左から右へ流れ、開いたフォルダだけを読み、コピー・Clair で開く・他のアプリで開くができること。AI 連携は
(1) ターミナルへのドロップ、(2) Agent が選択中のファイルを読める、(3) Agent がファイルを見せられる、
(4) 整理の提案を承認して実行、(5) 複数選択をまとめて Agent に送る、の 5 つ。

## Decision

- **ファイルブラウザはエディタのタブ**(`finder:<絶対パス>`)。チャット履歴タブと同じくファイルではないタブで、
  Project の再走査では閉じない。中身は Finder のカラム表示で、列が出たときにそのフォルダの 1 階層だけを
  main thread の外で読む。テキストは Clair の editor(`file.open`、Project 外は既存の ad-hoc 経路)、それ以外は
  既定のアプリ / Launch Services の一覧で開く。コピー / ペーストは pasteboard のファイル URL なので macOS の
  Finder と行き来できる。ゴミ箱は確認付き。
- **入口はサイドバー**。activity bar にカラム表示のアイコンを置き、パネルは Project(root と追加フォルダ)・
  場所(ホーム・デスクトップ・書類・ダウンロード)・開いているブラウザ。場所はアクティブなブラウザタブを
  その場所へ動かす(戻る/進むは残る)。`finder.open`(⌥⌘B、AI 不可)はタブとパネルを開く。
- **ドロップ**。Clair の terminal はファイル URL のドロップを受け、Ghostty と同じ規則で shell-escape した
  絶対パスを paste 経路で入力する。Return は押さない。explorer・ブラウザ・場所の行と、titlebar のファイル /
  ブラウザのタブはファイル URL としてドラッグできる(タブは並べ替え用の id を先頭に持ったまま)。
- **AI に公開する command**(すべて承認なし):
  - `finder.selection`(read): アクティブなブラウザタブのフォルダと選択(絶対パス)。`editor.context` と
    同じく transient で、ブラウザタブがアクティブでなければ拒否する。
  - `finder.reveal path`(additive、`clair reveal <path>`): そのファイルを選んだ状態でブラウザに出す。
    表示だけで内容を agent に返さない。
  - `finder.propose folder ops`(additive): フォルダ内のファイル操作(`mkdir` / `move` / `rename` / `trash`)の
    提案。すべてのパスはフォルダの中に限り、順に実行したときに元が存在し先が空いていることを検証する。
    提案するだけではディスクは変わらない。提案タブが開き、`finder.proposal id`(read)または
    `clair finder.wait id=…` で結果(applied / rejected / failed と実行した操作)を読む。
- **適用はユーザーだけ**。`finder.applyProposal` / `finder.rejectProposal` は AI 不可。適用ボタンが承認で、
  ゴミ箱を含むと destructive(GUI が confirmed で呼ぶ)。ゴミ箱の行は未チェックで始まる。操作は順に実行し、
  最初の失敗で止まって理由を返す。削除は Finder のゴミ箱なので手で戻せる。
- 提案は transient(再起動で消える)。

## Consequences

- Project 外のフォルダも見えるが、agent にディレクトリの中身を返す command は作らない(`finder.selection` は
  ユーザーが選んだパスだけ)。reveal は表示だけなので承認を求めない。
- 提案の検証は standardize したパスで行い、symlink は解決しない。フォルダ内の symlink が外を指していれば
  その先に効く(ponytail、必要になれば `resolvingSymlinksInPath` で塞ぐ)。
- ブラウザの列は自分の操作の後と表示時に読み直す。他のアプリによる変更の監視(FSEvents)はまだ無い。
- SwiftUI の `onDrag` は 1 項目しか運べないので、複数選択のドラッグは先頭だけ。複数はメニューの
  「ターミナルにパスを入力」「Agent に送る」で渡す。
