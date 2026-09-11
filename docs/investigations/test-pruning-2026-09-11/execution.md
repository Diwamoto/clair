# テスト削除・統合の実施記録

2026-09-11、[静的監査](README.md)の承認後に、D01–D10、M01–M29、S01–S03、P01–P05とA01の重複assert整理を実施した。既存の未コミットのUI／Debug変更を維持し、コミットは行っていない。以下は監査時点ではなく、変更後の検証結果。

## 実施内容と残した保証

| 監査ID | 実施内容 | 残る現実的な不具合の検出 |
| --- | --- | --- |
| D01–D10 | 未使用ブリッジモデル、snapshotカウンター、定数転記、setter/getter、OS／FileManagerの再確認、巨大履歴を実際には読み込まないテストを削除 | 製品の文書変更・保存、履歴の上限・永続化、実ホストのFFI確認は残す |
| M01–M03 | fake providerの配列確認を提案承認後の本文へ統合。rejectの空振りassertと手作りのrevision拒否重複を削除 | Unicode／CRLFの複数編集、部分承認、外部変更・Undo後の古い提案拒否 |
| M04 | terminal／agentの重複CodableテストをManagedWorktreeの保存・読込・surface復元へ集約。固定legacy JSONを追加 | session ID、profile、model、execution root、worktree関連付けと旧データの読込 |
| M05–M08 | 通常保存にUnicodeを含め、watcherのclean→dirtyを1ライフサイクルに。欠落・削除・再作成の開始状態assertをwatcherケースへ統合 | 明示save前のディスク不変、保存バイト、Undo、外部変更による未保存本文の破壊防止、監視の継続 |
| M09–M10 | diff計算を同期制御できるclosureとして注入し、cancel検証の固定sleep／巨大fixture依存を除去。大規模計測は`make benchmark-diff`へ分離 | 完了した古い結果を返さず、次revisionの結果を返す。独自diffの本文再構成は通常suiteにも残る |
| M11 | Swift同士の往復を、固定Web JSON→実際のmessageBody decoder→編集範囲の検証に置換 | `from`／`to`→UTF-16 range、revision、selection、scroll、undo／redoフラグの受信変換 |
| M12–M15 | Project隔離・選択・activity・再起動復元を2 Projectのシナリオに統合。registry全件照合、sourceラベルだけの反復、同分類のtemporaryケースを削減 | Projectごとに異なる状態が切替・復元後にも維持され、利用不可コマンドの理由とriskが伝わる |
| M16–M20 | Git statusをstage／unstage／commitへ統合。cleanup前状態、履歴query、シェル引用、terminal高さの重複を整理 | staged後に再編集した境界、未追跡ファイル、cleanup、実シェルのcwd／引数・特殊文字、表示領域の成長 |
| M21–M25 | mobileの認証済みRPC→handlerに入力順序・重複排除とfactory利用を集約。固定wire JSONへ置換。viewport setterと存在しない秘密値の検索を削除 | 実際の要求変換・認証・副作用回数、input順序、割込みバイト、wire互換性。scope／revoke／gapの独立境界は維持 |
| M26–M27 | PTY正常系の重複起動を統合。環境汚染ケースへ通常環境の検証も集約。100行の末尾だけのsmokeを、同一起動で4,096行の全バイト確認へ変更 | resize、CJK／OSC、出力欠落、環境の漏出。echoでは合格できないよう準備完了後にpayloadを送る |
| M28 | lease許可と競合拒否を同じlinked worktree fixtureで確認 | 別作業ツリーで許可し、既存leaseとの競合は拒否 |
| M29・A01 | 包含されるassert、内部buffer／ID／operation enum、helperが既に確認したmarker、重複shortcutケースを削除 | コメント座標・Undo／Redo、protocolの実payload、入力拒否後の状態保持などの独立した結果 |
| S01–S03 | `smoke-ffi`／`smoke-app-link`の別ビルド経路と実行ファイルを削除。minOSを実bundle検査へ移動。workspaceの重複構文検査・bundle ID文字列検索を削除 | 実際のXcodeビルド、実ホストFFI、Stable／DevのID・実行ファイル・CLI・Rust symbol・minOS |
| P01–P05 | upstream既知不具合・TextKit2等を`--diagnostics`へ分離。IMEとUndo／Redoを統合。具体的token確認へ集約し、通常fixtureを縮小 | アダプタの編集・Undo／Redo、2種類のcomposition range、各言語のtoken／再ハイライト、diff view、native／fallbackの異なる境界 |

