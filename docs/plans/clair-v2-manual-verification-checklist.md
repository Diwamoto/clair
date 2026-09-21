# Clair v2 実機検証チェックリスト

Date: 2026-09-21
Parent: [native rewrite queue](../clair-tasks.md) / [kanban](../clair-kanban.html)

これまでの実装は、build と XCTest(`ClairV2CoreTests` 183 件 0 failure)までしか通っておらず、**GUI の実機操作はほぼ未確認**。
この一覧は「自動テストでは確認できず、人が実機で見る必要があるもの」だけを集めたもの。各項目は `[ ]` を `[x]`(OK)/ `[!]`(NG、メモ)に書き換える。
NG は **canvas を変える**のか **native の bug** なのかを分類して残す(U07 の方針)。

## 0. 準備

- [ ] `make dev` で起動する(daemon + Mac app。`CLAIR_CHANNEL=dev` なので Stable のデータは触らない)
- [ ] 初回起動で Project が開く(seed は起動時の cwd)。別 Project は titlebar の `+` から開く
- [ ] 比較用: モックを `cd prototypes/clair-workbench && npm run dev` → `http://localhost:5173/#/ide` で横に並べる
- [ ] 見た目の差分を残したいとき: `CLAIR_SNAPSHOT=1 swift test --filter ChromeSnapshotTests`(`/tmp/cmp/native.png`。libghostty 含む)
- 既知: `IntegrationTests` の `h04StartsOpenCode…` はこの Mac で hang する(テスト側の問題。本項目の対象外)

## 1. 見た目(U04: モック照合)

比較済みの領域(オフスクリーン描画のみ。実ウィンドウでの確認がまだ):

- [ ] titlebar: Project チップ(色ドット+名前)、file タブ(幅 200・選択中はキャンバス色+下線・未保存ドット・閉じる ×)、`+`、検索欄、コマンド/設定アイコン
- [ ] titlebar: チップのクリックでタブグループが折りたたまれる/戻る(Project は切り替わらない)
- [ ] titlebar: 別 Project のタブを押すと Project が切り替わってからタブが開く
- [ ] サイドバー上部: アイコン列(7 個)が溢れず、選択中が塗りで分かる。bell に未読ドット
- [ ] Explorer: root 行が太字+ブランチ記号、chevron の開閉、M/A バッジの色(A=緑・M=黄)、選択行のハイライト
- [ ] Editor: パンくず、行番号 gutter(現在行が明るい)、One Dark 配色、行高 19px、選択色・キャレット色
- [ ] ステータスバー: ブランチ / `↓0 ↑2` / `N 変更` / `Ln, Col` / `N セッション`(upstream が無い Project では ↑↓ が出ない)
- [ ] pane: focus 枠が無く、非 focus の pane が薄い(0.75)。分割線は 1px
- [ ] agent 空 pane: 起動ボタン 3 つ。押すと下記 §5 のとおり terminal が分割で開く
- [ ] ウィンドウを 900×560 まで縮めても崩れない(タブ列は横スクロール)

**未照合**(モックと並べて差分を洗い出すところから):

- [ ] サイドバー各 panel: 変更一覧 / 検索 / 履歴 / 通知 / session 一覧
- [ ] コマンドパレット(⌘K)/ ファイルへ移動(⌘P)
- [ ] 設定画面(6 セクション。「一般」「モバイル」以外は canvas 未定義 = checklist §6.3)
- [ ] MCP 承認カード
- [ ] コンテキストメニュー(native NSMenu。canvas は独自 overlay なので**意図的に見た目が違う**。許容するか判断)

**既知の未実装(差分として出るのは想定内)**: syntax highlight(grammar 待ち)、quota メーター、editor 上余白 8px、titlebar のチップ色替え/rename/並べ替え、サイドバー strip のアイコン数(モック 4 個 → native 7 個)

## 2. Editor(E07 / U05)

