# NE-10 suggestion model evidence

検証日: 2026-09-08

## Fixture

モデル境界のfake providerへ次の本文を渡した。

- base: `zero\r\n🙂 old\r\nremove\r\nkeep\r\n`
- proposed: `inserted\r\nzero\r\n🙂 new\r\nkeep\r\nadded\r\n`

行差分には先頭追加、emojiを含む置換、削除、末尾追加が含まれる。別fixtureで結合文字、末尾改行、独立した2 hunkも確認した。

## Checks

1. `ProjectEditorSuggestionModel`がfixtureを変更行のUTF-16範囲へ変換し、期待旧文字列と置換文字列を保持する。
2. 行選択とhunk選択は`ProjectEditorDocumentModel.apply`へ一つの`.suggestion` transactionとして渡る。
3. partial apply後のremaining proposalは新revisionと現在本文を基準に再計算され、旧提案のID/範囲を流用しない。
4. remaining proposalの全適用でproposed本文と一致する。
5. 適用を二回行った後も各適用を一回のUndoで戻し、最終的にbase本文へ戻る。
6. rejectは本文を変更せず、部分rangeは`unsupportedPartialSelection`を返す。
7. manual edit、external snapshot、Undo後にbase revisionが変わった古い提案を拒否する。

結果: すべてpass。加えて、Clair DevのXCTestでNE-10の6件、既存bridgeの5件、native integrationの1件を実行し、12件すべて成功した。実行コマンドはNE-10本文の「検証結果」に記録した。これはfake/モデル境界の証跡であり、実AI APIへの送信を含まない。

## Known limitation

実AI APIへの送信、提案preview UI、本番AI command adapterへの接続はNE-20の対象であり、ここではfake providerと検証可能なモデル境界までを確認した。
