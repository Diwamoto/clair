# 全テスト関数の判定対応

この一覧は削除・統合前の監査対象。変更後の対応・検証は [execution.md](execution.md) を参照。関数名・行番号は監査時点のもの。

[監査本文](README.md)に削除・統合方法、見逃す不具合、負担を記載した。ここでは全228関数を列挙する。維持は件数確保ではなく、記載した独立の故障経路が残るため。移植・統合先として列挙されたテストもあり、候補表に載ることと丸ごと削除は同義ではない。S/P/Aは関数外またはassert単位の候補。

## apple/ClairTests/AgentActivityTests.swift

| 関数 | 判定・理由 |
|---|---|
| [testSourcesAndKindsKeepBellExitAndOfficialHookDistinct](apple/ClairTests/AgentActivityTests.swift:7) | 維持：exit statusから成功・失敗を分ける独自分類とbell/hookの区別。通知の意味が変わる回帰を検出。 |
| [testHistoryIsCodableAndCanBeQueriedByProjectAndSessionScope](apple/ClairTests/AgentActivityTests.swift:38) | M18：統合（履歴queryの前に行う不要なJSON往復） |
| [testStorePersistsVersionedSnapshotAtomicallyAndPreservesMuteState](apple/ClairTests/AgentActivityTests.swift:91) | M18：統合（履歴queryの前に行う不要なJSON往復） |
| [testStoreRejectsUnsupportedVersionAndMalformedJSON](apple/ClairTests/AgentActivityTests.swift:122) | 維持：未知schemaと破損JSONを製品errorへ変換する別分岐。既存履歴を誤解釈しない。 |
| [testProjectMuteCoversSessionsButSessionUnmuteDoesNotBypassProjectMute](apple/ClairTests/AgentActivityTests.swift:138) | 維持：Project muteの優先順位とsession単位の隔離。通知抑止を誤って解除する回帰。 |
| [testStoreKeepsOnlyNewestActivitiesWithinConfiguredBound](apple/ClairTests/AgentActivityTests.swift:160) | 維持：append後に古い履歴が落ち、最新が残る独自上限制御。count重複はA01。 |
| [testLoadingOversizedHistoryIsNormalizedToBound](apple/ClairTests/AgentActivityTests.swift:188) | D10：削除（読み込みの巨大履歴テストが巨大履歴を読んでいない） |
| [testOfficialHookDecoderAcceptsKnownEventsWithoutRetainingRawBody](apple/ClairTests/AgentActivityTests.swift:212) | 維持：外部hookのscope/time/kind変換と、実際に入力した秘密フィールドの破棄。 |
| [testOfficialHookDecoderDropsUnknownEventsAndRedactsSecretLookingBody](apple/ClairTests/AgentActivityTests.swift:241) | 維持：未知eventの拒否と既知event内の秘密文字列除去は別分岐。 |
| [testOfficialHookDecoderNormalizesControlCharactersBeforePersistingSummary](apple/ClairTests/AgentActivityTests.swift:259) | 維持：外部入力の制御文字を保存前に除去する独自処理。 |
| [testOfficialHookDecoderBoundsSummaryAndRejectsOversizedPayload](apple/ClairTests/AgentActivityTests.swift:270) | 維持：本文truncateと入力上限拒否は別のメモリ・表示境界。 |
| [testNotificationDispatcherHonorsMuteAndUsesProtocolSink](apple/ClairTests/AgentActivityTests.swift:287) | 維持：本物のdispatcherがmute時にsinkを呼ばない。モックの自己検証ではない。 |

## apple/ClairTests/AgentRateLimitTests.swift

| 関数 | 判定・理由 |
|---|---|
| [testParsesCodexPrimaryAndSecondaryWindows](apple/ClairTests/AgentRateLimitTests.swift:7) | 維持：Codexの2window schema、remaining変換とfetch時刻。別vendorのparserでは代替できない。 |
| [testPrefersMultiBucketResponseAndClampsPercentages](apple/ClairTests/AgentRateLimitTests.swift:26) | 維持：新形式の優先、bucket順序、0–100 clampという独自変換。 |
| [testSurfacesAppServerRequestError](apple/ClairTests/AgentRateLimitTests.swift:42) | 維持：外部serverの失敗を成功・空使用量に誤変換しない。 |
| [testResetDescriptionUsesLargestUsefulUnits](apple/ClairTests/AgentRateLimitTests.swift:52) | 維持：日本語の残り時間整形という独自処理。極小・同期fixtureで保守負担が低く、parserテストへ束ねても実益がない。 |
| [testParsesClaudeStatusLineUsage](apple/ClairTests/AgentRateLimitTests.swift:63) | 維持：Claude固有schemaとreset時刻の変換。Codex/OpenCodeとは別実装。 |
| [testClaudeMissingCacheIsUnknownInsteadOfAPIPlan](apple/ClairTests/AgentRateLimitTests.swift:78) | 維持：ファイル未存在を「APIプラン」と誤表示しない製品状態。 |
| [testClaudeNullWindowAndMalformedPayload](apple/ClairTests/AgentRateLimitTests.swift:86) | 維持：null windowと不完全payloadの扱い。入力型・欠損は異なる失敗条件で小さいfixture。 |
| [testClaudeCacheKeepsObservationTime](apple/ClairTests/AgentRateLimitTests.swift:96) | 維持：読込時刻ではなくファイルmtimeを観測時刻に使う製品判断。 |
| [testClaudeStatusLinePreservesLocalCommandAndUserOptions](apple/ClairTests/AgentRateLimitTests.swift:105) | 維持：実shellを通した引用とユーザー設定の優先・保持。既存コマンド破壊を検出。 |
| [testParsesOpenCodeGoUsage](apple/ClairTests/AgentRateLimitTests.swift:139) | 維持：OpenCode固有のISO時刻・3期間のschema変換。 |

## apple/ClairTests/AgentWorkflowTests.swift

| 関数 | 判定・理由 |
|---|---|
| [testFixedProfilesExposeStableIdentityAndLaunchDetails](apple/ClairTests/AgentWorkflowTests.swift:7) | D04：削除（プロフィール定義の丸写し） |
| [testProfilePassesSelectedModelAsQuotedLaunchArguments](apple/ClairTests/AgentWorkflowTests.swift:30) | M19：統合（シェルの正確な引用文字列を実行結果へ） |
| [testProfileBuildsProjectRootShellCommandWithQuotedValues](apple/ClairTests/AgentWorkflowTests.swift:44) | M19：統合（シェルの正確な引用文字列を実行結果へ） |
| [testShellCommandDoesNotExecuteCwdInjection](apple/ClairTests/AgentWorkflowTests.swift:58) | M19：統合（シェルの正確な引用文字列を実行結果へ） |
| [testShellCommandQuotesArgumentsIndependently](apple/ClairTests/AgentWorkflowTests.swift:88) | M19：統合（シェルの正確な引用文字列を実行結果へ） |
| [testAgentSessionLifecycleRoundTripsThroughCodable](apple/ClairTests/AgentWorkflowTests.swift:101) | M04：統合（terminal/agentのCodable往復を永続化境界1か所へ） |
| [testAgentControlSnapshotSeparatesFactualAttentionFromLifecycle](apple/ClairTests/AgentWorkflowTests.swift:134) | 維持：runningのままattention表示を成立させる独自projection。 |

