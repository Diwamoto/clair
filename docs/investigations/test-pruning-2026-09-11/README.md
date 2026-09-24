# Clair 全テスト削除・統合監査（2026-09-11）

この文書は削除・統合前の静的監査記録。承認後の変更内容と検証結果は [execution.md](execution.md) を参照。以下の関数名・行番号・件数は監査時点のもの。未コミットのNativeEditor／Debug関連変更も含めて読んだ。

判断は「この検証を削ると、どの現実的な不具合が新たに見逃されるか」。件数・カバレッジは評価指標にしていない。定数の転記、未使用モデル、独立性のない往復、同一setupは積極的に削る。安全性・データ保持の実境界は、似た名前でも別経路なら残す。

確認範囲は、desktop XCTest 163、Mobile Swift Testing 30、Rust 32、隠しディレクトリ内のlease Pythonテスト3の計228関数に加え、Swift/Rust smoke、CI検査スクリプト、native-editor-pocの自己検査・診断。全関数の判定対応は [inventory.md](inventory.md)。editor-web／interaction-lab／workbenchに専用テストsuiteはなく、ビルド・型検査をテスト関数には数えていない。外部依存・生成bundle・保存済みevidenceは製品自身のテスト対象から除外した。

監査時点では静的調査のみで、全suiteの実行・時間計測・mutation testは実施していない。「高コスト」はソース上のGit/PTY起動、ファイルI/O、待機、巨大fixtureからの評価で、実測秒数ではない。既存の不安定さの発生頻度も未計測。削減後の検証は上記の実施記録に分けて記載した。

Dは現テストをそのまま削除できる候補、Mはassert移植・統合・置換・一部削除。Mの残す保証を移す前に一括削除してはいけない。関数を束ねるだけで時間・保守コストが減らない統合は勧めない。

## D01 — 製品から呼ばれないブリッジモデルの3テスト（削除）

対象：

- [apple/ClairTests/ProjectEditorWebBridgeTests.swift:7](apple/ClairTests/ProjectEditorWebBridgeTests.swift:7) — `testChangeUsesUTF16PreEditRangesAndAdvancesOnce`
- [apple/ClairTests/ProjectEditorWebBridgeTests.swift:31](apple/ClairTests/ProjectEditorWebBridgeTests.swift:31) — `testStaleChangeDoesNotMutateAndCanBeResynchronized`
- [apple/ClairTests/ProjectEditorWebBridgeTests.swift:64](apple/ClairTests/ProjectEditorWebBridgeTests.swift:64) — `testSelectionOnlyChangeDoesNotAdvanceRevisionOrCaptureSnapshot`

根拠：ProjectEditorWebBridgeModel の参照は定義とこの3テストだけ。製品の ProjectEditorTab.applyEditorChange は documentModel.apply(change.transaction()) を直接呼ぶ。テスト用の並行実装を検証している。

削除で見逃すもの：削除で失うのは未使用モデルの挙動の保証。製品の変更・保存・古いrevision拒否・選択は ProjectEditorWebNativeIntegrationTests、複数UTF-16編集は ProjectEditorDocumentTests が検証する。

処置：3テストを削除。未使用モデル自体の除去は別のコード整理として扱える。Webメッセージ型まで削除しない。

費用対効果：実行は軽いが、製品と無関係な実装・テストの二重保守を解消。

## D02 — 自分で指定したsnapshot reasonと呼び出し回数（削除）

対象：

- [apple/ClairTests/ProjectEditorDocumentTests.swift:139](apple/ClairTests/ProjectEditorDocumentTests.swift:139) — `testSnapshotReasonsAreExplicitBoundaries`

根拠：自分で .initialLoad/.save/.diff を渡し、返却reasonとカウンター3を確認するだけ。実際の保存・diff境界から呼ばれたかは検証していない。

削除で見逃すもの：reasonの転記やテスト専用カウンターの故障だけ。余計な全文コピー、保存漏れなどは現状でも捕捉できない。

処置：丸ごと削除。selectionのrevision・イベント重複排除テストは残し、そこにあるsnapshotCaptureCount依存も削除候補。

費用対効果：低実行コスト、内部計測用APIへの結合が主な負担。

## D03 — 更新ヘルパー内の文字列検索（削除）

対象：

- [apple/ClairTests/ClairUpdateTests.swift:153](apple/ClairTests/ClairUpdateTests.swift:153) — `testUpdateHelperContainsBoundedWaitAndRollbackPath`

根拠：old_moved=0、wait_count、mv の断片を contains で探すだけ。到達不能コードやコメントに残っていても成功する。

削除で見逃すもの：特定の記述の消失は見逃すが、ロールバック不履行・待機無限化という実害は元から保証していない。

処置：現テストを削除。更新の回復保証が必要なら、一時appディレクトリでヘルパーを実行する振る舞いテストを別途設計する。現テストをその完成まで残す価値は低い。

費用対効果：実行は軽いが、正当なシェルリファクタリングに追随が必要。

## D04 — プロフィール定義の丸写し（削除）

対象：

- [apple/ClairTests/AgentWorkflowTests.swift:7](apple/ClairTests/AgentWorkflowTests.swift:7) — `testFixedProfilesExposeStableIdentityAndLaunchDetails`

根拠：allの順序、表示名、実行名、空arguments、候補モデル配列、スラッシュコマンドを定義どおり再掲している。

削除で見逃すもの：表示順・表示名・モデル候補の意図しない変更は見逃す。一方、実際にCLIが起動するか、モデルが利用可能かは検証しない。stableIDの互換性は永続化fixtureに集約する方が有用。

処置：丸ごと削除。シェル引数の安全性テストと実行経路は維持。stableIDはM04の永続化fixtureに含める。

費用対効果：設定変更のたびの二重修正を解消。

## D05 — NSTextViewのsetter/getterと初期設定（削除）

対象：

- [apple/ClairTests/TerminalTests.swift:9](apple/ClairTests/TerminalTests.swift:9) — `testTerminalTextViewInitializesAndAcceptsTranscript`

根拠：stringへ代入した値を読み戻し、isEditable/isSelectableの定数を確認するだけ。

削除で見逃すもの：選択・編集可否の設定ミスは見逃すが、キー入力のPTY配送や描画不良は検証していない。低価値の設定確認として削る。

処置：丸ごと削除。TerminalGridのCブリッジ・スクロール描画・制御キーのテストは残す。

費用対効果：AppKit依存を減らし、ビュー構造変更への追随を省く。

## D06 — ナビゲーション配列のコピー（削除）

対象：

- [apple/ClairTests/ProjectNavigationTests.swift:219](apple/ClairTests/ProjectNavigationTests.swift:219) — `testDebugDestinationIsIncludedInNavigationStrip`

根拠：WorkspaceActivity.navigationCases の値と debug.navigationEntry を再掲。実際のナビゲーションUIを操作していない。

削除で見逃すもの：配列からdebugが抜ける変更は見逃す。表示・クリック接続の不具合は元から捕捉しないため、保証の狭さに対しデザイン変更の負担が勝る。

処置：丸ごと削除。DAP、Project外ソースの拒否、ブレークポイントの状態遷移は残す。

費用対効果：UIデザイン変更ごとの機械的修正を削減。

