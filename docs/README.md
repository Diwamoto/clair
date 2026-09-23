# Clair documentation

このディレクトリは、Clairを「何のために作るか」「何を決めたか」「何を採用しなかったか」「現在どう動くか」を、issueの寿命に依存せず残すための正本です。

## 情報の置き場所

| 知りたいこと | 正本 |
|---|---|
| 仕様の正本(目的・原則・契約・完成の定義) | [clair-spec.md](clair-spec.md) |
| 実行順序と残りタスク | [clair-tasks.md](clair-tasks.md) |
| 進捗の可視化 | [clair-kanban.html](clair-kanban.html) |
| 何を、なぜ選び、何を選ばなかったか | [decisions/](decisions/README.md) |
| 再現可能な性能データ | [benchmarks/](benchmarks/README.md) |
| タスク単位の実装計画 | [plans/](plans/README.md) |
| release、migration、recoveryなどの操作手順 | [runbooks/](runbooks/README.md) |

GitHub issue は必要な場合だけ課題、議論、外部共有を扱います。実装順序と状態は
[clair-tasks.md](clair-tasks.md) を正本とし、issue 作成を機能開発の前提にしません。issue 本文と docs が食い違う場合は、明示的な新しい決定がない限り
[clair-spec.md](clair-spec.md)、[clair-tasks.md](clair-tasks.md)、accepted ADR を実装の基準にします。

## 標準フロー

1. [clair-tasks.md](clair-tasks.md) から dependency-ready なタスクを選ぶ(`clair-task` skill)。
2. Reversible な変更は queue の outcome と functional check だけで実装する。
3. Product、安全性、互換性、data migration、cross-component interfaceの判断が必要な場合だけ、
   planまたはADRを追加する。
4. 実装中の事実に合わせてqueue、spec、runbookを更新する。
5. Sliceの機能checkを通してcommitし、次のdependency-ready sliceへ進む。
6. Performance corpusと反復計測はfinal load-test phaseでまとめて実行する。

## 文書化のルール

- 事実、決定、仮定、未決事項を区別する。
- 現在の構成はspec、過去の判断理由はADRに書く。
- accepted ADRは履歴として残す。変更時は新しいADRでsupersedeする。
- 不採用案は、それを比較したdesignまたはADRの中に理由とともに残す。
- issueのチェックリストをplanへコピーしない。実装順序と検証可能なsliceへ分解する。
- raw benchmark結果をADRへ貼り込まず、benchmarkからADRへ要約とリンクを置く。

## Templates

- [Implementation plan](_templates/plan.md)
- [ADR](_templates/adr.md)