件数を目的にはしていないが、追跡用の結果はdesktop 163→136（通常は性能計測1件をskip）、mobile 30→27、Rust 32→26、lease Python 3→2。複数assertの削除やsmoke経路削除はこの関数数に含まれない。PoCは別集計。

## 実施中に見つかった不安定さ

`broker_reports_protocol_errors_after_attach`は、不正要求直後の最初のframeをERRORと決め打ちしていた。再実行時に、正常な非同期OUTPUT（0x82）が先着して失敗した。OUTPUTの構造を確認しながら5秒の期限内にERRORを待つ形に修正し、不正要求の拒否code自体の検証は維持した。製品のbroker処理は変更していない。

PTY harnessのframe待機にもtimeoutと子プロセスの終了処理を追加した。timeoutは性能の合否基準ではなく、応答が来ない際にテストが待ち続けるのを防ぐため。

## 検証結果

| 実行 | 結果 |
| --- | --- |
| `make test-swift` | 136件、1 skip、失敗0。テスト本体36.332秒。skipは下記の明示計測で実行 |
| `make benchmark-diff` | 1件通過。10,000行／2,000置換の計算1.545秒。固定10秒閾値は設けていない |
| `make test-mobile` | Swift Testing 27件通過 |
| `make test-rust lint-rust` | Rust 26件通過。rustfmt／Clippy通過 |
| brokerの失敗した1件を個別再実行 | 修正後に通過 |
| lease Pythonテスト | 2件通過 |
| `make smoke-bundles artifact-check` | Stable／Devビルド、両bundleの検査、生成物のignore検査が通過 |
| `make workspace-check` | 通過 |
| 変更したdesktop／mobile Swiftの`swift format lint --strict` | 通過 |
| 変更したshell scriptの`bash -n` | 通過 |
| PoC release build + `run.sh --self-test` | 通常の70判定すべて通過 |
| PoC `run.sh --self-test --diagnostics` | 75判定中72成功、3件は明示した既知のexpected failure（upstream multicursor undoと2種類のIME更新履歴）。想定外の失敗0 |

最初のdesktop実行はテストホストが途中で終了code 0となり、2件が中断された。既存Dev watcherには`Clair Dev`を終了・再起動する処理があり、テスト中もソースを変更していた。watcherを検証中だけ一時停止した再実行は通過した。watcherは終了時に復帰させ、PoCも終了済み。新しい常駐開発環境は開始していない。

リポジトリ全体のSwift format検査は、今回変更していない`ClairLifecycle.swift`、`MobileControlRuntimeBridge.swift`や既存のUI／Debug編集等のformatエラーで不合格。今回の整理に混ぜて修正はしていない。`make ci`全体の合格を主張するものではない。

## 監査案からの判断・限界

- A01のpermission error型確認は残した。mockを直接呼んだ結果ではなく、workspaceのcommand実行を通じて型付きエラーが保持されることを検証するため。失敗後のProject集合・active ID不変も残す。
- M11は受信側の固定契約を検証する。JavaScriptを実行して送信内容を取り出すE2Eではなく、JS送信側が全文を送らないことまでは保証しない。削除したSwift側の文字列検索もこの保証を持っていなかった。
- M04で行うJSONの実ファイル保存・読込は、アプリ全体のsessionストア再起動ではない。読込済みtabをsurface復元へ渡して関連付けを確認する。Projectの実ストア再起動はM12のテストが扱う。
- PoCの巨大fixtureは、native選択policyに必要な境界値を保持した。通常のdiff viewは40行とし、大規模計測用fixtureはbenchmark側に残した。
- テスト削減前の同条件の実行時間や不安定率は測定していない。短縮率やカバレッジ維持率を成果として算出していない。
- 実行ログはローカルの`/tmp/clair-prune-*.log`、Xcode結果は`.build/xcode/tests/Logs/Test`に保存。PoCは`CLAIR_POC_EVIDENCE_PATH`で一時ファイルへ出力し、過去のevidenceを上書きしていない。