## D07 — Rustの定数返却・定数とdefaultの比較（削除）

対象：

- [crates/clair-ptyhost/src/main.rs:384](crates/clair-ptyhost/src/main.rs:384) — `spawn_options_have_a_safe_terminal_default`
- [crates/clair-ptyhost/src/main.rs:379](crates/clair-ptyhost/src/main.rs:379) — `smoke_response_is_versioned_and_stable`
- [crates/clair-core/src/lib.rs:32](crates/clair-core/src/lib.rs:32) — `rust_and_c_abi_smoke_values_match`

根拠：SpawnOptionsの値を同じDEFAULT定数と比較し、smokeは定数返却関数を確認する。Rust内からextern C関数を呼んでもSwiftとのリンクを試していない。

削除で見逃すもの：defaultのフィールド取り違え・smoke文字列の変更は見逃す。ただしdefault値自体の不適切さは検出しない。FFIの実害はSwiftの実呼び出しに集約できる。

処置：3テストを削除。dimensions_are_bounded と実PTYテスト、Swift側のFFI呼び出しを残す。

費用対効果：時間よりも保証のないbootstrapテスト維持を削減。

## D08 — UserDefaultsのドメイン分離をOSに対して再確認（削除）

対象：

- [apple/ClairTests/ClairRuntimeProfileTests.swift:35](apple/ClairTests/ClairRuntimeProfileTests.swift:35) — `testPreferencesDomainsDoNotShareValues`

根拠：Clairの設定サービスを通さず、UserDefaults(suiteName:) と standard に書き込む。独自ロジックはホストbundle ID一致だけ。

削除で見逃すもの：OSのUserDefaults隔離の破綻を見逃す。製品が誤ったdefaultsを使うバグは現テストでも捕捉しない。ホストのIDはbundle smokeで確認できる。

処置：丸ごと削除。Stable/Devのデータディレクトリ・ドメインが異なるという製品設定契約は残す。

費用対効果：ユーザーdefaultsへのI/Oとホスト環境依存を解消。

## D09 — FileManager.createDirectoryの薄いラッパー（削除）

対象：

- [apple/ClairTests/ClairRuntimeProfileTests.swift:58](apple/ClairTests/ClairRuntimeProfileTests.swift:58) — `testApplicationSupportDirectoryCanBeCreated`

根拠：BootstrapState.ensureApplicationSupportDirectory は createDirectory を直接呼ぶだけ。同じ確認が SwiftRustSmoke.validateApplicationSupportCreation にもある。

削除で見逃すもの：ラッパーが何もしなくなる変更は見逃す。通常のstore保存テストが親ディレクトリ作成と実ファイルI/Oを保証する一方、このテストはアプリ起動時の呼び出し漏れを検証していない。

処置：このテストと独立smoke側の同等チェックを削除。BootstrapStateのエラー報告テストは残す。

費用対効果：一時ディレクトリI/Oと重複保守を削減。

## D10 — 読み込みの巨大履歴テストが巨大履歴を読んでいない（削除）

対象：

- [apple/ClairTests/AgentActivityTests.swift:188](apple/ClairTests/AgentActivityTests.swift:188) — `testLoadingOversizedHistoryIsNormalizedToBound`

根拠：store.save(snapshot) がすでに normalized(maximumActivityCount:) を実行するので、loadするファイルには2件しかない。通常append上限テストと同じ保存上限を繰り返している。

削除で見逃すもの：削除しても巨大ファイルのload正規化に対する保証は減らない。その分岐は元から未検証。保存上限は testStoreKeepsOnlyNewestActivitiesWithinConfiguredBound に残る。

処置：現テストを削除。読み込み時の縮小を保証したい場合のみ、store.saveを通さず5件のfixtureを直接書くテストへ置換する。

費用対効果：重複するディスク往復を削減。

## M01 — fake providerの期待編集配列を適用結果へ統合（統合・置換）

対象：

- [apple/ClairTests/ProjectEditorSuggestionTests.swift:7](apple/ClairTests/ProjectEditorSuggestionTests.swift:7) — `testFakeProviderCreatesArbitraryInsertionDeletionAndReplacementEdits`
- [apple/ClairTests/ProjectEditorSuggestionTests.swift:136](apple/ClairTests/ProjectEditorSuggestionTests.swift:136) — `testProposalPreservesTrailingNewlineAndUnicodeInFullApplication`

根拠：FakeSuggestionProviderはmakeProposalを呼ぶだけで製品呼び出しがない。ただし最初のテストは実makeProposalの挿入・削除・置換を通るため、単なるモック自己検証とは言い切れない。

削除で見逃すもの：無条件削除すると提案の挿入・削除range計算の不具合を見逃す。他テストは置換中心。

処置：両テストを、挿入・削除・置換とCRLF/結合文字を含む1つのmakeProposal→approve→正確なUTF-8バイト確認へ統合。編集の並べ方・細かな配列は固定しない。

費用対効果：不要なasync/fake経路と内部diff分解への結合を削減。

## M02 — rejectに渡していない文書の不変性（部分削除）

対象：

- [apple/ClairTests/ProjectEditorSuggestionTests.swift:83](apple/ClairTests/ProjectEditorSuggestionTests.swift:83) — `testRejectDoesNotMutateAndPartialLineSelectionReturnsUIError`

根拠：applier.reject(proposal) は .rejected を返すだけで document を受け取らない。無関係なdocument.contentが変わらない確認は空振り。

削除で見逃すもの：rejectの定数返却変更だけ。部分range承認を誤って許す問題は別の実ロジックなので残す。

処置：rejectの返値・直後のcontent確認を削除し、unsupportedPartialSelectionとrevision不変だけ残す。

費用対効果：テスト名と実際の保証を揃え、無意味な期待値を削減。

## M03 — 同じrevision拒否を3経路で繰り返す（ケース削減）

対象：

- [apple/ClairTests/ProjectEditorSuggestionTests.swift:107](apple/ClairTests/ProjectEditorSuggestionTests.swift:107) — `testOldProposalIsRejectedAfterManualExternalAndUndoRevisionChanges`

根拠：approveは変更原因を参照せずrevisionを比較する。manual/externalはともに異なる本文・進んだrevisionを用意して同じ拒否へ入る。

削除で見逃すもの：externalのsnapshot交換がrevisionを進めなくなる固有不具合は、externalケースを消すだけでは見逃し得る。Undo後の同一本文でも拒否するケースには固有価値がある。

処置：manualケースを削り、externalとUndoを残す。通常applyでrevisionが進む保証はDocumentTestsに委ねる。

費用対効果：ケース数削減より、同じ前提条件を作る長いsetupの削減。

## M04 — terminal/agentのCodable往復を永続化境界1か所へ（統合）

対象：

- [apple/ClairTests/TerminalTests.swift:223](apple/ClairTests/TerminalTests.swift:223) — `testTerminalTabPersistsStableSessionID`
- [apple/ClairTests/TerminalTests.swift:233](apple/ClairTests/TerminalTests.swift:233) — `testAgentTerminalTabPersistsProfileMetadata`
- [apple/ClairTests/ManagedWorktreeTests.swift:235](apple/ClairTests/ManagedWorktreeTests.swift:235) — `testManagedTerminalRootAndWorktreeIdentityRoundTrip`
- [apple/ClairTests/AgentWorkflowTests.swift:101](apple/ClairTests/AgentWorkflowTests.swift:101) — `testAgentSessionLifecycleRoundTripsThroughCodable`

