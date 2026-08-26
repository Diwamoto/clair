# Architecture

実装済みシステムの現在の構成、componentの責務、公開interface、data/control flow、所有境界を記述します。

architecture文書は「今どうなっているか」を説明し、判断の経緯は関連ADRへリンクします。実装と食い違ったままprojectを `complete` にしません。

想定する文書:

- `overview.md`: システム全体像
- `system-boundaries.md`: Swift、Rust、sidecar、external serviceの境界
- `terminology.md`: domain用語
