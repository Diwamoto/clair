# Clair Native Editor PoC 調査・検証結果

2026-09-08。**推奨は通常エディタの条件付き採用候補として継続。本番への全面置換は現段階では行わない。diffは現行経路を残して別段階で移行する。** CodeEditSourceEditor + CodeEditTextViewを第一候補とするが、ライセンス確認、実IME、初回ハイライト待ち、メモリ、ホスト全体での同条件測定を採用ゲートとする。VS Code相当の総合性能を達成したとは結論しない。

PoCでは6言語のTree-sitterハイライト、範囲変更通知によるコメント追跡、複数カーソルのUndo補正、固定AI提案の承認・却下・部分適用、左右diffの共通行配置を実装・実行できた。ネイティブ化の価値は確認できる。一方で、単にviewを入れ替えるだけでは性能・入力・配布の条件を満たさない。

## 作業の隔離と比較対象

- 作業場所: `/Users/daiki/.codex/worktrees/afc2/clair`。開始時クリーンな既存の隔離worktree、detached HEAD `d4fe851fb85f2e4e06993b53934b31c3a378fb97`。
- 変更は`prototypes/native-editor-poc`のみ。本番Swift、editor-web、元の未コミット変更を編集・破棄していない。公開・push・リリースなし。
- 元チェックアウト: `/Users/daiki/Projects/clair`。開始時点の状態と重要ファイルのSHA-256は [baseline.json](evidence/baseline.json)。別作業による変更との混同を避けるため、HEADだけで未コミット実装を識別しない。
- 比較A: 上記HEADのCodeMirrorEditor/NativeEditor/ContentView。ソース調査対象。コミット時点のdiffはSwiftUIの`ScrollView + Text`によるunified patch表示。
- 比較B: 元チェックアウトの未コミット版`editor-web/src/diff-main.ts`, `diff.ts`, `native-bridge.ts`など。unified patchを解析し、CodeMirrorのガターと行装飾で表示する。左右独立編集用のMergeViewとは異なる。凍結した実ビルド資産は [web-baseline.json](evidence/web-baseline.json) で識別し、`.build/baseline-web`に保存。
- 比較C: CodeEditSourceEditor固定revision、依存解決は [Package.resolved](Package.resolved)。実測PoCのソースは本ディレクトリ。
- 比較D: ローカルのVS Code 1.136.1。専用user-data-dirとextensions-dir、開発用の小さなベンチマーク拡張のみ。通常のユーザー環境は変更しない。

**Web測定はClairの現行資産を載せたWKWebViewハーネスであり、Clair全体の測定ではない。** Swift側の全文代入・SwiftUI再描画、プロジェクトのバックグラウンド処理は含まれない。全体での公平な比較は未検証。

## 移行経緯と現状

[ADR-0001](../../docs/decisions/0001-adopt-swiftui-appkit-frontend.md)は、SwiftUIを一般的な画面、AppKitを高頻度・macOS固有ビューに使い、エディタのIME・Unicode・large fileを実測する方針。ADR-0010による置換はRust core再利用条項だけで、frontend選択は有効。

`NativeEditor.swift`には文書・保存・ローカル履歴などの基盤に加え、従来の`NSTextView` wrapperと正規表現によるハイライトが残る。編集後に`textView.string`を文書へ渡し、ハイライト時も全文の状態を比較する。IME marked text中のハイライト回避がある。これをそのまま再有効化しても今回の性能・品質要件の解決にはならない。

履歴では`245193c`でnative syntax highlighting、`06d96a2`でCodeMirror埋め込み、`e64f678`で独自URL schemeによる資産配信を導入。基準HEADの通常表示は`ContentView`から`CodeMirrorEditorView`を使う。

`editor-web/src/main.ts`の`update.docChanged || update.selectionSet`から`notifyChange`を呼び、`doc.toString()`を含むmessageを送る。Swift側では`lastRenderedContent`との照合と`ProjectEditorTab`更新を行う。文書切替の`setDocument`はEditorStateを再作成する。Web版の良し悪し全体ではなく、**このClair integrationにある全文通知とstate再生成**が改善対象である。CodeMirror自体はincremental transaction / persistent EditorStateを持つため、Webを残す段階でも修正できる。

## 固定依存・ライセンス