## apple/ClairTests/ClairRuntimeProfileTests.swift

| 関数 | 判定・理由 |
|---|---|
| [testStableAndDevIdentitiesAreDisjoint](apple/ClairTests/ClairRuntimeProfileTests.swift:7) | 維持：設定値の単なる全コピーと違い、channel間のデータ・設定衝突を防ぐ不変条件。 |
| [testApplicationSupportPathsUseChannelDirectory](apple/ClairTests/ClairRuntimeProfileTests.swift:22) | 維持：既存ユーザーデータへの保存先を変えない契約。S02で重複smokeを除く。 |
| [testPreferencesDomainsDoNotShareValues](apple/ClairTests/ClairRuntimeProfileTests.swift:35) | D08：削除（UserDefaultsのドメイン分離をOSに対して再確認） |
| [testApplicationSupportDirectoryCanBeCreated](apple/ClairTests/ClairRuntimeProfileTests.swift:58) | D09：削除（FileManager.createDirectoryの薄いラッパー） |
| [testMissingApplicationSupportLocationIsReportedWithoutFallback](apple/ClairTests/ClairRuntimeProfileTests.swift:71) | 維持：nil時に勝手な保存先へ書かずエラー表示するBootstrap分岐。 |
| [testRustCoreSmokeCall](apple/ClairTests/ClairRuntimeProfileTests.swift:82) | 維持：実SwiftホストからRust ABIを呼ぶ。S02で2 assertを1つへ。 |

## apple/ClairTests/ClairUpdateTests.swift

| 関数 | 判定・理由 |
|---|---|
| [testSignedStableManifestCreatesAnUpdateForTheCurrentArchitecture](apple/ClairTests/ClairUpdateTests.swift:10) | 維持：署名済みmanifestから製品用artifact選択へ到達する正常系。 |
| [testManifestSignatureCoversTheArtifactHashAndURL](apple/ClairTests/ClairUpdateTests.swift:28) | 維持：改ざんhashを拒否するClairの署名payload契約。URL改ざんまでは未検証。 |
| [testManifestRejectsDevChannelAndOlderVersion](apple/ClairTests/ClairUpdateTests.swift:60) | 維持：Dev配布混入と同一version更新を止める別分岐。名前のolderに対し現fixtureは同一version。 |
| [testDevCoordinatorDoesNotCheckStableFeed](apple/ClairTests/ClairUpdateTests.swift:98) | 維持：Dev coordinatorのdisabled状態を守る。実ネットワーク未呼び出しまでの保証はない。 |
| [testPendingUpdateWritesStartupSuccessOnlyForMatchingStableLaunch](apple/ClairTests/ClairUpdateTests.swift:121) | 維持：別channel起動でupdate成功markerを誤作成しない。 |
| [testUpdateHelperContainsBoundedWaitAndRollbackPath](apple/ClairTests/ClairUpdateTests.swift:153) | D03：削除（更新ヘルパー内の文字列検索） |
| [testTerminationReasonSkipsNormalSessionTerminationForUpdateRestart](apple/ClairTests/ClairUpdateTests.swift:163) | 維持：update再起動で通常終了のsession破棄callbackを呼ばない。 |

## apple/ClairTests/CommandAdapterTests.swift

| 関数 | 判定・理由 |
|---|---|
| [testRegistryCoversAllTypedCommandsAndCodecPreservesID](apple/ClairTests/CommandAdapterTests.swift:28) | M13：統合（registry全件照合とpreflightの重複） |
| [testAgentListAndStatusAreExposedThroughTheSameIPCAdapter](apple/ClairTests/CommandAdapterTests.swift:71) | 維持：実routerのlist成功とmissing statusの構造化エラー。各methodのdispatch欠落を検出。 |
| [testLongestPrefixRoutingChoosesNestedProject](apple/ClairTests/CommandAdapterTests.swift:106) | 維持：親Projectではなく最長prefixのProjectへroutingする独自判断。 |
| [testMCPListFiltersCommandsAndCallReturnsStructuredError](apple/ClairTests/CommandAdapterTests.swift:133) | 維持：非公開commandがlistにも実callにも露出しない別境界。 |
| [testCLIWriteCommandUsesGUIApprovalGate](apple/ClairTests/CommandAdapterTests.swift:171) | 維持：承認handlerを通って実workspaceが変わる正経路。 |
| [testCLIWriteCommandCanBeDeniedBeforeDispatch](apple/ClairTests/CommandAdapterTests.swift:205) | 維持：承認拒否時に実workspaceが変わらない。正経路と統合して省く条件ではない。 |
| [testExplicitCLIConfirmationBypassesGUIApprovalForHeadlessTesting](apple/ClairTests/CommandAdapterTests.swift:240) | 維持：明示confirmed時のみ承認handlerを迂回する別経路。 |

## apple/ClairTests/ManagedWorktreeTests.swift

| 関数 | 判定・理由 |
|---|---|
| [testCreateListInspectAndRestartPreserveStableIdentity](apple/ClairTests/ManagedWorktreeTests.swift:8) | 維持：実Git worktreeを2つ作成し永続ID・rootを復元。root混線やcatalog消失を検出。 |
| [testCreateRejectsBranchConflictTargetConflictAndInvalidBase](apple/ClairTests/ManagedWorktreeTests.swift:43) | 維持：branch衝突・既存directory・不正baseは異なる非破壊拒否条件。 |
| [testCleanupRequiresCleanTargetNoActiveSessionAndExplicitConfirmation](apple/ClairTests/ManagedWorktreeTests.swift:84) | M17：統合（実行しないだけのcleanup取消テスト） |
| [testMissingWorktreeIsDiscoveredWithoutRetargeting](apple/ClairTests/ManagedWorktreeTests.swift:165) | 維持：外部削除されたworktreeを別rootに付け替えない。 |
| [testDetachedHeadIsNotLaunchableOrCleanable](apple/ClairTests/ManagedWorktreeTests.swift:183) | 維持：detached状態とcleanup拒否。agent launchの実行は未検証。 |
| [testCatalogCannotRetargetCleanupOutsideManagedRoot](apple/ClairTests/ManagedWorktreeTests.swift:208) | 維持：改ざんcatalogが管理外worktreeを削除対象にしない。 |
| [testManagedTerminalRootAndWorktreeIdentityRoundTrip](apple/ClairTests/ManagedWorktreeTests.swift:235) | M04：統合（terminal/agentのCodable往復を永続化境界1か所へ） |
| [testDirectAndManagedAgentLaunchCommandsKeepRootsDistinct](apple/ClairTests/ManagedWorktreeTests.swift:287) | 維持：生成commandに正しいcwdとworktree環境IDを渡す製品projection。完全な実行保証ではない。 |
| [testAgentLaunchRejectsManagedRootIdentityMismatch](apple/ClairTests/ManagedWorktreeTests.swift:318) | 維持：実coordinatorが誤ったworktree identityでtab/sessionを作らない。 |

