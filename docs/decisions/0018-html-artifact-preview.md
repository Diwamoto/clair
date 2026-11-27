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

## Addendum (2026-11-27)

`loadFileURL` でフォルダの読み取りを許可してから `loadHTMLString` する方式は、最初の読み込みが
「Frame load interrupted」で空白になり(編集するまで CSS も出ない)、Project 外のファイル
(`clair preview` した agent の artifact)には base URL が付かなかった。WebKit の file:// 許可に頼らず、
`clair-preview://file/` を base URL にして Clair の scheme handler がプレビュー対象ファイル自身のフォルダの
ファイルだけを返す(`..` と symlink で外に出る path は返さない)。同一 origin なので `fetch` と ES module も
同じフォルダ内で動く。判断シートの選択肢の HTML も同じ WebView を使う。