根拠：ProjectPaneTabとAgentSessionを複数ファイルでencode→decode。Managedのsurface復元にはdecodedTabではなく元のtabを渡しており、保存と復元の接続も弱い。

削除で見逃すもの：sessionID、profileID、worktreeID、実行rootの保存漏れは現実的なので全部捨てない。markRunning/markExitedの状態遷移も往復とは別の保証。

処置：管理worktreeの復元テストを残し、全metadataを保存→decode→surface復元で確認し、旧形式の固定fixture読込も同じ契約群に置く。TerminalTestsの2往復を削除。AgentWorkflowTestsは状態遷移だけに縮小し、AgentSessionの保存互換性は同じfixture群に集約。

費用対効果：同じ永続化型の重複setupとschema変更時の多点修正を削減。

## M05 — 通常保存とUnicode保存を1つの実ファイルテストへ（統合）

対象：

- [apple/ClairTests/NativeEditorTests.swift:38](apple/ClairTests/NativeEditorTests.swift:38) — `testEditorSavesOnlyAfterExplicitSaveAndUndoRestoresCleanState`
- [apple/ClairTests/NativeEditorTests.swift:61](apple/ClairTests/NativeEditorTests.swift:61) — `testEditorPreservesUnicodeEmojiAndCombiningTextAsUTF8`

根拠：どちらもreplaceContent→saveの同じ経路。Unicodeバイト比較を通常保存ケースに入れれば別の空ファイルsetupは不要。

削除で見逃すもの：無条件削除ではUnicode正規化・書き込みencoding誤りを見逃す。

処置：前者のbefore/afterをUnicode・結合文字入りにし、保存後はDataでバイト比較。後者を削除。Undo後にcleanへ戻る確認を保持。

費用対効果：1つ分のファイル・document・watcher生成を削減。

## M06 — RGB定数を丸写しする色テスト（部分削除）

対象：

- [apple/ClairTests/NativeEditorTests.swift:148](apple/ClairTests/NativeEditorTests.swift:148) — `testSyntaxHighlighterAppliesOneDarkColorsToTextStorage`

根拠：One Darkの3色をnsRGBの数値で再掲し、製品とテストの両方にデザイントークンがある。

削除で見逃すもの：正確な色味の誤りは見逃すが、テーマ変更のたびに壊れる。apply自体が無効になる不具合には価値がある。

処置：RGB一致を削除。keyword/string/commentに異なる属性が適用され、baseFontが保持される最小の描画アダプタ確認へ縮小。tokensの分類テストは残す。

費用対効果：実行時間よりテーマ変更時の修正負担を削減。

## M07 — watcherの同一パスrewriteを1ライフサイクルへ（統合）

対象：

- [apple/ClairTests/NativeEditorTests.swift:269](apple/ClairTests/NativeEditorTests.swift:269) — `testWatcherReloadsAnExternalRewriteWhenTheTabIsClean`
- [apple/ClairTests/NativeEditorTests.swift:286](apple/ClairTests/NativeEditorTests.swift:286) — `testWatcherDoesNotClobberUnsavedEditsOnExternalRewrite`
- [apple/ClairTests/NativeEditorTests.swift:188](apple/ClairTests/NativeEditorTests.swift:188) — `testExternalRewriteWinsWhenTheTabHasNoUnsavedEdits`
- [apple/ClairTests/NativeEditorTests.swift:200](apple/ClairTests/NativeEditorTests.swift:200) — `testExternalRewriteDoesNotClobberUnsavedEdits`

根拠：clean/dirtyの同期テストと非同期テストが重なる。ただし同期refreshだけではwatcher接続を保証できない。

削除で見逃すもの：dirty側の非同期ケースを丸ごと消すとwatcherが直接上書きする実装に変わった回帰を見逃す。

処置：非同期2本をclean外部更新→dirty編集→再度外部更新の1本へ統合し、両方の結果を確認。同期2本は短く故障箇所を特定できるので保持してよい。非同期側で同じ期待値を過度に繰り返さない。

費用対効果：surface/監視開始・終了を1回減らす。待機する独立事象そのものは2回残る。

## M08 — 欠落ファイル・削除再作成の開始状態を統合（統合）

対象：

- [apple/ClairTests/NativeEditorTests.swift:351](apple/ClairTests/NativeEditorTests.swift:351) — `testMissingFileOpensEmptyEditableTab`
- [apple/ClairTests/NativeEditorTests.swift:366](apple/ClairTests/NativeEditorTests.swift:366) — `testWatcherLoadsFileCreatedAfterOpeningMissingTab`
- [apple/ClairTests/NativeEditorTests.swift:234](apple/ClairTests/NativeEditorTests.swift:234) — `testExternalDeletionRetainsTheTabAndItsBufferContent`
- [apple/ClairTests/NativeEditorTests.swift:307](apple/ClairTests/NativeEditorTests.swift:307) — `testWatcherKeepsWatchingAfterExternalDeletionAndRecreation`

根拠：同じ初期missing状態／削除後buffer保持を、同期とwatcherケースで別々にfixture化している。

削除で見逃すもの：初期missingと既存ファイル削除はdirty状態が異なり、1種類に削るとデータ上書きを見逃す。

処置：初期missingの4assertをcreated-laterテストの書き込み前に移す。削除後のisMissing/isDirty/content確認をdeletion-recreationテストへ移す。その上で同期の2本を削除。

費用対効果：document/ファイルsetupを2つ削減。両シナリオ自体は維持。

## M09 — cancel前後の結果を1本の同期制御されたテストへ（統合・置換）

対象：

- [apple/ClairTests/ProjectEditorDiffModelTests.swift:91](apple/ClairTests/ProjectEditorDiffModelTests.swift:91) — `testCoordinatorCanCancelAndReturnsCurrentRevisionResult`
- [apple/ClairTests/ProjectEditorDiffModelTests.swift:122](apple/ClairTests/ProjectEditorDiffModelTests.swift:122) — `testCoordinatorDiscardsAStaleCalculationAfterCancellation`

根拠：前者は仕事のない状態でcancelするだけ。後者は1ms sleepで「計算が開始済みかつ未完了」と仮定し、速い／遅い実行環境の両方で破綻し得る。

削除で見逃すもの：後者を単に削ると古いdiffが現行表示を上書きする回帰を見逃す。

処置：開始・完了をテストから制御できる計算境界を用意し、旧計算開始→cancel→旧結果nil→新計算のrevision確認の1本へ置換。最小の注入点が必要なので即削除とは区別する。

費用対効果：巨大diffを競合待ちの代用品にする負担とsleep依存を排除。

## M10 — 10,000行と10秒閾値は性能評価へ（通常suiteから分離）

対象：

- [apple/ClairTests/ProjectEditorDiffModelTests.swift:103](apple/ClairTests/ProjectEditorDiffModelTests.swift:103) — `testTenThousandLineDiffRunsInBackgroundWithTwoThousandReplacements`

根拠：async関数を呼びDateで10秒未満を測るだけで、メインスレッドを塞いでいないことは検証しない。共有CIの負荷が結果に混ざる。