## apple/ClairTests/NativeEditorTests.swift

| 関数 | 判定・理由 |
|---|---|
| [testAppKitNativeEditorRequiresExplicitDevOptIn](apple/ClairTests/NativeEditorTests.swift:9) | 維持：環境値とdefaultsの優先順位を守る。単なるdefault定数確認ではない。 |
| [testEditorSavesOnlyAfterExplicitSaveAndUndoRestoresCleanState](apple/ClairTests/NativeEditorTests.swift:38) | M05：統合（通常保存とUnicode保存を1つの実ファイルテストへ） |
| [testEditorPreservesUnicodeEmojiAndCombiningTextAsUTF8](apple/ClairTests/NativeEditorTests.swift:61) | M05：統合（通常保存とUnicode保存を1つの実ファイルテストへ） |
| [testMarkedTextCommitUpdatesTheDocumentOnce](apple/ClairTests/NativeEditorTests.swift:75) | 維持：AppKit delegateから文書へIME確定内容が渡る。回数「once」は未確認。 |
| [testSearchSelectionConvertsLineAndCharacterColumnToUTF16Range](apple/ClairTests/NativeEditorTests.swift:100) | 維持：検索位置から文書rangeへの独自変換。現fixtureは非BMP幅の差までは確認しない。 |
| [testSyntaxHighlighterRecognizesSwiftTokensWithoutHighlightingStringContents](apple/ClairTests/NativeEditorTests.swift:112) | 維持：自作tokenizerのkeyword/string/comment境界。ライブラリ保証ではない。 |
| [testSyntaxHighlighterAppliesOneDarkColorsToTextStorage](apple/ClairTests/NativeEditorTests.swift:148) | M06：部分削除（RGB定数を丸写しする色テスト） |
| [testExternalRewriteWinsWhenTheTabHasNoUnsavedEdits](apple/ClairTests/NativeEditorTests.swift:188) | M07：統合（watcherの同一パスrewriteを1ライフサイクルへ） |
| [testExternalRewriteDoesNotClobberUnsavedEdits](apple/ClairTests/NativeEditorTests.swift:200) | M07：統合（watcherの同一パスrewriteを1ライフサイクルへ） |
| [testSaveRefusesToOverwriteAnExternalChangeAndKeepsTheUnsavedBuffer](apple/ClairTests/NativeEditorTests.swift:215) | 維持：watcher通知前でもsave時点で外部変更を守る、独立したデータ損失防止。 |
| [testExternalDeletionRetainsTheTabAndItsBufferContent](apple/ClairTests/NativeEditorTests.swift:234) | M08：統合（欠落ファイル・削除再作成の開始状態を統合） |
| [testSurfaceKeepsMultipleEditorTabsIndependent](apple/ClairTests/NativeEditorTests.swift:247) | 維持：同一Project内の別文書buffer・dirty状態の隔離。Project間隔離とは別。 |
| [testWatcherReloadsAnExternalRewriteWhenTheTabIsClean](apple/ClairTests/NativeEditorTests.swift:269) | M07：統合（watcherの同一パスrewriteを1ライフサイクルへ） |
| [testWatcherDoesNotClobberUnsavedEditsOnExternalRewrite](apple/ClairTests/NativeEditorTests.swift:286) | M07：統合（watcherの同一パスrewriteを1ライフサイクルへ） |
| [testWatcherKeepsWatchingAfterExternalDeletionAndRecreation](apple/ClairTests/NativeEditorTests.swift:307) | M08：統合（欠落ファイル・削除再作成の開始状態を統合） |
| [testNonUTF8FileOpensReadOnlyErrorTab](apple/ClairTests/NativeEditorTests.swift:334) | 維持：不正encodingのファイルを編集・上書き可能にしない。 |
| [testMissingFileOpensEmptyEditableTab](apple/ClairTests/NativeEditorTests.swift:351) | M08：統合（欠落ファイル・削除再作成の開始状態を統合） |
| [testWatcherLoadsFileCreatedAfterOpeningMissingTab](apple/ClairTests/NativeEditorTests.swift:366) | M08：統合（欠落ファイル・削除再作成の開始状態を統合） |

## apple/ClairTests/ProjectEditorCommentAnchorTests.swift

| 関数 | 判定・理由 |
|---|---|
| [testInsertionsFollowExplicitBoundaryAffinityAndInternalEditsExpand](apple/ClairTests/ProjectEditorCommentAnchorTests.swift:7) | 維持：anchor前・開始境界・内部・終端で意味が異なる独自座標処理。 |
| [testMultipleEditsUsePreEditCoordinatesForEveryAnchor](apple/ClairTests/ProjectEditorCommentAnchorTests.swift:72) | 維持：複数editの前座標を二重補正しない。operation転記はA01で削減。 |
| [testFullDeletionOrphansAndExactHistoryRestoresTheSameAnchor](apple/ClairTests/ProjectEditorCommentAnchorTests.swift:109) | 維持：orphan化とundo/redo後の同一anchor復元。operation転記はA01。 |
| [testDuplicateTextCannotReconnectAnAnchorAndRevisionMismatchIsRejected](apple/ClairTests/ProjectEditorCommentAnchorTests.swift:142) | 維持：restoreのdocument ID検証・range保持。名前のduplicate text/revision mismatchは未検証。 |

## apple/ClairTests/ProjectEditorDiffModelTests.swift

| 関数 | 判定・理由 |
|---|---|
| [testReconstructsCRLFAndTrailingNewlineWithoutSyntheticRows](apple/ClairTests/ProjectEditorDiffModelTests.swift:7) | 維持：独自diffの改行保存とsource再構成。replaced存在の重複はA01。 |
| [testEmptyAndUnicodeDocumentsHaveRealRowsOnly](apple/ClairTests/ProjectEditorDiffModelTests.swift:35) | 維持：空→追加の別分岐と行番号。通常置換のCRLFテストで代替不可。 |
| [testStableIDsUseTheDocumentPairAndBothRevisions](apple/ClairTests/ProjectEditorDiffModelTests.swift:48) | M29：部分削除（少量の重複assert・内部IDへの不要な結合） |
| [testRenameMetadataAndBinarySupportStaySeparateFromTextRows](apple/ClairTests/ProjectEditorDiffModelTests.swift:65) | 維持：rename情報とbinary非テキスト扱いを独立に守る。 |
| [testCoordinatorCanCancelAndReturnsCurrentRevisionResult](apple/ClairTests/ProjectEditorDiffModelTests.swift:91) | M09：統合・置換（cancel前後の結果を1本の同期制御されたテストへ） / M29：部分削除（少量の重複assert・内部IDへの不要な結合） |
| [testTenThousandLineDiffRunsInBackgroundWithTwoThousandReplacements](apple/ClairTests/ProjectEditorDiffModelTests.swift:103) | M10：通常suiteから分離（10,000行と10秒閾値は性能評価へ） |
| [testCoordinatorDiscardsAStaleCalculationAfterCancellation](apple/ClairTests/ProjectEditorDiffModelTests.swift:122) | M09：統合・置換（cancel前後の結果を1本の同期制御されたテストへ） |

