# Runbooks

development、release、migration、rollback、recoveryなど、人またはagentが再実行する操作手順を置きます。

各runbookには次を含めます。

- 適用条件と前提
- 必要な権限と安全上の注意
- 手順
- 成功確認
- failure時の停止条件とrecovery
- 最終検証日または検証対象version

設計理由はrunbookへ重複させず、関連ADRやarchitectureへリンクします。

Current runbooks:

- [Local development](local-development.md)