削除で見逃すもの：大規模入力での計算量退行は通常suiteから見えなくなる。小規模のsource復元テストだけでは代替できないため、性能計測として残す。

処置：通常単体suiteから外し、明示実行の性能チェックへ移動。小規模の機能テストでsource再構成を確認し、性能側では実測分布を扱う。

費用対効果：大規模diff計算と環境依存の閾値失敗を通常開発から除去。

## M11 — Swift同士の往復・文字列検索を実際のWeb契約へ（統合・置換）

対象：

- [apple/ClairTests/ProjectEditorWebBridgeTests.swift:83](apple/ClairTests/ProjectEditorWebBridgeTests.swift:83) — `testWebEnvelopeRoundTripsWithoutFullContent`
- [apple/ClairTests/ProjectEditorWebBridgeTests.swift:99](apple/ClairTests/ProjectEditorWebBridgeTests.swift:99) — `testSelectionEnvelopeContainsNoDocumentOrRevisionFields`

根拠：自動合成Codable同士の往復はキー名を双方で変更しても通る。contains検索はJSONキーではなく値にも反応する。messageBodyからの実際の入口を通っていない。

削除で見逃すもの：メッセージへの全文混入・JSとSwiftのキー不一致は現実的。丸ごと削って無保証にはしない。

処置：独立したJS形式の固定JSON fixtureをmessageBody initializerへ渡す契約テストに集約。全文を送らない保証はWeb側の送信objectに置く。selection/editという異なるschemaは両方保持。

費用対効果：合成Codableの自己整合確認と内部文字列表現への依存を削減。

## M12 — Project隔離・再起動復元を2 Projectの1経路へ（統合）

対象：

- [apple/ClairTests/ProjectKernelTests.swift:444](apple/ClairTests/ProjectKernelTests.swift:444) — `testProjectSwitchKeepsFileTreeSelectionAndTabsIsolated`
- [apple/ClairTests/ProjectKernelTests.swift:531](apple/ClairTests/ProjectKernelTests.swift:531) — `testThreeProjectPaneLayoutsRemainIsolatedAcrossRestart`
- [apple/ClairTests/ProjectKernelTests.swift:579](apple/ClairTests/ProjectKernelTests.swift:579) — `testWorkspaceActivitySelectionPersistsPerProjectAcrossRestart`

根拠：Projectを作って切替・復元するsetupが3本。3番目のProjectは同じID辞書の隔離確認を繰り返している。

削除で見逃すもの：削除だけでは、実行中の選択保持、復元時のlayout混線、activity未保存をそれぞれ見逃す。

処置：2 Projectに異なるlayout・選択・activityを与え、再起動前後で確認する1本へ統合。surfaceの参照同一性（===）は外し、ユーザーから見える状態を比較。

費用対効果：ディスク保存、surface生成、監視setupを大きく削減できる候補。

## M13 — registry全件照合とpreflightの重複（統合）

対象：

- [apple/ClairTests/ProjectKernelTests.swift:150](apple/ClairTests/ProjectKernelTests.swift:150) — `testCommandRegistryExposesTypedRiskAndAvailabilityPreflight`
- [apple/ClairTests/CommandAdapterTests.swift:28](apple/ClairTests/CommandAdapterTests.swift:28) — `testRegistryCoversAllTypedCommandsAndCodecPreservesID`
- [apple/ClairTests/ProjectKernelTests.swift:210](apple/ClairTests/ProjectKernelTests.swift:210) — `testHumanCommandSurfacePreservesUnavailableReasonAndDisplaysError`

根拠：Set(registry.descriptors.map(id)) == Set(allCases)が2か所。missing Projectのpreflightもsurfaceの不可用テストと重複。

削除で見逃すもの：registryへの登録漏れは現実的なので全件照合は1か所残す。リスクとAI公開可否は別の実制御であり、単なるenum確認として捨てない。

処置：全件照合はCommandAdapterTestsだけ。missing Projectのavailability/risk確認はsurface失敗テストへ統合し、ProjectKernel側の独立preflightテストを削除。openProject正常系は実dispatchで確認。

費用対効果：同じregistry契約の二重修正を削減。

## M14 — sourceラベルだけを変えて3回dispatch（ケース削減）

対象：

- [apple/ClairTests/ProjectKernelTests.swift:174](apple/ClairTests/ProjectKernelTests.swift:174) — `testHumanCommandSurfacesDispatchTheSameCommandID`

根拠：同じsurface.invokeに .commandWindow/.menu/.shortcut を渡すだけ。sourceは記録に使われ、実際のmenu/shortcutのハンドラーを操作しない。

削除で見逃すもの：実UI側の配線ミスは現状でも捕捉しない。sourceごとの記録フィールド転記しか増えていない。

処置：1回のinvokeでProjectが切り替わりexecutionが記録されるテストへ縮小。3種類のUI共通配線が検証済みと読める名前も変更。

費用対効果：繰り返しdispatchに伴う保存と認知負担を削減。

## M15 — plainとtemporaryが同じ入力分類（ケース削減）

対象：

- [apple/ClairTests/ProjectKernelTests.swift:8](apple/ClairTests/ProjectKernelTests.swift:8) — `testOpensGitNonGitAndTemporaryFoldersInOneWorkspace`

根拠：3つとも同じ一時ディレクトリ配下。Gitも.gitディレクトリを置くだけ。plainRootとtemporaryRootには名前以外の差がない。

削除で見逃すもの：temporaryを消しても固有の製品条件は失わない。Git有無を問わず開ける保証は残せる。

処置：Git印あり・なしの2つに縮小。件数・active IDの期待値を合わせる。

費用対効果：余分なProject生成・保存・監視開始を削減。

## M16 — Git statusとstage/unstage/commitの重複起動（統合）

対象：

- [apple/ClairTests/ProjectGitTests.swift:8](apple/ClairTests/ProjectGitTests.swift:8) — `testStatusSeparatesStagedUnstagedAndUntrackedChanges`
- [apple/ClairTests/ProjectGitTests.swift:33](apple/ClairTests/ProjectGitTests.swift:33) — `testDiffStageUnstageAndCommitPreserveStagedBoundary`

根拠：同じbaseline repositoryでstatus→stageを繰り返す。ただし前者のstaged後に再編集して両側に同じpathが存在するケースは固有。

削除で見逃すもの：片方だけ削るとpartial staging・untracked分類またはunstage/commit経路を失う。

処置：1 repoでuntrackedを置き、stage後の再編集→両diffの内容確認→unstage→stage→commitを確認する1本へ。段階ごとに必要なassertを残し、中間statusの重複照合を削る。

費用対効果：Git init/config/commitと多数のProcess起動を1 fixture分削減。

## M17 — 実行しないだけのcleanup取消テスト（統合）

対象：

- [apple/ClairTests/ProjectGitTests.swift:387](apple/ClairTests/ProjectGitTests.swift:387) — `testCleanupCancellationLeavesManagedWorktreeInPlace`
- [apple/ClairTests/ManagedWorktreeTests.swift:84](apple/ClairTests/ManagedWorktreeTests.swift:84) — `testCleanupRequiresCleanTargetNoActiveSessionAndExplicitConfirmation`