## apple/ClairTests/ProjectEditorDocumentTests.swift

| 関数 | 判定・理由 |
|---|---|
| [testAppliesMultiplePreEditUTF16RangesAtomically](apple/ClairTests/ProjectEditorDocumentTests.swift:7) | 維持：複数rangeの編集順序・通知・revision更新の独自原子性。 |
| [testRejectsStaleRevisionWithoutPartialMutation](apple/ClairTests/ProjectEditorDocumentTests.swift:44) | 維持：古い編集を受理せず内容/revisionを保持。外側のテストだけに寄せない最小文書契約。 |
| [testRejectsInvalidRangesIncludingSurrogateSplitsAndOverlaps](apple/ClairTests/ProjectEditorDocumentTests.swift:77) | 維持：負数・終端外・surrogate・overlapは独立の破損条件。 |
| [testSelectionChangesDoNotAdvanceRevisionOrCaptureSnapshots](apple/ClairTests/ProjectEditorDocumentTests.swift:120) | 維持：selectionのみでrevisionが変わらず同値通知を抑止。snapshot counterはA01で削減。 |
| [testSnapshotReasonsAreExplicitBoundaries](apple/ClairTests/ProjectEditorDocumentTests.swift:139) | D02：削除（自分で指定したsnapshot reasonと呼び出し回数） |

## apple/ClairTests/ProjectEditorSuggestionTests.swift

| 関数 | 判定・理由 |
|---|---|
| [testFakeProviderCreatesArbitraryInsertionDeletionAndReplacementEdits](apple/ClairTests/ProjectEditorSuggestionTests.swift:7) | M01：統合・置換（fake providerの期待編集配列を適用結果へ統合） |
| [testLineApprovalAppliesAtomicallyAndOneUndoRestoresExactUnicodeBytes](apple/ClairTests/ProjectEditorSuggestionTests.swift:31) | M29：部分削除（少量の重複assert・内部IDへの不要な結合） |
| [testHunkApprovalAppliesAllRowsInTheHunkAndAllApprovalFinishesProposal](apple/ClairTests/ProjectEditorSuggestionTests.swift:56) | 維持：hunk選択→残提案のrebasing→all承認という実利用の連鎖。 |
| [testRejectDoesNotMutateAndPartialLineSelectionReturnsUIError](apple/ClairTests/ProjectEditorSuggestionTests.swift:83) | M02：部分削除（rejectに渡していない文書の不変性） |
| [testOldProposalIsRejectedAfterManualExternalAndUndoRevisionChanges](apple/ClairTests/ProjectEditorSuggestionTests.swift:107) | M03：ケース削減（同じrevision拒否を3経路で繰り返す） |
| [testProposalPreservesTrailingNewlineAndUnicodeInFullApplication](apple/ClairTests/ProjectEditorSuggestionTests.swift:136) | M01：統合・置換（fake providerの期待編集配列を適用結果へ統合） |

## apple/ClairTests/ProjectEditorWebBridgeTests.swift

| 関数 | 判定・理由 |
|---|---|
| [testChangeUsesUTF16PreEditRangesAndAdvancesOnce](apple/ClairTests/ProjectEditorWebBridgeTests.swift:7) | D01：削除（製品から呼ばれないブリッジモデルの3テスト） |
| [testStaleChangeDoesNotMutateAndCanBeResynchronized](apple/ClairTests/ProjectEditorWebBridgeTests.swift:31) | D01：削除（製品から呼ばれないブリッジモデルの3テスト） |
| [testSelectionOnlyChangeDoesNotAdvanceRevisionOrCaptureSnapshot](apple/ClairTests/ProjectEditorWebBridgeTests.swift:64) | D01：削除（製品から呼ばれないブリッジモデルの3テスト） |
| [testWebEnvelopeRoundTripsWithoutFullContent](apple/ClairTests/ProjectEditorWebBridgeTests.swift:83) | M11：統合・置換（Swift同士の往復・文字列検索を実際のWeb契約へ） |
| [testSelectionEnvelopeContainsNoDocumentOrRevisionFields](apple/ClairTests/ProjectEditorWebBridgeTests.swift:99) | M11：統合・置換（Swift同士の往復・文字列検索を実際のWeb契約へ） |

## apple/ClairTests/ProjectEditorWebNativeIntegrationTests.swift

| 関数 | 判定・理由 |
|---|---|
| [testWebRangeTransactionKeepsNativeRevisionAndSaveInSync](apple/ClairTests/ProjectEditorWebNativeIntegrationTests.swift:8) | 維持：実ProjectEditorTab経路でWeb変更→dirty→disk保存→stale拒否を検証。 |
| [testSelectionAndViewportStateStayOnTheNativeDocument](apple/ClairTests/ProjectEditorWebNativeIntegrationTests.swift:47) | 維持：実tabへのscroll/selection反映とselection時revision維持。 |
| [testProjectTabPersistsEditorPositionWithoutBreakingLegacyShape](apple/ClairTests/ProjectEditorWebNativeIntegrationTests.swift:86) | 維持：古い保存JSONを読める固有の互換性。新型同士の往復だけでは代替不可。 |

## apple/ClairTests/ProjectGitTests.swift

