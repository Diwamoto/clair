# Clair product principles

## 1. Projectがworkspaceの所有単位

一つのClair processは複数ProjectをChromeのtab groupのように保持する。ProjectはGit repositoryでなくてもよい。各Projectは独立したeditor、terminal、agent、notification、pane layoutを持ち、非表示中も明示的に終了されるまでsessionを継続する。

## 2. Editorとterminalを同格に扱う

Clairはagent dashboardではない。各paneはeditor、terminal、diffを混在できるtab groupであり、任意にsplit、移動、最大化、幅・高さの均等化ができる。file tree、search、Git等はsidebarを標準とし、必要ならpaneへ開ける。

## 3. Raw terminalを互換性の正本にする

通常shell、Claude Code、Codex、OpenCodeはraw PTYとして完全に使えることを優先する。agent内容をTUI screen scrapingで推測しない。process lifecycle、terminal bell、終了code、Claude Codeの公式hooks等、根拠のある情報だけを補助表示と通知に使う。

## 4. 独自editorがClairの価値を作る

Clairは外部editorを前提にしない。agentによるfile変更のlive反映、branch diff、native merge editor、Project/pane integrationをClair自身が所有する。VS Code extension互換は目指さず、言語機能はLSP、debuggerはDAP、containerはDev Container specificationを利用する。

## 5. Worktreeは任意のexecution context

worktreeはProjectやagentの必須所有単位ではない。agent起動時に通常のProject rootまたはmanaged worktreeを選ぶ。同じworktreeで複数terminal・複数agentを動かしてよい。managed worktreeはClairのlocal管理領域に置く。

## 6. Branch全体を成果物としてreviewする

managed worktreeの成果はbase branchに対するbranch全体のdiffとしてreviewする。commit済みと未commit/untrackedを分けて表示し、統合前にはcleanなcommit状態を要求する。採用はmerge commitで行い、conflictはnative merge editorまたはagentへの再依頼で解決する。

## 7. すべての操作をcommandにする

Clairが実行可能な操作はstable ID、typed parameter/result schema、error、risk metadataを持つCommand Registryへ登録する。palette、menu、shortcut、CLI、MCPは同じcommandを呼ぶ。AIには`aiAvailable`なcommandだけを公開する。

危険性はAIに推測させず、commandの固定riskと対象状態を使うdeterministic preflightで判断する。write、destructive、external operationはClair自身が必要な承認を取る。

## 8. User controlと回復可能性を保つ

agentがdisk上のfileを変更した場合はその内容を正本とし、同じfileの未保存editor bufferは破棄してlive reloadする。ただし上書き前の内容はClairのlocal file historyから復元できる。

terminal transcriptはsession終了後に保存しない。通常のshell command historyはshell自身に任せる。Clairの状態はMac内の専用storageに保存し、repositoryを自動的に汚さない。

## 9. Personal、native、macOS-onlyを選ぶ

Clair v2はsingle user、自所有device、macOSに最適化する。Windows/Linux、team collaboration、account system、hosted agent、marketplace、VS Code extension互換のために中核を複雑化しない。

## 10. 体感とdogfoodingを判断材料にする

native化の合格線は、同じ作業をcceditより明確に快適に行えることとする。機能追加の優先順位は一般市場の網羅性ではなく、Clairを使った日常開発で繰り返し発生する摩擦から決める。