直接・間接依存のrevisionとライセンスファイルのハッシュは [dependencies.json](evidence/dependencies.json)。バイナリgrammarのソース側解決記録は [grammar-source-pins.json](evidence/grammar-source-pins.json)。後者だけで配布バイナリとの完全な対応・全license noticeの収録を保証しない。

|依存|実解決|確認結果|
|---|---|---|
|CodeEditSourceEditor|`1fa4d3c3ffba007482111466cb9721416f97ae00`|MIT。READMEはproduction readyではないと明記|
|CodeEditTextView|0.12.1 / `d7ac3f11…`|MIT。AppKit + CoreTextの独自text/layout/selection/Undo。NSTextView互換ではない|
|CodeEditLanguages|0.1.20 / `331d5dbc…`|バイナリgrammarとquery資産。取得したrootにLICENSEが見つからず、包括的な配布許諾は未解決|
|CodeEditSymbols|0.2.3 / `ae69712b…`|取得したrootにLICENSEが見つからず、アイコンを含む許諾確認が必要|
|SwiftTreeSitter|0.25.0|BSD-3-Clause|
|tree-sitter|0.25.10|MIT。内部Unicode noticeも別に存在|
|TextFormation / TextStory / Rearrange|0.9.0 / 0.9.2 / 2.1.1|BSD-3-Clause|
|swift-collections|1.6.0|Apache-2.0（取得LICENSEを確認）|
|SwiftLintPlugin|0.65.0|MIT、ビルド時依存|

上位2パッケージがMITというだけで全grammarやSymbolsの再配布を許可済みとは扱わない。**本番配布の採用ゲート**は、未確認の許諾、grammar別notice、バイナリとソースpinの対応を確認すること。全grammar入りバイナリはPoCで利用したが、必要言語だけをソースからビルドする構成も移行案に含める。