| 関数 | 判定・理由 |
|---|---|
| [testStatusSeparatesStagedUnstagedAndUntrackedChanges](apple/ClairTests/ProjectGitTests.swift:8) | M16：統合（Git statusとstage/unstage/commitの重複起動） |
| [testDiffStageUnstageAndCommitPreserveStagedBoundary](apple/ClairTests/ProjectGitTests.swift:33) | M16：統合（Git statusとstage/unstage/commitの重複起動） |
| [testUntrackedDiffAndRenameDeleteStatusesAreSafe](apple/ClairTests/ProjectGitTests.swift:59) | 維持：untracked diff、rename元path、削除のporcelain解析は別分岐。 |
| [testCommitMessageAndBranchSwitchErrorsAreTypedAndSafe](apple/ClairTests/ProjectGitTests.swift:77) | 維持：空commit・traversal・dirty switch・Gitエラー後のbranch保持。余計な削除statusはA01。 |
| [testWorkspaceGitCommandsAndExternalIndexRefreshStayProjectScoped](apple/ClairTests/ProjectGitTests.swift:112) | 維持：実indexの変更をwatcher経由で拾いcommandがdispatchされる。Project隔離は未検証。 |
| [testNonGitProjectReportsAvailabilityWithoutThrowing](apple/ClairTests/ProjectGitTests.swift:158) | 維持：Gitでないfolderを例外ではなくnotRepositoryとして扱う製品境界。 |
| [testBranchWideReviewSeparatesCommittedAndUncommittedChangesAndGatesAdoption](apple/ClairTests/ProjectGitTests.swift:164) | 維持：レビュー範囲を分けsource/target dirtyをそれぞれ拒否。別repo・別副作用境界。 |
| [testCleanAdoptionCreatesTwoParentMergeCommitAndPreservesSourceAndTargetState](apple/ClairTests/ProjectGitTests.swift:236) | 維持：実Gitに正しいmerge方式を指示しsource branchとworktreeを保持する。 |
| [testDivergentAdoptionReturnsConflictAndLeavesTargetMergeInProgress](apple/ClairTests/ProjectGitTests.swift:293) | 維持：conflict時にmerge進行中状態と元HEADを守る失敗経路。 |
| [testAdoptionRejectsStalePlanAfterSourceHeadAdvances](apple/ClairTests/ProjectGitTests.swift:352) | 維持：prepare後のsource更新を検出し別変更を勝手に採用しない。 |
| [testCleanupCancellationLeavesManagedWorktreeInPlace](apple/ClairTests/ProjectGitTests.swift:387) | M17：統合（実行しないだけのcleanup取消テスト） |

## apple/ClairTests/ProjectKernelTests.swift

| 関数 | 判定・理由 |
|---|---|
| [testOpensGitNonGitAndTemporaryFoldersInOneWorkspace](apple/ClairTests/ProjectKernelTests.swift:8) | M15：ケース削減（plainとtemporaryが同じ入力分類） |
| [testDuplicateCanonicalRootIsRejectedWithoutChangingState](apple/ClairTests/ProjectKernelTests.swift:32) | 維持：dotdot正規化とsymlink解決は別のduplicate経路。 |
| [testInvalidAndPermissionErrorsPreserveOtherProjects](apple/ClairTests/ProjectKernelTests.swift:65) | 維持：missing/file/unreadable失敗で既存Projectを壊さない。注入エラーの転記はA01。 |
| [testMetadataCloseReopenAndStorePersistenceKeepStableProjectID](apple/ClairTests/ProjectKernelTests.swift:99) | 維持：rename/color/close/reopen後の実store identity保持。layout復元とは別の永続化対象。 |
| [testCommandRegistryExposesTypedRiskAndAvailabilityPreflight](apple/ClairTests/ProjectKernelTests.swift:150) | M13：統合（registry全件照合とpreflightの重複） |
| [testHumanCommandSurfacesDispatchTheSameCommandID](apple/ClairTests/ProjectKernelTests.swift:174) | M14：ケース削減（sourceラベルだけを変えて3回dispatch） |
| [testHumanCommandSurfacePreservesUnavailableReasonAndDisplaysError](apple/ClairTests/ProjectKernelTests.swift:210) | M13：統合（registry全件照合とpreflightの重複） |
| [testConfigurableShortcutRejectsInvalidAndConflictingMappings](apple/ClairTests/ProjectKernelTests.swift:242) | M29：部分削除（少量の重複assert・内部IDへの不要な結合） |
| [testFileTreeLoadsNestedFoldersAndOpensFixtureEditorTab](apple/ClairTests/ProjectKernelTests.swift:322) | 維持：実surfaceで展開→非同期treeロード→文書オープン。scanner単体とは別接続。 |
| [testRestoredExpandedDirectoriesFinishLoadingAfterSurfaceCreation](apple/ClairTests/ProjectKernelTests.swift:356) | 維持：初回expandではなく復元済みexpanded集合から起動する固有の非同期経路。 |
| [testFileTreeWatcherRefreshesExternalCreateRenameAndDelete](apple/ClairTests/ProjectKernelTests.swift:384) | 維持：外部作成・rename・削除は異なるfilesystem通知。1 lifecycleに既に統合済み。 |
| [testFileTreeShowsMissingRootAndRecoversWhenRootReturns](apple/ClairTests/ProjectKernelTests.swift:422) | 維持：root自体の消失と復旧。子ファイル更新と監視再確立条件が違う。 |
| [testProjectSwitchKeepsFileTreeSelectionAndTabsIsolated](apple/ClairTests/ProjectKernelTests.swift:444) | M12：統合（Project隔離・再起動復元を2 Projectの1経路へ） |
| [testPaneLayoutSupportsNestedSplitsTabMoveCloseMaximizeAndEqualize](apple/ClairTests/ProjectKernelTests.swift:479) | 維持：実pane treeの移動・最大化・均等化・closeでtabを消失しない。既に1シーケンス。 |
| [testThreeProjectPaneLayoutsRemainIsolatedAcrossRestart](apple/ClairTests/ProjectKernelTests.swift:531) | M12：統合（Project隔離・再起動復元を2 Projectの1経路へ） |
| [testWorkspaceActivitySelectionPersistsPerProjectAcrossRestart](apple/ClairTests/ProjectKernelTests.swift:579) | M12：統合（Project隔離・再起動復元を2 Projectの1経路へ） |
| [testCorruptOrMissingWorkspaceSnapshotFallsBackWithoutReplacingCorruptData](apple/ClairTests/ProjectKernelTests.swift:615) | 維持：破損保存内容をfallbackで上書きしない、欠落との区別。 |
| [testNavigationOpensSearchResultsAndAppliesReplacementToDirtyBuffers](apple/ClairTests/ProjectKernelTests.swift:641) | 維持：検索結果→文書オープン→replaceをbufferに適用しdiskを保持する接続。 |
| [testSearchResultsRefreshAfterExternalFileChange](apple/ClairTests/ProjectKernelTests.swift:679) | 維持：既存検索queryの結果がwatcher後に更新される。tree更新だけでは代替不可。 |

## apple/ClairTests/ProjectNavigationTests.swift