根拠：prepareCleanup後にconfirmCleanupを呼ばず存在を確認する。UIの取消処理は操作していない。同じprepareはManagedWorktreeTestsで何度も通る。

削除で見逃すもの：prepareCleanupが誤って削除する回帰は検出価値があるが、それは既存cleanupテストに1 assertで持てる。

処置：cleanPlanの作成直後・confirm前にworktree存在を確認し、ProjectGit側の独立テストを削除。

費用対効果：Git repo・worktree生成一式を削減。

## M18 — 履歴queryの前に行う不要なJSON往復（統合）

対象：

- [apple/ClairTests/AgentActivityTests.swift:38](apple/ClairTests/AgentActivityTests.swift:38) — `testHistoryIsCodableAndCanBeQueriedByProjectAndSessionScope`
- [apple/ClairTests/AgentActivityTests.swift:91](apple/ClairTests/AgentActivityTests.swift:91) — `testStorePersistsVersionedSnapshotAtomicallyAndPreservesMuteState`

根拠：queryテストがJSON往復を済ませたrestoredに対してフィルタを確認。永続化はstoreテストが別にある。

削除で見逃すもの：Project/sessionの取り違えを検出するfixtureは独立価値があり削らない。

処置：queryはhistoryに直接実行。保存互換性はstoreテストの固定fixtureに集約。store側のfileExistsと現行version定数の自己比較も重複なら除去。なお現状の正常write/readだけでatomic性までは保証していない。

費用対効果：機能の異なるassertを分離し、JSON往復を削減。

## M19 — シェルの正確な引用文字列を実行結果へ（統合）

対象：

- [apple/ClairTests/AgentWorkflowTests.swift:30](apple/ClairTests/AgentWorkflowTests.swift:30) — `testProfilePassesSelectedModelAsQuotedLaunchArguments`
- [apple/ClairTests/AgentWorkflowTests.swift:44](apple/ClairTests/AgentWorkflowTests.swift:44) — `testProfileBuildsProjectRootShellCommandWithQuotedValues`
- [apple/ClairTests/AgentWorkflowTests.swift:58](apple/ClairTests/AgentWorkflowTests.swift:58) — `testShellCommandDoesNotExecuteCwdInjection`
- [apple/ClairTests/AgentWorkflowTests.swift:88](apple/ClairTests/AgentWorkflowTests.swift:88) — `testShellCommandQuotesArgumentsIndependently`

根拠：3本がシェル生成文字列の完全一致。等価な引用方法への変更でも壊れる。実shellテストはcwdのsemicolonだけを検証。

削除で見逃すもの：cwd、任意arguments、model引数は別の入力境界。どれかを無条件に消すと空白・引用符・コマンド置換の破綻を見逃す。

処置：一時ディレクトリ内のfixture実行体でcwdとargvを記録し、空白・単引用符・semicolon・コマンド置換文字がそのまま届き副作用がない1本へ。プロフィールのmodel→--model変換は小さな1本で保持。完全一致3本を2つの役割へ整理。

費用対効果：文字列実装への強い結合を解消。shell起動数は増やさず既存実行テストを拡張。

## M20 — 高さの実装式をテストでも再計算（部分削除）

対象：

- [apple/ClairTests/TerminalTests.swift:45](apple/ClairTests/TerminalTests.swift:45) — `testTerminalGridKeepsScrollbackAndTerminalTextViewGrowsDocumentHeight`

根拠：inset*2 + displayedRows*cellSizeという実装の式を期待値として再掲。

削除で見逃すもの：正確な余白のずれを見逃すが、スクロール領域が画面行数分に切られる問題は既存のGreaterThanで捕捉できる。

処置：expectedHeight計算と完全一致だけ削除。scrollbackがあり、表示行数が増え、viewがviewport相当より高い確認を残す。

費用対効果：フォント・余白・レイアウト実装の変更負担を削減。

## M21 — モバイル入力の順序・重複排除を3回確認（統合・部分削除）

対象：

- [packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:609](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:609) — `mobileHostAppliesInputInArrivalOrderAndDoesNotResizeFromViewport`
- [packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:104](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:104) — `inputSequencerUsesArrivalOrderAndMakesDuplicatesIdempotent`
- [packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:910](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:910) — `mobileHostDeliversFreshAcceptedOperationsToTheApplicationBridge`

根拠：pure sequencer、host返値、host handler配送で重複を確認。host順序テスト末尾のreadOnlySequencerはhostを迂回し、既存権限拒否テストとも重複する。viewport/resizeはそもそも操作していない。

削除で見逃すもの：純粋な順序計算と、重複入力がアプリへ二重配送されない保証は両方必要。interruptの0x03変換も独自経路。

処置：pure sequencerを保持。handler配送テストに異なる2入力の順序とinterrupt payloadを追加し、host順序テストを削除。末尾readOnlySequencerは移さず削除。

費用対効果：pairing/key生成/session登録の重複fixtureを1つ削減。

## M22 — DTOのCodable往復とfactory転記（統合・置換）

対象：

- [packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:186](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:186) — `agentControlContractExposesFactualStateAndCapabilities`
- [packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:874](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:874) — `mobileRequestFactoryProjectsSharedControlMethods`
- [packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:895](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:895) — `mobileRequestFactoryEncodesAgentInput`

根拠：agent descriptorの入力state/model/capabilitiesの読み戻し、method定数、factoryのJSON往復が中心。実際のmethod routingや権限処理まで届かない。

削除で見逃すもの：wire上のmethod名・schema変更でクライアントが壊れるリスクはあるが、同じ型同士の往復では互換性を十分保証しない。

処置：agent descriptorは独立JSON fixtureでdecodeし、factoryは既存RPC/handlerテストに通す。initializeはloopbackがすでに通る。agentInputとterminalInputのRPC配送を移植した後、独立factory2本を削除。

費用対効果：薄い転記テストを実利用の契約に集約。

## M23 — 存在しない秘密値を検索する否定assert（部分削除）

対象：

- [packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:824](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:824) — `mobilePairingLinkDeepLinkRoundTripsIdentityAndTransport`
- [packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:852](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:852) — `mobileAttentionPayloadContainsOnlyOpaqueWakeMetadata`

根拠：pairing linkにdevice_token/private_keyを入力していない。notificationにもprompt/cwd/terminal/secretを入力していない。JSON文字列にその単語がないことは漏洩経路を検証しない。

削除で見逃すもの：将来の秘密キー追加の一部を偶然検出することはあるが、別名の漏洩は検出不能。deep linkの独自URL変換とAPNSキーへのmappingは維持すべき。

処置：否定containsを削除。通知はAPNS payloadの許可キー集合を確認する最小契約へ。実secretを与えて保存ファイルに残らないhost pairingテストはそのまま維持。

費用対効果：誤った安心感と語句依存を削減。

## M24 — viewportのsetter/getterをlocal性の保証としない（部分削除）

対象：

- [packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:731](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:731) — `mobileClientKeepsViewportLocalAndRecoversFromStreamGaps`

根拠：setLocalViewport後に同じ値を読み戻すだけで、送信処理やremote resizeがないことは検証しない。残りのcursor/gap/scrollbackは実アルゴリズム。

