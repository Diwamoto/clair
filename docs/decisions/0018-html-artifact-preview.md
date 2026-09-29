---
title: "HTML artifact を独立した WebView でプレビューする"
status: accepted
date: 2026-09-29
---

# ADR-0018: HTML artifact プレビュー

## 決定

HTML / HTM は既存の preview pane に表示する。編集 buffer を `WKWebView` の
`loadHTMLString` に渡し、JavaScript を実行する。editor 本体の描画・入力経路には
WebView を使わない。

base URL はプレビュー対象ファイル自身のフォルダに限定する。`<script src>` /
`<link href>` などの相対パスは同じフォルダ内のファイルだけ解決でき（`..` や
symlink で Project の外へは出られない）、フォルダの外や他のプロジェクト、Mac の
他の場所は読めない。プレビュー内のページ遷移は止め、ユーザーがクリックした
http / https / mailto リンクだけ既定のアプリへ渡す。WebView のデータストアは
非永続にする。

JavaScript とリモートリソースはネットワーク通信できる。これはユーザーが
JavaScript 実行を選んだ際の実行範囲であり、preview pane のページ遷移制御で
通信まで遮断できるとは扱わない。

## 理由

HTML artifact のインタラクションを Clair 内で確かめられるようにするため。
既存の Markdown / CSV preview と同じ pane 操作を使い、editor の性能上の
不変条件を維持する。local file の参照を必要とするサイト全体のプレビューは
別の設計課題とする。