| 関数 | 判定・理由 |
|---|---|
| [testQuickOpenFlattensFilesAndRanksFilenameMatches](apple/ClairTests/ProjectNavigationTests.swift:8) | 維持：パスflattenとfilename優先rankingという独自検索規則。 |
| [testLoadedTreeIsLazyBoundedAndIgnoresGeneratedDirectories](apple/ClairTests/ProjectNavigationTests.swift:38) | 維持：lazy表示・生成物除外・子数上限。300実ファイルはresource境界確認に使っている。 |
| [testPrefetchedDirectoryCacheRebuildsExpandedTreeWithoutWalkingDisk](apple/ClairTests/ProjectNavigationTests.swift:95) | 維持：cacheを与える独自構成経路。disk再走査不在までは検証していない。 |
| [testWatcherGraphIsLimitedToLoadedDirectories](apple/ClairTests/ProjectNavigationTests.swift:117) | 維持：watcher数の資源上限と未ロード範囲の除外。単なる内部配列の一致ではない。 |
| [testSearchReportsUnicodeLineColumnsAndSkipsGitAndBinaryFiles](apple/ClairTests/ProjectNavigationTests.swift:147) | 維持：独自検索の行列位置・大小文字・対象除外。ファイルtree除外とは別経路。 |
| [testReplacementPreviewIsPureAndContainsReplacementBytes](apple/ClairTests/ProjectNavigationTests.swift:180) | 維持：preview中にdiskを変えず、同一行の複数matchを置換。最終applyテストとは別条件。 |
| [testFileURLRejectsAbsoluteAndTraversalPaths](apple/ClairTests/ProjectNavigationTests.swift:209) | 維持：外部からのpathをProject内に閉じる独自validation。 |
| [testDebugDestinationIsIncludedInNavigationStrip](apple/ClairTests/ProjectNavigationTests.swift:219) | D06：削除（ナビゲーション配列のコピー） |
| [testDAPFrameDecoderHandlesFragmentedAndCoalescedMessages](apple/ClairTests/ProjectNavigationTests.swift:229) | 維持：独自Content-Length framingの分割/結合受信。buffer.isEmptyだけA01で削除。 |
| [testDAPFrameDecoderRejectsOversizedFrames](apple/ClairTests/ProjectNavigationTests.swift:251) | 維持：encode側のpayload上限拒否。名前と違い受信decodeの拒否は未検証だが送信上限には価値。 |
| [testDebugSourceLocationRevealsOnlyFilesInsideProject](apple/ClairTests/ProjectNavigationTests.swift:258) | 維持：debuggerからの位置を実tabへ反映しProject外pathを拒否する。 |
| [testDebugSessionStoresAndTogglesProjectBreakpoints](apple/ClairTests/ProjectNavigationTests.swift:286) | 維持：同じbreakpointの再操作が重複追加でなく解除となる独自状態遷移。 |

## apple/ClairTests/TerminalTests.swift

| 関数 | 判定・理由 |
|---|---|
| [testTerminalTextViewInitializesAndAcceptsTranscript](apple/ClairTests/TerminalTests.swift:9) | D05：削除（NSTextViewのsetter/getterと初期設定） |
| [testTerminalGridRetainsCursorMovesAnsiAttributesAndWideGlyphs](apple/ClairTests/TerminalTests.swift:18) | 維持：libvtermだけでなく独自C/Swiftセル変換を含む。 |
| [testTerminalGridSwitchesAlternateScreenWithoutDiscardingPrimaryGrid](apple/ClairTests/TerminalTests.swift:37) | 維持：独自terminalのalternate screen保持。通常gridの文字確認と異なるモード。 |
| [testTerminalGridKeepsScrollbackAndTerminalTextViewGrowsDocumentHeight](apple/ClairTests/TerminalTests.swift:45) | M20：部分削除（高さの実装式をテストでも再計算） |
| [testTerminalControlKeyMappingSendsRawPtyBytes](apple/ClairTests/TerminalTests.swift:60) | 維持：macOS keycode→PTY control byteの独自mapping。Ctrl-Cなど実操作に直結。 |
| [testDecoderAcceptsPartialFramesAndPreservesBinaryInput](apple/ClairTests/TerminalTests.swift:67) | 維持：Swift側の独自CP framing。Rustテストとは異なる実装。payload重複はA01。 |
| [testFrameValidationRejectsInvalidDimensionsAndOversizedPayloads](apple/ClairTests/TerminalTests.swift:84) | 維持：Swift送信寸法と受信payload上限の別境界。 |
| [testSanitizerHandlesSplitEscapeSequencesAndKeepsUtf8Text](apple/ClairTests/TerminalTests.swift:102) | 維持：独自state machineのchunk跨ぎANSI/OSC除去。 |
| [testSanitizerReportsGroundBellButNotOscTerminator](apple/ClairTests/TerminalTests.swift:116) | 維持：同じBEL byteでもOSC終端では通知しない独自状態判定。 |
| [testTranscriptBufferCapsAtUtf8Boundary](apple/ClairTests/TerminalTests.swift:131) | 維持：byte上限でUnicodeを途中切断しない独自truncate処理。 |
| [testSessionBrokerDecoderAcceptsPartialAndBatchedFrames](apple/ClairTests/TerminalTests.swift:139) | 維持：CB固有framing。CP decoderと別コードなので同じ形式のテストでも重複扱いしない。 |
| [testSessionBrokerDecoderAllowsLargeCompleteBatchesAndBoundsPayloads](apple/ClairTests/TerminalTests.swift:157) | 維持：バッチ全体と1frameの上限を混同しない回帰防止。 |
| [testSessionBrokerPayloadFramesDecodeAndRejectInvalidRanges](apple/ClairTests/TerminalTests.swift:179) | 維持：手組みCB payloadからoffset/UUID/errorを復元。gap範囲の独自validation。 |
| [testTerminalTabPersistsStableSessionID](apple/ClairTests/TerminalTests.swift:223) | M04：統合（terminal/agentのCodable往復を永続化境界1か所へ） |
| [testAgentTerminalTabPersistsProfileMetadata](apple/ClairTests/TerminalTests.swift:233) | M04：統合（terminal/agentのCodable往復を永続化境界1か所へ） |

## packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift

| 関数 | 判定・理由 |
|---|---|
| [negotiatesTheIntersectionWithoutDowngradingTheMajor](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:7) | 維持：minor・capability・frame上限の独自交渉。 |
| [rejectsAProtocolMajorMismatch](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:28) | 維持：非互換majorを拒否。正常交渉とは別分岐。 |
| [binaryTerminalFramesPreserveRawBytes](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:41) | 維持：独自binary encoder/decoder。合成Codableの往復とは異なりfield配置・byte保持に価値。 |
| [binaryTerminalFramesRejectTrailingAndOversizedData](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:59) | 維持：末尾余分byteとpayload上限の別validation。 |
| [catalogUsesStableIDsAndWorktreeScope](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:87) | 維持：grantのworktree許可範囲でcatalogを制限する独自認可。 |
| [inputSequencerUsesArrivalOrderAndMakesDuplicatesIdempotent](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:104) | M21：統合・部分削除（モバイル入力の順序・重複排除を3回確認） |
| [inputSequencerRejectsRevokedOrMismatchedOperations](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:135) | 維持：revoked/read-onlyの拒否。identity mismatchという名前の部分は未検証。 |
| [inputOperationIDCannotBeReusedForDifferentPayload](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:160) | 維持：同じoperation IDで別payloadを許さない。duplicate idempotencyとは別。 |
| [agentControlContractExposesFactualStateAndCapabilities](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:186) | M22：統合・置換（DTOのCodable往復とfactory転記） |
| [agentControlAuthorizerRequiresMatchingScopeAndIdentity](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:211) | 維持：signal権限の不足時にinterruptを拒否する独自authorizer。 |
| [agentLaunchAuthorizerOnlyAcceptsRegisteredProfilesAndVisibleWorktrees](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:248) | 維持：任意shell profileと範囲外direct launchの拒否。 |
| [agentInputAuthorizerRequiresSteerScopeAndPayload](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:303) | 維持：agent入力の正常変換と空payload拒否。不足scopeは未検証。 |
| [mobileHostPairingIsOneTimeAndPersistsOnlyNonSecretMaterial](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:355) | 維持：one-time secretの再利用拒否と、実secret/tokenを保存しない境界。 |
| [mobileHostAuthenticatesWithFreshChallengeAndRevokesConnections](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:397) | 維持：本物の認証・device失効でconnection IDを閉じる判断。 |
| [mobileHostRejectsExpiredPairingAndFingerprintChanges](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:426) | 維持：期限とhost identityの相違は別の信頼境界。 |
| [mobileHostKeepsSubscriberCursorsIndependentAndReportsGaps](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:468) | 維持：subscriber queue超過とjournal欠落は別実装。どちらのgapも必要。 |
| [mobileHostUpdatesSessionProjectionWithoutResettingStream](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:564) | 維持：session metadata更新で既存出力offset/queueを失わない。 |
| [mobileHostAppliesInputInArrivalOrderAndDoesNotResizeFromViewport](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:609) | M21：統合・部分削除（モバイル入力の順序・重複排除を3回確認） |
| [mobileTransportDecoderHandlesPartialFramesAndRejectsOversizedFrames](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:656) | 維持：transport外枠とterminal内frameは別層。1byteずつの小fixtureも許容できるコスト。 |
| [mobileRPCConnectionRequiresAuthenticationBeforeProjectAccess](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:682) | M25：統合（認証正常系setupの二重化） |
| [mobileClientKeepsViewportLocalAndRecoversFromStreamGaps](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:731) | M24：部分削除（viewportのsetter/getterをlocal性の保証としない） |
| [mobileClientCanAttachBeforeInitialReplayArrives](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:788) | 維持：receiptがoutputより先に来る現実的race。通常attachと順序が異なる。 |
| [mobilePairingLinkDeepLinkRoundTripsIdentityAndTransport](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:824) | M23：部分削除（存在しない秘密値を検索する否定assert） |
| [mobileAttentionPayloadContainsOnlyOpaqueWakeMetadata](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:852) | M23：部分削除（存在しない秘密値を検索する否定assert） |
| [mobileRequestFactoryProjectsSharedControlMethods](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:874) | M22：統合・置換（DTOのCodable往復とfactory転記） |
| [mobileRequestFactoryEncodesAgentInput](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:895) | M22：統合・置換（DTOのCodable往復とfactory転記） |
| [mobileHostDeliversFreshAcceptedOperationsToTheApplicationBridge](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:910) | M21：統合・部分削除（モバイル入力の順序・重複排除を3回確認） |
| [mobileListenerAndClientCompleteLoopbackAuthentication](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:998) | M25：統合（認証正常系setupの二重化） |
| [mobileDisableClosesRemoteAccessWithoutDeletingLocalSessions](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:1072) | 維持：remote無効化でlocal sessionを失わずアクセス拒否する製品状態。 |
| [mobileDisconnectOnlyRemovesSubscriptionsFromThatConnection](packages/ClairMobileKit/Tests/ClairMobileKitTests/MobileControlProtocolTests.swift:1106) | 維持：同じdeviceの別connectionを巻き込まないcleanup範囲。 |

## crates/clair-cli/src/main.rs

| 関数 | 判定・理由 |
|---|---|
| [parses_agent_control_commands_with_explicit_confirmation](crates/clair-cli/src/main.rs:1119) | 維持：CLI引数→agent inputとconfirmed flagの独自変換。 |
| [parses_generic_command_json_as_an_object](crates/clair-cli/src/main.rs:1143) | 維持：generic commandのparamsと既定confirmedの扱い。 |
| [parses_path_locations_without_losing_colons](crates/clair-cli/src/main.rs:1160) | 維持：path内colonとline/column suffixの独自解釈。3入力は別分岐。 |
| [discovers_an_enclosing_app_bundle](crates/clair-cli/src/main.rs:1176) | 維持：bundle内Resourcesからアプリを特定する独自path探索。 |
| [exchanges_one_newline_delimited_json_response_over_unix_socket](crates/clair-cli/src/main.rs:1185) | 維持：製品send_jsonのrequest終端・write shutdown・response読込を実socketで検証。 |
| [config_uses_the_channel_specific_socket_directory](crates/clair-cli/src/main.rs:1225) | 維持：Rust CLIがSwift hostと同じStable socketを選ぶ契約。Swiftのprofileテストでは代替不可。 |

## crates/clair-core/src/lib.rs

| 関数 | 判定・理由 |
|---|---|
| [rust_and_c_abi_smoke_values_match](crates/clair-core/src/lib.rs:32) | D07：削除（Rustの定数返却・定数とdefaultの比較） |

## crates/clair-ptyhost/src/broker.rs

| 関数 | 判定・理由 |
|---|---|
| [attach_frame_round_trips_bounded_session_metadata](crates/clair-ptyhost/src/broker.rs:1473) | 維持：CB attachの独自複合binary構造を確認。integration fixtureとはmetadata/cursor条件が異なる。 |
| [malformed_broker_frame_is_rejected_before_payload_allocation](crates/clair-ptyhost/src/broker.rs:1483) | 維持：CB decoderの割当て前payload上限。外側のerror返信とは別。 |
| [partial_broker_header_is_not_accepted](crates/clair-ptyhost/src/broker.rs:1495) | 維持：CB独自readerが欠損headerをEOF正常終了扱いしない。 |
| [attach_rejects_invalid_session_id_and_dimensions](crates/clair-ptyhost/src/broker.rs:1504) | 維持：UUID形状と寸法は異なるvalidation境界。 |
| [slow_subscriber_stays_bounded_and_reports_gap](crates/clair-ptyhost/src/broker.rs:1522) | 維持：小chunkの蓄積超過を制限しgapを報告するqueueアルゴリズム。 |
| [oversized_subscriber_chunk_becomes_gap_without_queue_growth](crates/clair-ptyhost/src/broker.rs:1534) | 維持：単一chunkが上限を超える別分岐。蓄積超過テストで代替不可。 |

## crates/clair-ptyhost/src/main.rs