削除で見逃すもの：viewport値の保持不良は見逃す。ただし端末を誤resizeする不具合は現テストでも見つからない。

処置：viewport setupとそのassertだけ削除し、stream gap/replay/byte capを残す。local性の検証をするなら送信境界で行う。

費用対効果：無関係な責務と過大なテスト名を削減。

## M25 — 認証正常系setupの二重化（統合）

対象：

- [packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:682](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:682) — `mobileRPCConnectionRequiresAuthenticationBeforeProjectAccess`
- [packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:998](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:998) — `mobileListenerAndClientCompleteLoopbackAuthentication`

根拠：RPC認証前拒否テストは拒否確認後にpair/auth正常系を最後まで行う。同じ正常系は実listener/clientのloopbackで通る。

削除で見逃すもの：認証前にProject情報が漏れる回帰はloopback正常系だけでは検出できない。

処置：RPCテストはinitialize後の未認証拒否までで終了。正常pair/authはloopbackへ集約。Networkが利用できない環境でも認証正常系を走らせる要件がある場合のみpure RPC版を残す。

費用対効果：重複key生成・pairing/auth setupを削減。移植前提ではなく環境要件付きの候補。

## M26 — PTY正常系4本を2起動に統合（統合）

対象：

- [crates/clair-ptyhost/tests/live_shell.rs:119](crates/clair-ptyhost/tests/live_shell.rs:119) — `shell_command_round_trips_raw_output_and_resize`
- [crates/clair-ptyhost/tests/live_shell.rs:139](crates/clair-ptyhost/tests/live_shell.rs:139) — `shell_receives_clair_terminal_environment`
- [crates/clair-ptyhost/tests/live_shell.rs:162](crates/clair-ptyhost/tests/live_shell.rs:162) — `shell_does_not_inherit_stale_host_environment`
- [crates/clair-ptyhost/tests/live_shell.rs:221](crates/clair-ptyhost/tests/live_shell.rs:221) — `shell_preserves_cjk_and_osc_bytes`

根拠：4本とも新しい/bin/shとptyhostを起動。出力/resize/CJK/OSCは1セッションで確認でき、正常environmentと汚染environmentも同じ起動で検証できる。

削除で見逃すもの：環境の再構築、raw bytes維持、resize適用は独立の製品契約なのでassertを削ってはいけない。

処置：出力/resize/CJK/OSCを1本、環境の初期値と親環境汚染の除去を1本へ。固定markerが入力echoに現れないよう分割して出力し、期限付き収集を共通化。

費用対効果：2回のPTY/プロセス起動を削減。現ShellHarnessにtimeout/Dropがないため、障害時の長時間停止・子プロセス残留対策も有効。

## M27 — 100行のflood smoke（削除・統合）

対象：

- [crates/clair-ptyhost/tests/live_shell.rs:241](crates/clair-ptyhost/tests/live_shell.rs:241) — `terminal_flood_completes_without_host_crash`

根拠：100行出して末尾marker2つを探すだけ。全行配送・queue上限・メモリ・実行時間を確認しない。

削除で見逃すもの：短い連続出力でhostが落ちる回帰は見逃し得るが、これを負荷保証として残す価値は低い。

処置：独立テストを削除し、M26の正常出力fixtureを複数フレーム相当の既知バイト列にする。性能は既存terminal-flood benchmark経路へ。

費用対効果：1回のPTY/プロセス起動を削減。実際の負荷耐性が維持されたとは主張しない。

## M28 — lease許可と競合拒否で同じworktreeを作り直す（統合）

対象：

- [.agents/skills/clair-issue-executor/scripts/test_item_lease.py:136](.agents/skills/clair-issue-executor/scripts/test_item_lease.py:136) — `test_independent_items_can_be_leased_in_parallel`
- [.agents/skills/clair-issue-executor/scripts/test_item_lease.py:84](.agents/skills/clair-issue-executor/scripts/test_item_lease.py:84) — `test_one_worktree_and_one_item_are_exclusive`

根拠：exclusiveテストがすでにmainのP01とlinked worktreeのP02を同時保持する。parallelテストもsubprocessを逐次実行し、同時競合を起こしていない。

削除で見逃すもの：2つのlinked worktree同士の許可とother_leases報告は前者に固有なので、そのassertを移す必要がある。

処置：exclusiveテストの解放後にworker-one=P01、worker-two=P02を取得し、other_leasesを確認。parallel側を削除。競合時の排他、同一worktreeの複数item禁止は維持。

費用対効果：Git init/commit、2つのworktree生成とPythonプロセス起動の重複を削減。

## M29 — 少量の重複assert・内部IDへの不要な結合（部分削除）

対象：

- [apple/ClairTests/ProjectEditorDiffModelTests.swift:91](apple/ClairTests/ProjectEditorDiffModelTests.swift:91) — `testCoordinatorCanCancelAndReturnsCurrentRevisionResult`
- [apple/ClairTests/ProjectEditorDiffModelTests.swift:48](apple/ClairTests/ProjectEditorDiffModelTests.swift:48) — `testStableIDsUseTheDocumentPairAndBothRevisions`
- [apple/ClairTests/ProjectEditorSuggestionTests.swift:31](apple/ClairTests/ProjectEditorSuggestionTests.swift:31) — `testLineApprovalAppliesAtomicallyAndOneUndoRestoresExactUnicodeBytes`
- [apple/ClairTests/ProjectKernelTests.swift:242](apple/ClairTests/ProjectKernelTests.swift:242) — `testConfigurableShortcutRejectsInvalidAndConflictingMappings`

根拠：diff stable-IDテストのhunkID非nilは別テストと重なる。line approvalのremaining edit ID変化は、残proposalが正しく適用できることより弱い。shortcutのreserved2件は同じ集合判定。

削除で見逃すもの：IDの安定性／revisionによる無効化は現実の選択先混線を防ぐので丸ごと削らない。reservedの2件目削除はその定数の登録漏れを見逃すが、集合の各値を再掲する価値は低い。

処置：hunkID非nilの重複、remaining edit IDの直接比較、reservedの2回目を削除。安定IDの同一入力一致・revision変更時不一致、partial後の再承認とUndo、1つのreserved/invalid/conflict/clearは残す。cancelテストはM09へ。

費用対効果：実行短縮は僅少。内部ID生成・ショートカット定義変更時の修正を減らす。

## S01 — 手書きの別経路app-linkビルドを削除

対象：[scripts/smoke-app-link.sh](scripts/smoke-app-link.sh:1)、[Makefileのsmoke-app-link](Makefile:68)。

Stable/Devをswiftcでソース列挙して2回リンクするが、実際のXcode targetとは別のビルドグラフ。make ciでは実アプリ両channelのビルドとbundleのRust symbol確認も行う。手書きリストは現行のMobileControl／WebBridge／Debug等のソースグラフに追随しておらず、独立の保守対象になっている。

削除で失うのは「手書きswiftc invocationでリンクできる」という製品で使わない構成の保証。実アプリのリンク欠落はXcode buildが捕捉する。唯一の追加確認である最低macOS 14.0のvtool検査は、必要なら実bundleのバイナリに移す。その上でスクリプトと通常smokeからの呼び出しを削除。実ビルド2回と並行する追加リンク2回を除けるため、優先度が高い。現スクリプトの失敗自体は実行して再現していない。

