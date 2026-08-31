# Clair benchmark corpus

この corpus は ccedit V1 と Clair の同一 workload 比較に使う synthetic fixture です。
大容量ファイル本体は repository に保存せず、次の command で ignored build directory に生成します。

```sh
bash scripts/benchmarks/generate-corpus.sh --output .build/benchmarks/corpus
```

既存 directory が空でない場合、誤って測定データを上書きしないよう generator は停止します。
新しい測定では新しい output directory を使ってください。

## Contents

| Path | Contract |
|---|---|
| `large-files/text-10MiB.txt` | exactly 10,485,760 bytes of deterministic text |
| `large-files/text-100MiB.txt` | exactly 104,857,600 bytes of deterministic text |
| `unicode/unicode-fixture.txt` | CJK、emoji、combining mark、full-width、wide glyph、box drawing の rendering fixture |
| `unicode/ime-operations.json` | marked-text の更新・commit・cancel と UTF-8/UTF-16/grapheme offset contract |
| `terminal/flood-1MiB.txt` | terminal flood 用の exactly 1,048,576-byte payload |
| `terminal/osc-sequences.bin` | OSC 52 clipboard と OSC 633 shell-integration marker の byte fixture |
| `file-tree/` | 10,000 deterministic files（10 modules × 20 packages × 50 files）|
| `git-status/` | local Git fixture with modified/deleted/renamed/untracked state |
| `MANIFEST.json` | generator version、relative path、byte size、SHA-256、Git fixture status |

## Stability rules

- Generator versionを変更した場合は、既存結果を上書きせず新しい result directory を使います。
- File path、byte size、Unicode sequence、Git status mutation の順序を任意に変更しません。
- corpus は user repository の中へ生成せず、`.build/benchmarks/` または明示的な temporary directory に置きます。
- raw result には corpus の absolute path を保存せず、manifest の digest と generator version だけを記録します。

## File-tree profiles

`file-tree/` は 200 directory、10,000 file、root 以下 3 level の synthetic stress profile です。
512-file smoke fixture ではなく、tree enumeration、watcher、Quick Open、find、Git UI の負荷を同一形状で比較するために使います。
実利用 repository の統計をコピーしたものではないため、「一般的な project を代表する」とは主張しません。
file count、directory count、depth は `MANIFEST.json.file_tree_profile` に保存します。

## Unicode、IME、terminal fixtures

`unicode-fixture.txt` は静的 rendering の入力です。IME lifecycle は別の
`ime-operations.json` を正本とし、marked text の更新、commit、cancel と、expected text、
UTF-8 byte、UTF-16 code unit、grapheme boundary を同じ順序で検証します。

terminal は `flood-1MiB.txt` を固定回数送る workload と、実 byte の OSC 52/633 fixture を使います。
clipboard を変更する OSC 52 は benchmark-only pasteboard の内容を事前退避し、測定後に復元できる UI driver でのみ実行します。

## Git fixture state

`git-status/` は generator が local user identity を設定して baseline commit を作り、その後に次の状態を作ります。

- one tracked file modified in place;
- one tracked file deleted;
- one tracked file renamed;
- one untracked file added.

これにより V1/Clair の status scan、diff、file tree が同じ状態を観測できます。fixture 内の Git metadata は測定後に破棄できます。