| 関数 | 判定・理由 |
|---|---|
| [smoke_response_is_versioned_and_stable](crates/clair-ptyhost/src/main.rs:379) | D07：削除（Rustの定数返却・定数とdefaultの比較） |
| [spawn_options_have_a_safe_terminal_default](crates/clair-ptyhost/src/main.rs:384) | D07：削除（Rustの定数返却・定数とdefaultの比較） |
| [dimensions_are_bounded](crates/clair-ptyhost/src/main.rs:391) | 維持：CLI文字列から寸法範囲を制限する独自parse。 |
| [spawn_options_parse_working_directory_shell_and_size](crates/clair-ptyhost/src/main.rs:398) | 維持：argv→PTY起動設定の各field対応。default定数比較とは別。 |
| [broker_options_require_explicit_socket_and_catalog_paths](crates/clair-ptyhost/src/main.rs:418) | 維持：必須catalog/path欠落拒否と正常parse。 |

## crates/clair-ptyhost/src/protocol.rs

| 関数 | 判定・理由 |
|---|---|
| [frame_round_trip_preserves_binary_input](crates/clair-ptyhost/src/protocol.rs:222) | 維持：独自CP frame serialization。生0xff/0x00を落とさない。 |
| [partial_header_is_reported_without_accepting_a_frame](crates/clair-ptyhost/src/protocol.rs:231) | 維持：CP独自readerでpartial headerを正常終了にしない。 |
| [oversized_frame_is_rejected_before_payload_allocation](crates/clair-ptyhost/src/protocol.rs:239) | 維持：CP decoderのpayload割当て前上限検査。 |
| [resize_rejects_zero_dimensions](crates/clair-ptyhost/src/protocol.rs:257) | 維持：row=0、column=0、不正payload長は異なる拒否条件。 |
| [control_frame_payload_lengths_are_checked](crates/clair-ptyhost/src/protocol.rs:277) | 維持：closeとexitの異なる長さ契約。片方だけではmatch armの漏れを検出できない。 |

## crates/clair-ptyhost/tests/live_shell.rs

| 関数 | 判定・理由 |
|---|---|
| [shell_command_round_trips_raw_output_and_resize](crates/clair-ptyhost/tests/live_shell.rs:119) | M26：統合（PTY正常系4本を2起動に統合） |
| [shell_receives_clair_terminal_environment](crates/clair-ptyhost/tests/live_shell.rs:139) | M26：統合（PTY正常系4本を2起動に統合） |
| [shell_does_not_inherit_stale_host_environment](crates/clair-ptyhost/tests/live_shell.rs:162) | M26：統合（PTY正常系4本を2起動に統合） |
| [shell_preserves_cjk_and_osc_bytes](crates/clair-ptyhost/tests/live_shell.rs:221) | M26：統合（PTY正常系4本を2起動に統合） |
| [terminal_flood_completes_without_host_crash](crates/clair-ptyhost/tests/live_shell.rs:241) | M27：削除・統合（100行のflood smoke） |
| [malformed_frame_is_rejected_and_shell_is_reaped](crates/clair-ptyhost/tests/live_shell.rs:263) | 維持：不正frame後に実hostがerror/exitを返し終了。unit decoderだけでは後始末経路を保証しない。 |

## crates/clair-ptyhost/tests/session_broker.rs

| 関数 | 判定・理由 |
|---|---|
| [broker_rejects_bounded_frames_and_reports_missing_sessions](crates/clair-ptyhost/tests/session_broker.rs:275) | 維持：未attach段階のprotocol error返信とsessionMissing。実socket境界に価値。 |
| [broker_reports_protocol_errors_after_attach](crates/clair-ptyhost/tests/session_broker.rs:305) | 維持：attach後の別dispatchループで不正kindを拒否。前段階の拒否と非重複。 |
| [broker_reattaches_running_pty_after_client_disconnect](crates/clair-ptyhost/tests/session_broker.rs:330) | 維持：client切断後に同一PTYへ再接続しcursor以前を再送しない。marker重複だけA01。 |

## .agents/skills/clair-issue-executor/scripts/test_item_lease.py

| 関数 | 判定・理由 |
|---|---|
| [test_resolves_next_and_rejects_incomplete_dependency](.agents/skills/clair-issue-executor/scripts/test_item_lease.py:77) | 維持：queue内next選択と未完了依存の拒否。lease排他とは異なる製品ルール。 |
| [test_one_worktree_and_one_item_are_exclusive](.agents/skills/clair-issue-executor/scripts/test_item_lease.py:84) | M28：統合（lease許可と競合拒否で同じworktreeを作り直す） |
| [test_independent_items_can_be_leased_in_parallel](.agents/skills/clair-issue-executor/scripts/test_item_lease.py:136) | M28：統合（lease許可と競合拒否で同じworktreeを作り直す） |

## 関数形式ではない検査

| 対象 | 判定 |
|---|---|
| [scripts/smoke-app-link.sh](scripts/smoke-app-link.sh) | S01：手書き別build経路を削除。minOS検査は必要なら実bundleへ移す。 |
| [scripts/smoke-swift-rust.sh](scripts/smoke-swift-rust.sh) | S02：FFI実呼び出しをXCTestへ集約して独立実行体生成を削除。 |
| [apple/Smoke/SwiftRustSmoke.swift](apple/Smoke/SwiftRustSmoke.swift) | D09/S02：profile・ディレクトリ重複確認を除去し独立smokeを廃止候補。 |
| [scripts/smoke-bundles.sh](scripts/smoke-bundles.sh) | 維持：実Stable/Dev bundleのmetadata、同梱CLI実行、Rust symbolの検証。 |
| [scripts/check-workspace.sh](scripts/check-workspace.sh) | S03：重複plutilとID grepを縮小。その他の高速設定確認は維持。 |
| [scripts/validate-xcode-project.rb](scripts/validate-xcode-project.rb) | 維持：project/scheme間のID・file参照整合。コンパイラの型検査だけではない。 |
| [scripts/check-ignored-artifacts.sh](scripts/check-ignored-artifacts.sh) | 維持：意図した生成物のignoreと追跡混入。プロジェクト運用ルールを実Gitで確認。 |
| [scripts/benchmarks/validate-result.rb](scripts/benchmarks/validate-result.rb) | 維持：benchmark結果のschema/指標契約。単体テストの重複ではない。 |
| [prototypes/native-editor-poc/Sources/NativeEditorPoC/Checks.swift](prototypes/native-editor-poc/Sources/NativeEditorPoC/Checks.swift) | P01〜P05：診断分離、IME/色確認統合、巨大fixture縮小。その他のadapter・Undo・anchor・policy別境界・lifecycleは維持。 |
| [prototypes/native-editor-poc/Sources/NativeEditorPoC/TextKitProbe.swift](prototypes/native-editor-poc/Sources/NativeEditorPoC/TextKitProbe.swift) | P04：代替ライブラリ診断を通常self-testから外す。 |
| [.github/workflows/native-smoke.yml](.github/workflows/native-smoke.yml) | make ciへの入口。S01/S02をMakefileで整理すればworkflowの重複jobはない。 |
| [.github/workflows/stable-release.yml](.github/workflows/stable-release.yml) | 維持：Release固有のpackage、version/public key、artifact存在確認。Debug smokeで代替不可。 |