## S02 — 独立Swift/Rust smokeをdesktop XCTestに集約

対象：[scripts/smoke-swift-rust.sh](scripts/smoke-swift-rust.sh:1)、[apple/Smoke/SwiftRustSmoke.swift](apple/Smoke/SwiftRustSmoke.swift:1)、[ClairRuntimeProfileTests.testRustCoreSmokeCall](apple/ClairTests/ClairRuntimeProfileTests.swift:82)。

現在はSwift実行体をStable/Dev用に別々にコンパイルし、profileの定数、ディレクトリ作成、同じFFI返値を検証する。FFI実呼び出しはdesktop XCTestでも行われ、実Stable/Dev bundleのsymbolもsmoke-bundlesが見る。

独立smokeの2つのprofile検査関数と実行体生成を削り、FFIの実呼び出しはtestRustCoreSmokeCallに1つの固定値assertとして残す。D07のRust内部smokeテストも同時に削れる。失うのは別途作ったStable条件のCLI実行体での呼び出し確認。現在のRustCore/ABIにchannel別実装はなく、そのためだけに別build経路を維持する価値は低い。実Stable bundleの実行まで検証していたわけではない。

## S03 — workspace検査の重複と文字列判定を縮小

対象：[scripts/check-workspace.sh](scripts/check-workspace.sh:6)、[scripts/validate-xcode-project.rb](scripts/validate-xcode-project.rb:15)。

project.pbxprojのplutil -lintは直後のRuby内plutil -convert jsonと重複するため削除候補。xcconfig内PRODUCT_BUNDLE_IDENTIFIERのgrep2本は実bundleの完全一致検査へ集約できる。特にStableのgrepはDev IDも部分一致し得る。失うのはテキストの置き場所・書式の確認で、最終的なbundle ID不良はsmoke-bundlesで捕捉する。

ただしworkspace-check単独の高速feedbackは弱まる。実行時間の利益は小さく低優先。ビルドグラフの参照整合、全scheme参照、Swiftコンパイル条件の確認、artifact-checkは別の保証として残す。署名付きリリースのversion/public key/package確認も通常Debug buildと同一視して削除しない。

## P01 — PoCのexpectedFailureを通常判定から診断へ移す

対象：[Checks.swift](prototypes/native-editor-poc/Sources/NativeEditorPoC/Checks.swift:107) の `upstream multicursor single undo`、`composition updates do not enter undo history`。

expectedFailure=trueは失敗しても終了コードに影響しない。unexpected passも検出しないため、元から回帰ゲートではない。上流ライブラリの制約記録としてのみ診断モードに移す。初回multicursorのinsert/redo確認も、adapter有効のinsert→undo→redoにまとめられる。

削除で失うのは未補正upstreamの診断結果。adapter適用後のUndo/Redoの実動作は残す。PoCはmake test/ciから呼ばれないので、これはPoC実行時の短縮でありCI短縮には数えない。

## P02 — PoCのsynthetic IME正常系を後半のUndo/Redoケースに統合

対象：[Checks.swift:142](prototypes/native-editor-poc/Sources/NativeEditorPoC/Checks.swift:142) の `synthetic marked text` / `synthetic composition commit`、[同:181](prototypes/native-editor-poc/Sources/NativeEditorPoC/Checks.swift:181) のcomposition一連。

前半はmarked text→commitの短い正常系で、後半は同じ操作に更新・Undo・Redoを加えている。ただし前半は明示markedRange、後半はNSNotFoundのreplacementRangeという差がある。単純削除ではこのrange分岐を失う。

後半のシーケンスで2種のreplacementRangeを小さなパラメータとして確認するか、明示rangeの契約が別に保証されるなら前半を削る。巨大な文書resetを伴う独立シーケンスを減らす。IMEのfamily emoji／結合文字のrange検査は異なる境界なので残す。

## P03 — PoCのハイライト色数・asset存在チェックを実際のtoken確認へ統合

対象：[Checks.swift:225](prototypes/native-editor-poc/Sources/NativeEditorPoC/Checks.swift:225) の `Swift multiple highlight colors`、`query asset <name>`、`highlight colors <name>`。

後半の言語ごとのtoken probeが具体的なcomment/string/number等の色を検証するので、前半の色数>2と各言語の色数>2は同じ描画結果の粗い再確認。色数は誤った色でも増え、asset存在だけでは実際に読み込まれたか分からない。

前半の0.8秒待機と色数走査を削除。各言語の実token probeを残し、asset存在は診断出力に下げる。失うのは対象probe外の第三色がなくなる問題などで、限定的。言語ごとのgrammar/queryは別資産なので、言語を丸ごと1つに削る提案ではない。定数色のコピーはsemantic tokenとの対応検査に変えられるが、テーマの完全一致自体を目的にしない。

## P04 — PoCの代替TextKit2診断を通常self-testから削除

対象：[Checks.swift:335](prototypes/native-editor-poc/Sources/NativeEditorPoC/Checks.swift:335)、[TextKitProbe.swift](prototypes/native-editor-poc/Sources/NativeEditorPoC/TextKitProbe.swift:7)。

製品で使わない別エディタを作り、基本挿入・undo・Tree-sitterの色付けを検査してresultsへ入れるだけ。これらの辞書にはpassキーがなく、全体の失敗判定にも参加しない。

通常runChecksから外し、比較調査の明示オプションへ移す。製品または採用PoC adapterの不具合検出は減らない。失うのは代替技術の診断記録だけ。ライブラリを再評価するときに実行すればよい。

## P05 — PoCの巨大fixtureを責務ごとに縮小・分離

対象：[Checks.swift:204](prototypes/native-editor-poc/Sources/NativeEditorPoC/Checks.swift:204) のdiff表示、[同:315](prototypes/native-editor-poc/Sources/NativeEditorPoC/Checks.swift:315) のpolicy境界と5,000,000 emoji。

`diff view virtualizes visible cells...` はgeneratedCellCount>0と選択IDを確認するだけで、全行生成しても通る。`mode and width changes retain rows`にも10,000行は不要。機能確認は小さなfixtureにし、仮想化は必要なら可視範囲に対するセル生成の上限を性能チェックで検証する。失うのは大きなtableを作ってスクロールした際のクラッシュ検出で、明示benchmarkに残す。

UTF-8とUTF-16の独立集計確認に5,000,000 emojiは不要。短い絵文字fixtureで集計差を確認し、実上限を超えた入力でnative controllerが生成されない確認は1ケースだけ残す。byte上限とline上限は異なるクラッシュ回避条件なので捨てない。大きな割り当ての繰り返しを通常機能確認から分離する。

## A01 — その他のassert単位の削除候補

