# Architecture Decision Records

複数の合理的な選択肢があり、将来の実装や複数componentへ影響する判断をADRとして残します。

ファイル名は `NNNN-short-kebab-title.md` とし、次の未使用番号を採番します。番号は意味や優先度を表さず、作成後に振り直しません。

Status:

- `proposed`: 検討中
- `accepted`: 現在有効
- `superseded`: 新しいADRに置き換えられた
- `deprecated`: 対象自体が使われなくなった

accepted ADRの結論を後から書き換えて履歴を消しません。方針変更は新しいADRを作り、旧ADRと相互に `supersedes` / `superseded_by` を設定します。不採用案だけのファイルやフォルダは作らず、採用判断を行ったADR内の比較として残します。

作成には [ADR template](../_templates/adr.md) を使います。
