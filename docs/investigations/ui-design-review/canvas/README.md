# Design canvas sources

このディレクトリは[UI design review](../README.md)のClaude Design canvasの正本である。

公開canvas: https://claude.ai/code/artifact/3fae5882-2b89-4ed4-acd4-8f9004befa26

## 構成

| ページ | ファイル | 内容 |
|---|---|---|
| Workspace | `Current.dc.html` | 現在のUIをsourceから再現し、指摘を番号で示したもの |
| Workspace | `Main.dc.html` | 提案するworkspace shell |
| Workspace | `SessionRail.dc.html` | 提案するsession rail |
| Workspace | `BranchReview.dc.html` | branch reviewを全幅main areaへ移した案 |
| System | `Tokens.dc.html` | design token、type scale、chrome budget、latency budget |
| System | `Palette.dc.html` | commandとファイル移動を統一したoverlay（選択が動く） |
| System | `Mobile.dc.html` | desktopと同じtokenを使うmobile画面 |

`canvas.json`がページ、配置、注釈を持つ。

色はすべて`apple/ClairApp/WorkspaceChrome.swift`の実測値である。実装のtokenを変えた場合は
このcanvasも合わせて更新する。

## 更新のしかた

`.dc.html`を編集してから再seedし、同じURLへ再publishする。seed後の
`clair-workspace-redesign.html`は約2.6MBのeditor payloadを含むためcommitしない
（`.gitignore`済み）。

canvas上でGUI編集してSaveした場合は、公開されているartifactを読み戻して
このディレクトリの`.dc.html`へ反映してから再seedする。そうしないと次のseedで
GUIの編集が失われる。
