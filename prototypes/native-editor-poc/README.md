# Clair Native Editor PoC

本番エディタを変更せず、CodeEditSourceEditor / CodeEditTextView + Tree-sitterを評価する独立macOSアプリ。結果・推奨は [REPORT.md](REPORT.md)。外部AI接続、公開、リリースは行わない。

## 起動

macOS 14以上、XcodeのSwift toolchainが必要。検証環境はmacOS 26.6.2、Swift 6.3.3、Apple M4 / 32 GiB。

```sh
cd prototypes/native-editor-poc
swift package resolve
python3 prepare-build.py
swift build -c release
python3 make-fixtures.py
./run.sh fixtures/normal.swift fixtures/sample.rs fixtures/sample.ts fixtures/sample.tsx fixtures/sample.json fixtures/sample.md
```

`Package.resolved`とSourceEditorのrevisionを保持すること。初回取得はCodeEditLanguagesのGit履歴で数GB、展開済みバイナリ資産も約588 MBを使った。`prepare-build.py`はPoC配下のSPMチェックアウトのSymbols資産宣言だけを補正する。`package-app.py`はSwift CLI用のbundle配置を補正する。いずれも本番Clairを変更しない。独自Symbolsアイコンの表示は保証しない。

`run.sh`は専用ロックで重複起動を拒否。Quitまたはウィンドウを閉じて終了する。計測モードは自動終了する。アプリbundleは`.build/Clair Native PoC.app`に生成されるが、再現性と二重起動防止のため`run.sh`を使う。

## 操作

- **Open**: UTF-8ファイルを別タブとして読み込む。タブはcontroller/文書/Undo/selection/scrollを保持。
- **Multi**: 先頭3行にカーソルを置く。文字入力、Cmd-Z、Shift-Cmd-Zを試す。
- **行番号の左の細い領域をクリック**: 選択がある場合はそのUTF-16範囲、なければクリック行をコメント対象にする。オレンジの印と下部の範囲・本文で表示。**Comment**は現在の選択範囲に追加。
- **Propose / Diff**: 文書の先頭・末尾にコメントを挿入する固定AI提案。左右は同じ表の行・スクロールを共有し、片側にない行は表示専用の空欄となる。
- **Apply row / Apply block**: 変更行を選択して部分適用。固定サンプルでは1ブロック＝1編集なので共通経路。**Apply all**は全適用。**Reject**は破棄。
- 部分適用後の残りは意図的に古いrevisionのまま。再提案が必要。Editorへ戻って編集してから適用すると拒否される。
- **Save as**: UTF-8で別名保存。IME変換中は拒否。本番の外部変更検出・ローカル履歴との統合はPoC外。

## 自動検証と計測

```sh
./run.sh --self-test > evidence/checks.log 2>&1
./run.sh --benchmark > evidence/benchmark.log 2>&1
./run.sh --benchmark --async-policy > evidence/benchmark-async.log 2>&1
python3 summarize-results.py
python3 audit-dependencies.py
```

上流そのままの複数カーソルUndoは`expectedFailure: true`として失敗を記録し、PoCアダプター付きの同じ操作は合格を要求する。他の必須テストが失敗した場合、終了コードは1。TextKit 2の小さな代案検証は補足結果として別に保存する。実IME操作の合否を合成marked-text APIテストから推定しない。

ベンチマークは各サイズの文書を順次保持。各操作20回、起動1回。初期表示の同期処理、可視範囲の色付け検出、編集API、スクロールAPI、2タブ往復を計測する。画面の最終ピクセルが更新されるまでの時間ではない。50タブを開き、大きいdiffの配置計算・表示・スクロールも測る。結果の生データはJSON。

## Web / VS Code比較

```sh
# 原本を読み取るだけ。既に凍結した比較資産があれば上書きしない。
python3 freeze-web.py
./run.sh --web-benchmark > evidence/web.log 2>&1

# 別ターミナル。普段のVS Codeの設定・拡張機能は使わない。
'/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code' \
  --user-data-dir /tmp/clair-poc-vscode-profile \
  --extensions-dir /tmp/clair-poc-vscode-extensions \
  --extensionDevelopmentPath="$PWD/vscode-benchmark" \
  --new-window "$PWD/fixtures"
```

VS Codeは`evidence/vscode-done.txt`生成後に終了すること。fixtureに対する変更は保存しない。再測定時は新しい一時profileを使う。Web測定は120秒を超えて進行しない場合、中断し測定不能として記録する（スクリプトの内蔵タイムアウトではない）。ユーザーの他のWebKitプロセスを終了しない。

Webハーネスは元のチェックアウトの凍結した`EditorWeb`資産を使う。`freeze-web.py`のsourceは環境に合わせて変更可能だが、`web-baseline.json`のハッシュが変わると別の比較対象になる。本番ClairのSwiftUIホストやSwift側の文書同期は含まない。VS Codeとの操作完了境界も違うため、表の数字を速度比にしない。

## 手動検証手順

1. 日本語IMEで「にほんご」を変換、候補変更、確定、Esc取消、再変換。候補ウィンドウとカーソル位置、他タブへ切替後の復帰も確認。
2. 絵文字の家族シーケンスと結合文字を左右移動・選択・削除。Undo/Redoと保存再読込を確認。
3. コメントの前に改行を追加・削除。対象自体を削除するとorphanになることを確認。PoCはorphanからの自動復元をしない。
4. 変更行で部分適用し、Undoで全体が戻ることを確認。適用前に文字を入力してから古い提案を適用すると拒否されることを確認。
5. 同じfixtureで各エディタの初回表示・入力・スクロール・タブ切替を録画/計測する。キー→描画遅延、フレーム落ち、IMEの体感は本JSONから判断しない。
