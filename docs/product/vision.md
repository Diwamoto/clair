# Clair product vision

## 存在理由

Clairは、Daikiが会社と自宅のどちらでも、不自由なくAIを使って開発するためのpersonal native macOS IDEである。

DaikiはVS Codeのeditor、navigation、Git、debugging等の統合体験を必要としている。一方、複数のClaude Code、Codex、OpenCodeを並列に動かす作業では、Ghosttyのterminalとpane操作のほうが自然である。別々のアプリを行き来すると、Project、terminal、agent、worktree、diff reviewのcontextが分断される。会社ではClaude Code中心の運用となり、自宅ではPCに触れられる時間が限られるため、Macを離れた後もagentを進められることにも価値がある。

ClairはVS CodeとGhosttyを並べて使うのではなく、それぞれの必要な性質を一つのProject workspaceへ統合する。

## 目指す成果

利用者は一つのClairで複数Projectを保持し、Projectごとのeditor、terminal、agent、Git状態、pane layoutを切り替えられる。任意数のraw-terminal agentを起動し、必要な場合だけmanaged worktreeで変更を隔離し、branch全体をreviewして採用できる。

Clairはagent固有のchat UIを正本にしない。通常のshellと各CLIのraw terminalをそのまま使えることを保証し、その周囲にProject ownership、起動導線、通知、diff review、command automationを加える。

Clairの全操作はtyped Command Registryに定義される。人間はcommand palette、menu、任意のkeyboard shortcut、`clair` CLIから同じ操作を実行できる。AIはMCPを通じて明示的に公開されたcommandを利用できる。

## cceditとの関係

Clairはcceditの別frontendではなく、ccedit v2として製品を置き換える後継である。cceditのRust coreとterminal基盤はClairへ移管して再利用し、SwiftUI/AppKitのnative macOS frontendへ置き換える。ClairでClairを日常的に開発できた時点でcceditを廃止する。

## 成功の判断

最初の成功はfeature parityの数字ではなく、次の状態で判断する。

- Clair Stableを使ってClair repositoryを開き、Clair Devを別bundleとしてbuild・起動し、変更を確認できる。
- editor、複数terminal、複数agent、任意worktree、branch reviewの開発loopがClair内で完結する。
- 日常操作の体感がcceditより明確に快適である。
- cceditへ戻らずClairの開発を継続できる。

Go language intelligence、mobile、debugger、Dev Containerは重要だが、ccedit廃止の条件にはしない。