- [ProjectNavigationTests:249](apple/ClairTests/ProjectNavigationTests.swift:249)：DAP decoderの`buffer.isEmpty`を削除。返された2 payloadの一致を残す。内部bufferを保持する等価な実装を許す。削除で失う未消費残留の保証が必要なら、次のappendの出力を確認すべき。
- [ProjectEditorDocumentTests:120](apple/ClairTests/ProjectEditorDocumentTests.swift:120)：selectionテストのinitialSnapshot.revisionとsnapshotCaptureCountを削除。revision不変、selection値、同じselectionで通知が増えない保証は残す。カウンターは本当の割り当てコストを測っていない。
- [ProjectKernelTests:79](apple/ClairTests/ProjectKernelTests.swift:79)：permissionケースの期待errorの丸写しに依存しすぎず、注入した失敗後のProject集合とactive IDが保持されるassertを中心にする。モック自身が投げる型の確認は減らせるが、モックを使うだけでこのテスト全体は削らない。
- [ProjectGitTests:95](apple/ClairTests/ProjectGitTests.swift:95)：branch-switchエラーテスト内の削除status確認はrename/deleteテストと重複。dirtyをrestoreするsetupは残し、余分なremove→status→deleted確認を削れる。Git外部コマンドの起動も減る。
- [ProjectEditorDiffModelTests:27](apple/ClairTests/ProjectEditorDiffModelTests.swift:27)：`replacedが存在` と `replaced件数>=2` の前者は後者に包含されるので削除。source再構成の確認は独自diffアルゴリズムを検証しており残す。
- [session_broker.rs:350](crates/clair-ptyhost/tests/session_broker.rs:350)：`read_output_until(marker)`成功後に同じmarkerが含まれるassertをfirst/second双方で削除。helper自身がmarkerを見つけるまで成功を返さない。旧出力が再送されない否定assertは別保証として残す。
- [AgentActivityTests:184](apple/ClairTests/AgentActivityTests.swift:184)：activitiesが`[second, third]`と等しい直後のcount==2を削除。
- [TerminalTests:78](apple/ClairTests/TerminalTests.swift:78)：frames==[input,resize]の直後の同じpayload一致は削れる。ただしdimensionsのdecode確認は別変換なので残す。
- [MobileControlProtocolTests:204](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:204)：decoded==agentの直後の同じstate/model/capabilities確認は包含される。M22の独立fixtureに置き換えれば一括解消できる。
- [ProjectEditorCommentAnchorTests:99](apple/ClairTests/ProjectEditorCommentAnchorTests.swift:99) と [同:125](apple/ClairTests/ProjectEditorCommentAnchorTests.swift:125)：明示的にapply/undoを呼んだ直後のoperation enum転記確認は削減候補。実際のrange移動、orphan化、Undo/Redo復元は残す。

これらの時間効果は通常小さい。主な利益は実装変更への結合と読解負担の削減で、件数削減のためだけに優先しない。

## 削らない境界と、その理由

- 文書のUTF-16範囲、surrogate分断、overlap、古いrevisionの拒否：入力不備で本文が壊れる。数値のケースに見えても異なる破損条件。
- 外部変更後のsave拒否：watcherがまだ通知していなくてもディスクを上書きしない最終防御。watcherテストで代替不可。
- コメントanchorの境界affinity・多重編集・orphanとUndo/Redo：独自の座標変換。一般的なStringや型の保証ではない。
- libvtermのcursor/ANSI/wide glyph/alternate screen：CのTerminalVTermからSwiftへのセル情報変換も通る。libvterm単体の再テストとみなして丸ごと削るべきではない。
- Git mergeの2 parent、source保持、conflict、stale plan、cleanupのdirty/active/detached/管理root外拒否：Clairが正しい対象・フラグ・順序でGitを呼ぶ保証。Git自身が保証するから不要、とはならない。
- Mobileのrevocation、scope、operation ID reuse、subscriber queue gap、journal gap、projection更新、接続単位cleanup：別の認可・状態管理境界。Swift/Rustで似た形でも別実装であり相互代替できない。
- protocolのサイズ上限・欠損header・不正寸法：decoderの境界で不要な割り当て・受理を防ぐ。`read_exact`がEOFを返すだけに見えても、独自decoderがそれを握りつぶさないことを保証する。
- CommandAdapterの承認spy、AgentActivityのnotifier、Mobileのoperation recorder：製品の許可／拒否／重複排除後に副作用が何回起こるかを見る。モックの自己検証ではない。
- Rust CLIのUnix socketテスト：fake serverを使うが、製品send_jsonの改行終端、write shutdown、response読み込みというプロトコル実装を通す。
- 署名検証テスト：CryptoKit自体ではなくClairが構成したpayloadの検証を通す。ただし署名元も同じsignedPayloadを使うためcanonical payloadの互換性までは保証しない。現在のtamperテストはhashだけを変更し、名前にあるURL改ざんは検査していない。

## テスト名だけから推定すると誤る保証

以下は「追加テストをすべて作る」という提案ではない。削除判断で、既存テストを代替保証として過大評価しないための記録。

- `testPrefetchedDirectoryCacheRebuildsExpandedTreeWithoutWalkingDisk`：cache生成後もdiskをそのまま残すため、「再走査していない」は証明していない。ただしcacheからツリーを構成する独自経路はあるので全削除は推奨しない。
- `testWatcherGraphIsLimitedToLoadedDirectories`：上限・未ロードの子ファイル除外は確認する。FD資源の上限に価値があり、内部実装依存だけを理由に削らない。
- `testMarkedTextCommitUpdatesTheDocumentOnce`：最終本文は確認するがrevision/イベント回数は測っていない。現在「1回」を保証していると扱わない。
- `testDuplicateTextCannotReconnectAnAnchorAndRevisionMismatchIsRejected`：duplicate本文を与えておらず、restore失敗はdocument IDの相違。revision mismatchを実際に起こしてはいない。ID拒否と座標復元自体は有用。
- `testWorkspaceGitCommandsAndExternalIndexRefreshStayProjectScoped`：Projectは1個なのでProject間隔離は確認しない。外部index監視とcommand dispatchには価値がある。
- `testDetachedHeadIsNotLaunchableOrCleanable`：inspectとcleanupは実行するが、agent launchは実行していない。
- `inputSequencerRejectsRevokedOrMismatchedOperations`：revokedとread-onlyを確認し、identity mismatchは作っていない。
- `agentControlAuthorizerRequiresMatchingScopeAndIdentity`：正常identityと不足scopeだけ。別identityの拒否は保証していない。
- `agentInputAuthorizerRequiresSteerScopeAndPayload`：正常scopeと空payloadだけ。不足scopeの拒否は保証していない。
- `mobileHostAuthenticatesWithFreshChallengeAndRevokesConnections`：正常署名とrevokeを確認するがchallenge再利用の拒否は未確認。
- `malformed_frame_is_rejected_and_shell_is_reaped`：hostのerror/exitと終了待ちは確認する。shell PIDの消滅を直接確認するものではない。

## 実施順

1. D01/D02/D03/D10の未使用・空振り検証を削除し、定数・setter等のD候補を処理する。
2. S01/S02の二重ビルド経路、M26/M27のPTY起動、M16/M17/M28のGit fixture、M12のProject生成重複を減らす。
3. M09の固定sleepを置換し、M10/P05の性能確認を明示実行へ分離する。
4. M01/M04/M11/M22の契約移植を行ってから旧テストを削除する。
5. 残りのassert単位の縮小。単に関数を減らすだけの統合を優先しない。

候補は相互に重なる。例えばD07のFFI削除はS02の残存確認とセット、M29のcancelテストはM09と同一。行数や候補数を単純に足して削減テスト数・短縮時間を算出しない。