- [ ] ファイルを開く → 編集 → タブとファイルツリーに未保存マーク → ⌘S で保存される
- [ ] 保存後に外部で `cat` して内容が一致する
- [ ] **日本語 IME**: 変換候補ウィンドウの位置、確定、未確定文字の下線、Undo が 1 単位(E07 実機 gate)
- [ ] 選択・複数カーソル・Undo/Redo・クリップボード・ドラッグ&ドロップ
- [ ] 大きいファイル(数 MB)のスクロールが引っかからない。10MB 超は「開けません」表示
- [ ] 非 UTF-8 ファイルは「UTF-8 のテキストではないため開けません」
- [ ] 外部(agent やエディタ)でファイルが変わると、未保存の変更が破棄されて再読込される(仕様: 原則 8)
- [ ] ステータスバーの Ln/Col がカーソルに追従する(日本語・絵文字を含む行でも列がずれない)
- [ ] 検索ヒットをクリック → その行へカーソルとスクロール
- [ ] VoiceOver でエディタが読める(E07 実機 gate)

## 3. 変更確認 / レビュー(U05)

- [ ] 変更一覧(shield): staged / 変更 / 未追跡 の 3 セクション。行の +/− と、見出しの一括 +/−
- [ ] コミットメッセージ欄 + 「コミット」: 空・ステージ無しで無効。成功後に一覧から消え、履歴には残らない
- [ ] コミット失敗時(hook 失敗など)に理由が出る
- [ ] diff pane: +/− 行の色、`+N −M` の行数、hunk 移動(⌥↑↓)、5000 行超の打ち切り、バイナリ表示
- [ ] 行クリック → コメント追加 → 解決。アプリ再起動後も残る(`Application Support/Clair/reviews.json`)
- [ ] **行ドリフト**: コメント後にファイル上部へ行を足す → コメントが追従する。その行を書き換える → 「位置を特定できません」で上部に別表示
- [ ] **suggestion**: 「提案にする」→ 1 行置換 → 適用でバッファに反映・未保存になる → ⌘Z で 1 回で戻る / 却下 / バッファ編集後は適用不可
- [ ] 「agent に送る」: プロンプトがクリップボードに入り、実行中 agent の pane に focus(貼り付けは自分で。自動送信されないこと)
- [ ] Explorer / タブの「Agent に送る ›」: 実行中 agent の terminal に `@path ` が入る(Return は押されない)

## 4. コンテキストメニュー(U05)

- [ ] ファイルタブ / Explorer ファイル / Explorer フォルダ / editor pane / terminal pane の各メニューが出る
- [ ] **terminal pane で右クリックが libghostty に奪われないか**(奪われると出ない。実機未確認)
- [ ] 「Finder で表示」「パスをコピー」が実際に動く
- [ ] 実行できない項目が消えずに disabled で残る

## 5. Terminal / Agent(T03 / T06 / U06 / V07)

- [ ] shell が起動し、入力・出力・色・カーソルが正しい
- [ ] **CJK / IME**: 日本語入力と確定、ワイド文字の桁ずれなし
- [ ] paste guard(ESC を含む・複数行の貼り付けが確認される)、bracketed paste
- [ ] mouse reporting(vim / tmux でクリック・スクロール)、focus in/out
- [ ] リサイズ(pane ドラッグ・ウィンドウ)で行列が追従し、TUI が崩れない
- [ ] alternate screen(vim / less / htop)から戻って画面が壊れない
- [ ] flood(`yes` や巨大 `cat`)で UI が固まらない(U06: overlay が描画性能を悪化させない。**計測は未着手**)
- [ ] agent 起動(Claude Code / Codex / OpenCode): 空 pane のボタン → terminal が分割で開き、cwd が Project root(確認ダイアログが出る想定)
- [ ] agent 終了後も pane が残り、exit code が分かる
- [ ] session 一覧: 実行中 / ベル(入力待ち)/ 終了の区別、クリックで Project 切替+pane focus
- [ ] ステータスバーの「入力待ち」表示が bell に応じて出る
- [ ] pane 分割 / 最大化 / 均等化 / 閉じる(未保存 buffer がある pane は破棄確認)

## 6. 通知(V08)

- [ ] bell / 終了で通知履歴(bell アイコン)に積まれる。既読・消去
- [ ] titlebar の Project チップに未読バッジ。Project を開くと既読
- [ ] macOS banner: **非 frontmost かつ未ミュート**のときだけ出る(app bundle 外では出ない仕様。実機表示は未確認)
- [ ] Project ミュート(チップ右クリック)/ terminal ミュート
- [ ] banner に terminal の内容や secret が出ていない(固定文言のみ)