第一候補の参照: [SourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor/tree/1fa4d3c3ffba007482111466cb9721416f97ae00)、[TextView](https://github.com/CodeEditApp/CodeEditTextView/tree/d7ac3f11f22ec2e820187acce8f3a3fb7aa8ddec)、[Languages](https://github.com/CodeEditApp/CodeEditLanguages/tree/331d5dbc5fc8513be5848fce8a2a312908f36a11)。Web検索結果のfeature一覧ではなく、固定した実ソースとPoC結果を区別した。

## 構成と公開API

`Document`が`TextViewController`を保持し、内部のtext storage、selection manager、CEUndoManager、scroll viewをタブごとに残す。SwiftUIのString bindingは使わない。文書を空で生成→表示領域を確定→初回だけ`setText`→以後は範囲編集、という構成。全文snapshotは初回ロード・保存・明示的なdiff提案生成だけ。

|要件|公開APIで実現した経路|追加保守|
|---|---|---|
|編集・選択・Undo|`textView`, `selectionManager`, `replaceCharacters`, `undoManager`|標準複数カーソルUndoを通知でグループ化する小さなadapter|
|全文同期の回避|`addStorageDelegate`, `NSTextStorageDelegate`のrange/delta|delegateだけではTextFormation経路を捕捉できないことを回帰テスト|
|行・範囲取得|`lineStorage.getLine(atPosition/atOffset)`とUTF-16選択|標準gutter自体はcontroller内部なので左に独自railを置く|
|コメント追跡|文字変更range/deltaでanchor更新|重なった編集はorphan化。複数編集がまとめられた範囲も保守的に無効化|
|固定AI提案|文書revisionと範囲編集、明示的Undo grouping|残りの提案を再baseせず古いまま拒否。実サービス不要|
|ハイライト|TreeSitterClient、CodeLanguage、EditorTheme|CLI resource配置、初期可視範囲更新、async閾値の調整|
|左右diff|共通DiffRow配列＋2列NSTableView|独自projection。CodeEditSourceEditor内の既製左右diffを実証したものではない|

高頻度の選択通知は全文を取得しない。ストレージ通知からのrevision更新でも本文を読まない。Tree-sitterのread blockは4096 UTF-16文字程度の断片を読み、非main threadからはmain queueを待つ実装。したがって「コピーゼロ」「main threadを一切使わない」とは主張しない。

元のProjectEditorTabの保存、外部変更検知、履歴、LSP/AI boundaryと繋ぐ際には`content`を毎入力でPublished更新する設計を残さない。文書ownerへ差分操作とrevisionを渡し、保存時にsnapshotを取得する。既存の外部変更・失敗時の保存保護を維持する。Rust側にも常時全文コピーを置くなら利点を失う。

## 機能別結果

「合格」は記載したfixture/API範囲に限る。詳細は [checks.json](evidence/checks.json)、[benchmark-async.log](evidence/benchmark-async.log)。未検証をAPIの存在で合格へ変更しない。

|項目|判定|範囲・制約|
|---|---|---|
|Swift / Rust / TS / TSX / JSON / Markdown色分け|合格|各fixtureで複数色を確認|
|Swift複数行文字列・コメント|合格|文字列内の日本語/emoji、コメント継続行の指定色を検証|
|Rust nested comment / raw multiline string|合格|ネストコメントと日本語raw stringの指定色|
|TS template / TSX文字列・日本語コメント|合格|fixtureの指定tokenで確認。全言語構文やsemantic token品質を保証しない|
|Markdown fenced Swift injection|合格|fence内`let`、`hi`がSwiftのkeyword/string色|
|Unicode保存|合格|UTF-8 roundtrip、fixtureに家族emoji・結合文字を含む|
|marked text生成・確定|合格（合成API）|`setMarkedText`→`insertText`。OSの日本語IME候補UIを使ったテストではない|
|日本語IME変換・確定・取消・再変換|未検証（実IME）|候補位置、キー操作、再変換、タブ切替中のcompositionを実機で要確認|
|Unicodeの矢印・ドラッグ選択・削除|未検証（実操作）|UTF-16範囲の計算と保存からgrapheme操作の品質を推定しない|
|複数カーソル編集・Undo/Redo|条件付き合格|上流そのままの1回Undoは失敗。公開通知によるPoC grouping adapterで1回Undo合格|
|コメントの前に行追加、Undo|合格|TextFormationを含む文字変更をstorage通知で追跡|
|コメント対象の削除|合格（保守的仕様）|orphan化し誤った行へ付け替えない。削除Undo後の自動再接続は未実装|
|gutter横操作から行/範囲取得・コメント表示|合格（UI、限定fixture）|公開lineStorage、選択範囲を使用。折返し・折畳みの精度は未検証。PoCは折返しoff|
|左右diff追加/削除の位置合わせ|合格（モデル）|片側空欄、old/new行番号。両方向の挿入/削除を検証|
|diffスクロール同期|構成上共有、実行済み|同じ表の2列なので独立scroll offsetを同期する処理が不要。2つのCodeEdit editorの同期を実証したものではない|
|変更ブロック/行操作|固定サンプルで実装|1ブロック=1提案編集。任意hunkの部分置換・Git stage/unstageは未実装|
|AI承認・却下・部分適用|合格（固定提案）|全適用/部分適用、1回Undo、編集後や部分適用後のstale拒否|
|タブ状態保持|合格（API）|同じcontroller、選択、scroll、Undoを保持。IME中の切替は未検証|
|通常〜10MB、1MB長行、50タブ、大diff|実測あり|条件と未計測指標は次節。通常エディタとdiffが総合的にVS Code相当との判定は保留|

## 見つかった問題と対応

1. **生成時に大きい文字列を渡すと画面に載る前に大量の行viewを作る。** 最初の計測は90秒以上で1コアほぼ100%、physical footprint約758MiB。`TextView.init → TextLayoutManager.layoutLines → NSView.addSubview / z-order invalidation`を [sample](evidence/eager-constructor-sample.txt) に保存。空viewを配置後に`setText`する公開APIの経路へ変更して完走した。
2. **背景にNSColor.textBackgroundColorをそのまま渡すと例外。** minimapを非表示にしていても`brightnessComponent`を呼び、catalog colorで例外となった。RGB背景のthemeで回避。アプリが固まったのではなく、AppKitが初期化中の例外を捕捉してwindow setupが未完了だった。
3. **Swift CLIのリソース差異。** Symbolsの`Bundle.module`生成とLanguagesの`Resources/Resources`参照を補正。Parserだけ動作してもquery不在なら色が付かない。最終版は全6言語のqueryの存在と色を検証済み。
4. **初回可視範囲。** 遅延setText後に公開layout APIで配置を確定し、scroll bounds変更通知で可視highlightを更新。初期本文の再代入で毎回直す方法は使わない。
5. **編集delegateだけでは不十分。** TextFormationの改行は本文を変えるがdidReplace通知を通らず、anchorがずれた。公開storage delegateへ変更し、文字編集だけを追跡。属性変更でrevisionを増やさない。
6. **複数カーソルの自動Undo grouping不足。** 上流既定の失敗をexpected failureとして残し、通知adapter付きの成功を別に検証。通常入力経路に明示的groupを置く必要がある。複合IME・paste・列選択の全ケースは未検証。
7. **1MBの同期parse境界。** 既定の`maxSyncContentLength=1,000,000`はUTF-16長ベース。日本語を含む約1MB UTF-8 fixtureは同期領域に残り、入力中央値約26ms。10MBは非同期になる。`--async-policy`は公開定数を250,000へ下げると入力中央値3.61ms、p95 3.76msへ改善した。ただしscrollのp95は26.20msであり、全操作が16.7ms以内になったわけではない。

いずれもPoC側で再現可能な回避を入れたが、上流の破壊的変更に対するadapter回帰テストは必要。ライブラリをforkしてrendererを変更する作業はまだ行っていない。

## 測定条件・解釈

生データから生成した数値表は [MEASUREMENTS.md](MEASUREMENTS.md)。fixtureは [fixtures.json](evidence/fixtures.json) のbyte数/SHA-256で固定。

- 同じApple M4（10 logical CPU）、32GiB、macOS 26.6.2、arm64、Swift 6.3.3。Release build。ユーザーの他アプリは動作中で、完全idleやthermal状態を統制したラボ測定ではない。
- Nativeは約1164×710の本文可視領域、13pt monospaced、折返しoff、minimap非表示。VS Codeは独立profileの標準画面・標準settingsであり、本文viewport・font設定まで一致していない。
- Native入力は`replaceCharacters`＋同期display submission、VS Codeはextensionの`editor.edit`応答、Webは`evaluateJavaScript`往復。NativeとVS Codeの入力は先頭へのASCII1文字を20回。Webは現行公開bridgeでの選択移動を20回（入力との同一指標ではない）。
- Native first-highlightは20ms間隔で可視範囲に複数色が現れるまで待つ。全ファイルのsyntax解析完了や最終描画完了とは違う。max待機約10秒。全最終fixtureで複数色を確認。
- Nativeの2タブ往復はviewを外し再配置＋表示送信。VS CodeはshowTextDocument往復。通常fixtureではVS Codeのfirst docと対象docが同一になり、通常ファイルのタブ列は意味のある2タブ比較になっていない。数値は削除せず限界を明記。
- 各条件1プロセス1周、操作各20回。p95はnearest-rankで19番目。安定した回帰基準には複数回のcold/warm・統制された画面条件が必要。
- CPU秒はNativeプロセスの各fixture処理区間。RSSは先行文書も保持した累積maximumであり、そのファイル単独の必要メモリではない。Nativeの10MB段階で約1GiB、長行後約1.1GiBに達し、メモリ削減を実証していない。
- Webは専用WKWebViewと現在の元チェックアウトの配信済み資産。10MB setDocument往復約3秒、選択/scrollで秒〜数十秒の外れ値。高負荷のWebContentプロセスは約1.9GiB RSSを観測したが、CPU/RSSの揃った継続時系列は取れていない。
- Web10MBの20選択では本文209,714,700 bytesを受信。これは観測した転送量で、内部の全コピー量ではない。Web側のfirst-ready約439msは空資産のready通知まで。
- VS Codeは1.136.1、専用開発拡張で4fixture、50追加タブ、大diffを実行。UIで大diff表示とタブ生成を確認して終了。CPU/RSSの比較可能な時系列は未収集。

**未計測**: 実キー入力→最終glyph、frame time/drop、慣性scroll中の入力、実IMEの遅延、各アプリの同一設定cold/warm launch、Clair全体の初回表示・CPU/メモリ、各実装の等価なlarge diff処理完了。これらを推測値で埋めない。

## 代案

|候補|今回確認したこと|採用上の判断|
|---|---|---|
|CodeEditSourceEditor / CodeEditTextView|実アプリ、6言語、編集、拡張、計測。上記adapterが必要|通常エディタの第一候補を継続。大きい文書と配布はゲート未達|
|NSTextView / TextKit 2 + Tree-sitter|`NSTextView(usingTextLayoutManager:true)`でUnicode挿入、Swiftのquery captureによる基本色付け、TextKit2が維持されることを実行。window無しprobeのUndoManagerはnil|保険として成立。ただしincremental parser、injection、gutter、multi-selection editing、diffの組立てをClairが所有する。現時点で保守負担を理由に第一候補へ昇格させない|
|STTextView|固定ソース `0ac9121a3b4dba90c4920a8bcfe9ddf1fcc4b16a`を調査。AppKit/TextKit2、gutter、plugin入口、TreeSitter/Neon/Annotations pluginの公開案内。依存STTextKitPlus >=0.2.0、CoreTextSwift >=0.2.0|GPLv3 / 商用license。closed-sourceの現方針で無条件採用しない。商用条件の確認前に本PoCへ組み込まない。性能・IME・plugin実動作は未検証|

STTextViewのライセンスは [固定LICENSE](https://github.com/krzyzanowskim/STTextView/blob/0ac9121a3b4dba90c4920a8bcfe9ddf1fcc4b16a/LICENSE.md)、API・plugin一覧は [固定README](https://github.com/krzyzanowskim/STTextView/blob/0ac9121a3b4dba90c4920a8bcfe9ddf1fcc4b16a/README.md) を参照。GPL/商用という確認結果を、CodeEdit系のMITから類推しない。[AppleのTextKit2初期化API](https://developer.apple.com/documentation/appkit/nstextview/init(usingtextlayoutmanager:)) は標準APIだが、標準でIDE要件を満たす保証ではない。

## 推奨する段階移行

1. **先に文書ownershipを整理**: エンジン非依存のrevision/編集transaction/selection/保存snapshot APIを作る。Web側もselection通知から全文を外し、タブごとのEditorStateを保持。native migration前にも効く改善であり、fallbackの品質を保つ。
2. **通常ファイルのopt-in native**: 本PoCの公開API adapter、UTF-16 boundary、Undo grouping、read-onlyと保存失敗を既存ProjectEditorTabへ接続。必要grammarのlicense audit、実IME一式、UI選択のgrapheme検証を通す。大規模fileは閾値に基づく既存エディタfallbackを維持。閾値はUTF-8 byteだけでなく長行、UTF-16長、解析負荷も見る。
3. **性能の採用判定**: 同じ画面幅/font/wrap/minimap、複数の実コード、cold/warm各複数回、実キー→描画とフレーム時間、process treeのCPU/RSSを全ClairとVS Codeで比較。async閾値で入力は改善しても初回syntax待ちとメモリが残るため、grammar絞込み、parse scheduling、保持タブevictionを検討する。nativeをデフォルトにするのはこの後。
4. **diffを独立して移行**: まずread-onlyのunified/左右projection、行・hunkID、anchor、virtualization、wrap時の高さ、scroll対応表を実装。PoCの2列表は位置合わせの基礎として使えるがsyntax付きeditable paneではない。任意hunkの行単位適用、空行/末尾改行/CRLF/rename、stale文書、Undoを検証してから現行diffを置き換える。
5. **AI/コメント共通化**: 固定提案のrevision検証を本サービスにも使い、古い提案を文字列検索で自動的に別箇所へ適用しない。部分適用後の残りは再計算。コメントのorphan復元、複数deltaの正確な追跡、永続化と共有は別の仕様として扱う。

本PoCで成立した通常編集部分を捨てる根拠はない。一方で「依存を追加すれば既製diff・IME・VS Code級性能が揃う」という採用理由は成立しない。通常エディタを条件付きで進め、diffを後段へ分けるのが最も根拠のある移行案である。

## UI確認・終了

最終UIでMarkdown内Swiftの色分けを目視。3カーソルへ`X`を入力して1回Cmd-Zで復元、固定提案の先頭変更行をApply rowで適用してCmd-Zで復元した。行番号横クリックでUTF16 `{19,13}`の行コメント、`let x`選択後の同位置クリックで`{19,5}`の範囲コメントを作成。選択範囲を改行で置換すると両方がorphanになることをAX表示で確認した。OS日本語IMEの候補操作は実施していない。

VS Codeは専用開発ホストの大diffと54個の未保存fixture/tabを確認したうえでQuit。PoCもQuit。開発watcher・serverは起動していない。測定後の最終修正は初回caret位置・無効コメント範囲の拒否・未知拡張子のplain-text fallbackで、機能テストを再実行した。性能表はそれ以前のハイライトと編集経路の測定値であり、最終バイナリの再測定値とは区別する。
