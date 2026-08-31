# Projects

GitHub issueを実装可能な単位へ変換したproject bundleを置きます。

PoC期間の通常の機能sliceは
[local feature queue](../plans/clair-poc-queue.md)だけで管理します。すべての機能を4文書へ
展開せず、重大なproduct/architecture判断、高riskなdata handling、複数componentにまたがる
契約、または後から独立してreviewする必要がある作業だけをproject bundleにします。

ディレクトリ名は `pNNNN-short-kebab-slug` とし、同じsource issueに対して重複したprojectを作りません。各bundleは [project templates](../_templates/project-readme.md) に従い、`README.md`、`requirements.md`、`design.md`、`plan.md` を持ちます。

project codeを変更すると参照と履歴が壊れるため、作成後は名称を固定します。scopeが大きく変わる場合は、既存projectを改名せず、新しいprojectへ分割して相互にリンクします。