## 7. Project / 永続化(V04)

- [ ] 複数 Project を開いて切り替え。Project ごとに tab / pane / 折りたたみが保持される
- [ ] アプリ再起動で layout・tab が復元される(agent terminal は自動再 spawn **されない**のが正)
- [ ] 設定の「レイアウトを復元」off で復元されない
- [ ] Project の root を消す / tab のファイルを消す / `workspace.json` を壊す → 安全に縮退して起動できる
- [ ] Git 管理外のフォルダでも開ける(Git 系コマンドが出ない)

## 8. 検索 / 置換 / 履歴(V05)

- [ ] 検索(リテラル / 正規表現 / 大文字小文字)、件数・ファイル数表示、0 件メッセージ
- [ ] 一括置換 → 履歴に退避される → 履歴 panel(時計アイコン)で差分プレビュー → 復元
- [ ] 保存前に自動退避され、復元すると復元前の内容も履歴に残る
- [ ] 外部のファイル追加/削除でツリーが更新される(FSEvents)
- [ ] **⇧⌘F ショートカットで検索に入れるか**(titlebar の検索欄は現状サイドバーの検索 panel を開く。未配線の可能性あり)

## 9. Git / worktree(V06)

- [ ] stage / unstage / commit / branch 切替 / branch 削除(未マージは拒否、確認あり)
- [ ] `worktree.create` → 別 Project として開く → agent の cwd が worktree
- [ ] `worktree.adopt`(未コミットがあると拒否 / マージ / 衝突時は abort されて理由が出る)
- [ ] `worktree.remove`(dirty だと拒否、branch は残る)
- [ ] 大きいリポジトリで GUI が固まらない(git は main thread 同期実行。ceiling)

## 10. CLI / MCP(V02 / V03)

- [ ] `clair open path:line` 、`clair pane.splitRight` などが GUI に反映される。GUI 不在で exit 3
- [ ] `clair <destructive>` が確認なしで実行されず、GUI の確認ダイアログが出る
- [ ] `clair mcp serve` を実 MCP クライアント(Claude Code 等)につなぐ: tools/list は `aiAvailable` のみ
- [ ] write 以上の呼び出しで **window 内の承認カード**が出る(内容・リスク・残り秒・⌘↩ 許可 / esc 拒否)
- [ ] 60 秒無応答が「拒否」になる。`aiAvailable: false` の command は呼べない
- [ ] **D5 独立レビュー(人手 gate)**: `clair-v2-v03-mcp.md` の threat model を読んで判断

## 11. Channel / 更新 / 常駐(V09)

- [ ] Dev と Stable で bundle ID・data dir・socket が分かれている(`Clair Dev v2` / `Clair v2`)
- [ ] 更新の手動 check / 自動 check、署名検証、適用 → 再起動 → 起動成功 marker、失敗時 rollback
- [ ] **`.app` としての実適用**(swift run では確認できない。未達)
- [ ] **更新再起動後の PTY reattach**(実行中 terminal が切れずに戻る。未達)
- [ ] window を閉じても daemon が継続し、明示終了で止まる
- [ ] agent 実行中の電源接続時に idle sleep が抑止される(battery 時は設定に従う)
- [ ] **D5 独立レビュー(人手 gate)**

## 12. ゲート(人手で判定するもの)

- [ ] **U04**: モックとの最終照合(本一覧 §1 の未照合領域を含む)
- [ ] **T07**: OpenCode TUI / shell / resize / alt screen / flood / sleep-wake / network switch / Mac-mobile 同時入力 / reattach / OSC 52・633
- [ ] **V10**: Stable から Clair source を開き、terminal/agent で Dev を build・起動して変更を確認できる。ccedit より快適か(本人判断)
- [ ] **N08**(iPhone/iPad): Mac 側 pairing 面の実装後に判定。現状 blocked(N09 実装済みだが dogfood 未検証)
- [ ] iOS 実機: editor IME / VoiceOver(E08)、terminal(T05)。APNs は Developer 会員登録 + key 待ち

## 13. 記録

- 結果は各項目に `[x]` / `[!]` で残し、NG は「canvas 変更 or native bug」を 1 行添える
- 全項目が終わったら kanban の該当カード(U04/U05/U06/V03/V06/V09)を更新する
