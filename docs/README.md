# Clair documentation

このディレクトリは、Clairを「何のために作るか」「何を決めたか」「何を採用しなかったか」「現在どう動くか」を、issueの寿命に依存せず残すための正本です。

## 情報の置き場所

| 知りたいこと | 正本 |
|---|---|
| 仕様の正本(目的・原則・契約・完成の定義) | [clair-spec.md](clair-spec.md) |
| 実行順序と残りタスク | [clair-tasks.md](clair-tasks.md) |
| 進捗の可視化 | [clair-kanban.html](clair-kanban.html) |
| 1件のissueをどう実装可能な単位へ落としたか | [projects/](projects/README.md) |
| 現在のシステム構成と境界 | [architecture/](architecture/README.md) |
| 何を、なぜ選び、何を選ばなかったか | [decisions/](decisions/README.md) |
| 判断前の比較、spike、技術調査 | [investigations/](investigations/README.md) |
| 再現可能な性能データ | [benchmarks/](benchmarks/README.md) |
| 複数projectをまたぐ順序や移行計画 | [plans/](plans/README.md) |
| release、migration、recoveryなどの操作手順 | [runbooks/](runbooks/README.md) |

GitHub issue は必要な場合だけ課題、議論、外部共有を扱います。実装順序と状態は
[clair-tasks.md](clair-tasks.md) を正本とし、issue 作成や project bundle 作成を機能開発の
前提にしません。issue 本文と docs が食い違う場合は、明示的な新しい決定がない限り
[clair-spec.md](clair-spec.md)、[clair-tasks.md](clair-tasks.md)、accepted ADR を実装の基準にします。

## Project bundle

issueから実装へ渡す単位をprojectと呼びます。各projectはbranch名に似た一意なコードを持ちます。

```text
pNNNN-short-kebab-slug
```

例: issue #12のeditor基盤選定なら `p0012-editor-foundation`。推奨branchは `project/p0012-editor-foundation` です。project codeは追跡用IDであり、それ自体はbranchの作成や切り替えを指示しません。

各projectには次の4ファイルが必須です。

```text
docs/projects/<project_code>/
├── README.md
├── requirements.md
├── design.md
└── plan.md
```

- `README.md`: source issue、status、成果、関連文書、readiness、完了記録
- `requirements.md`: goals、non-goals、制約、受け入れ条件、明示的な対象外
- `design.md`: 現状、提案設計、境界、代替案、不採用理由、risk、rollout
- `plan.md`: 依存順の実装slice、受け入れ条件との対応、検証方法

## Project status

```text
draft -> ready -> in-progress -> complete
                   └──────────> blocked
```

- `draft`: 設計中。実装を変え得る未決事項がある
- `ready`: 重大な意思決定を追加せず実装できる
- `in-progress`: 実装または検証中
- `complete`: 全受け入れ条件を実装・検証し、関連docsも現在の状態を表す
- `blocked`: 外部依存または追加決定がないと進められない

`blocked` は「まだ終わっていない」の別名にはしません。blocking questionと解除条件をprojectのREADMEに明記します。

## 標準フロー

1. [clair-tasks.md](clair-tasks.md) から dependency-ready なタスクを選ぶ(`clair-task` skill)。
2. Reversible な変更は queue の outcome と functional check だけで実装する。
3. Product、安全性、互換性、data migration、cross-component interfaceの判断が必要な場合だけ、
   project bundle、investigation、ADRを追加する。
4. 実装中の事実に合わせてqueue、architecture、runbookを更新する。
5. Sliceの機能checkを通してcommitし、次のdependency-ready sliceへ進む。
6. Performance corpusと反復計測はfinal load-test phaseでまとめて実行する。

## 文書化のルール

- 事実、決定、仮定、未決事項を区別する。
- 現在の構成はarchitecture、過去の判断理由はADRに書く。
- accepted ADRは履歴として残す。変更時は新しいADRでsupersedeする。
- 不採用案は、それを比較したdesignまたはADRの中に理由とともに残す。
- issueのチェックリストをplanへコピーしない。実装順序と検証可能なsliceへ分解する。
- raw benchmark結果をADRへ貼り込まず、benchmarkからADRへ要約とリンクを置く。
- 小さなprojectでも4つの必須ファイルを省略せず、内容を短くする。
- 文書は原則としてsource issueの言語に合わせ、同一project内で混在させない。

## Templates

- [Project README](_templates/project-readme.md)
- [Requirements](_templates/requirements.md)
- [Design](_templates/design.md)
- [Implementation plan](_templates/plan.md)
- [ADR](_templates/adr.md)
- [Investigation](_templates/investigation.md)
