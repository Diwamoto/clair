---
title: "Agent の HTML preview 要求を CLI と承認ゲートに通す"
status: accepted
date: 2026-09-29
---

# ADR-0019: Agent の HTML preview 要求

## 決定

`clair preview <html-path>` は一つの `file.preview` command として、file を開き
HTML preview pane を表示する。相対 path は CLI の作業ディレクトリで解決する。
正規化後の実ファイルが `.html` または `.htm` であることを確認する。

CLI からの `file.preview` は、`CLAIR_TERMINAL_KEY` の有無にかかわらず GUI の
承認ゲートを通す。MCP には公開しない。`clair open` の従来の承認条件は変えない。
生成した artifact を Clair で表示できることは `clair-preview` skill で agent に案内し、
既存の Agent skill インストール操作で配布する。

## 理由

HTML preview は JavaScript とネットワーク通信を実行できる(ADR-0018)。
caller 環境変数だけを承認要否の根拠にすると、agent が変数を外した CLI 呼び出しで
承認を回避できる。CLI の path 検証と GUI の承認を一つの command にまとめ、
file を開いてから別 command で preview する間の active file の変化も避ける。
