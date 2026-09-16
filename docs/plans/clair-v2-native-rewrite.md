# Clair v2: Native Rewrite Plan

Status: accepted execution plan
Date: 2026-09-13

Detailed execution order: [Clair v2 native rewrite task queue](clair-v2-native-rewrite-queue.md)

Mobile platform decision: [ADR-0015: Native iPhone/iPad clientとAPNsを製品経路に採用する](../decisions/0015-native-mobile-apns.md)。

## 1. Decision

Clair v2 は、現在の Clair を段階的に延命するのではなく、編集・ターミナル・AI レビューの基盤を含めて作り直す。

これは旧実装を隠しながら動かし続ける計画ではない。v2 の製品ランタイムには、次の旧経路を残さない。

- CodeMirror / `WKWebView` を使ったエディタ
- CodeEditSourceEditor を中核にしたエディタ
- `libvterm` を使ったターミナル描画
- 旧 Swift/Rust ブリッジを前提にした編集・表示経路
- 旧 UI と v2 UI の機能フォールバック

既存コードは、仕様・テストケース・失敗事例・計測値を回収するための資料として扱う。旧実装の退避はファイルコピーではなく、Git のスナップショット、タグ、履歴で行う。v2 への切り替え後に旧ソースをリポジトリ内へ残す必要はない。

## 2. Product target

Clair は、Mac とモバイルから同じ開発セッションを操作できる、AI レビュー中心のネイティブ開発環境にする。

優先順位は次の通り。

1. 大きなコードを軽快かつ正確に編集できること
2. AI へのレビュー依頼と変更適用を、行単位の文脈付き操作として扱えること
3. Mac のローカル開発環境を、モバイルから安全に観察・操作できること
4. ターミナル、ワークスペース、Git、LSP を一つの変更モデルで接続すること

目標は VS Code の全拡張エコシステムを再現することではない。エディタの基本品質は VS Code 相当まで引き上げ、Clair 固有の AI レビュー体験を上に積む。

### Platform decision

Clair の製品クライアントは PWA ではなく、Apple のネイティブアプリとして作る。

- macOS: SwiftUI のアプリシェル、AppKit のエディタと Ghostty surface
- iOS / iPadOS: SwiftUI を中心にしたネイティブ companion app
- 通知: APNs と UserNotifications を使う
- App lifecycle: scene phase、background task、silent push、接続復旧をネイティブの制約に合わせて設計する
- Apple Developer の bundle ID、capability、signing、push entitlement、TestFlight 配布を Phase 0 から管理対象にする

Web UI は開発用の検証・診断に限定し、製品の操作面、通知経路、認証面には使わない。

## 3. Architecture

```text
ClairApp
├── ClairEditorCore       text, selections, transactions, undo, search
├── ClairEditorView       AppKit native viewport and CoreText renderer
├── ClairReviewCore       review anchors, threads, suggestions, revisions
├── ClairTerminal         GhosttyKit/libghostty surface and session bridge
├── ClairAgent            OpenCode session, tool events, patch application
├── ClairWorkspace        files, tabs, splits, worktrees, Git, LSP
├── ClairDaemon           long-lived Mac session and mobile transport
├── ClairPushRelay        minimal APNs provider boundary
└── ClairMobile           SwiftUI client for iOS/iPadOS
```

SwiftUI はシェル、ナビゲーション、インスペクタ、レビュー UI、モバイル UI に使う。大量のテキスト描画と入力のホットパスは AppKit の `NSView` と Swift の専用コアで実装する。

## 4. Native editor

### 4.1 Text model

`ClairEditorCore` は UI フレームワークから独立させる。現在の `TextBuffer` は、設計を再確認したうえで基礎部品として再利用してよいが、UI の状態や SwiftUI の再描画と結合させない。

必須の責務:

- piece table または rope による部分更新
- UTF-8 / UTF-16 / extended grapheme cluster 間の座標変換
- 行インデックスと行 ID
- immutable revision と transaction ID
- 複数選択範囲・矩形選択・マルチカーソル
- 一つの transaction としての編集、Undo/Redo、外部変更の取り込み
- 検索、置換、正規表現、選択範囲への適用
- Tree-sitter の増分構文解析との同期
- LSP の UTF-16 range との変換

ドキュメント全体の String を、入力や描画のたびに SwiftUI へ渡さない。保存、解析、AI 連携などの境界で必要な場合だけスナップショットを生成する。

### 4.2 Rendering and input

`ClairEditorView` は行ごとの SwiftUI View を作らず、可視 viewport の行だけを CoreText で描画する。

- 可視行の glyph/run をキャッシュする
- 変更された行とその周辺だけを再レイアウトする
- 高速スクロール時は表示用キャッシュを優先し、全ファイルを eager layout しない
- caret、selection、composition、diagnostic、review marker を同じ座標系で描画する
- `NSTextInputClient` を実装し、日本語 IME、marked text、確定、delete を正しく扱う
- AppKit の accessibility、copy/paste、undo、system text cursor の契約を守る

TextKit 2 は、標準挙動やアクセシビリティを使える箇所では補助的に利用してよい。ただし、エディタ全体を `NSTextView` の eager layout や一行一 View の構成に依存させない。

### 4.3 Editing quality gate

次を満たすまで AI 機能を完成扱いにしない。

- 日本語 IME の実機操作
- 絵文字、結合文字、CRLF、巨大な単一行
- マルチカーソルの入力、削除、貼り付け、Undo/Redo
- 複数選択を含む検索・置換
- 外部変更、file watcher、agent による同時編集
- 10MB 級ファイルの初期表示、スクロール、編集
- layout / input / transaction の計測と回帰テスト

## 5. AI review as a first-class model

AI レビューのコメントは、単なる行番号や画面上の吹き出しとして保存しない。

アンカーは最低限、次を持つ。

- file identity
- document revision
- UTF-16 range
- start/end の line ID
- 周辺テキストの hash
- コメント本文、author、thread、status

status は `attached`、`stale`、`orphaned`、`resolved` を持つ。編集で行番号がずれても、line ID と周辺 hash で再配置を試み、確信が持てない場合は勝手に移動せず stale として表示する。

AI からの変更提案は、テキスト差分ではなく editor transaction に変換する。

- Apply: transaction として適用
- Reject: 提案を破棄
- Partial apply: 選択した hunk だけ適用
- Undo: 通常の編集と同じ Undo stack に入れる
- Apply 後に関連レビューを自動で再評価し、解決・stale を更新する

最初の provider は OpenCode とする。provider 固有のイベント形式は `ClairAgent` の内部 adapter に閉じ込め、レビュー・編集・セッションのモデルは provider 非依存にする。

## 6. Terminal and session

ターミナルの表示とセッション所有権を分離する。

- `libghostty` / GhosttyKit は terminal emulation、font、GPU rendering、入力表示を担当
- PTY、process、resize、session persistence は Clair 側が担当
- surface はセッションへ attach/detach できる
- Mac とモバイルは、同じセッションの別 surface になる
- 端末の raw replay は alternate screen、サイズ、scrollback を考慮して実装する

Muxy、Termini、termio、Crispy の構成を参照する。ただし、Muxy の LAN trust をそのまま採用しない。ペアリングは一回限りの承認、端末鍵、challenge、権限 scope、明示的な revoke を持つ。通信は private route を前提にし、平文 WebSocket を製品の既定にしない。

## 7. Workspace and native mobile app

Mac 側の `ClairDaemon` が、長寿命の workspace / worktree / terminal / agent session を所有する。モバイルは薄い操作クライアントとして次を行う。

- workspace、tab、split、worktree の閲覧
- ファイルの段階的な読み込み
- terminal の attach と入力
- agent session の開始、停止、承認
- review thread の閲覧、コメント、提案の apply/reject
- pairing、device scope、revoke の管理
- agent の承認要求、レビュー完了、セッション異常を APNs 通知で受け取る
- 通知タップから対象 workspace、review thread、terminal session へ deep link する
- アプリが foreground / background / terminated のどの状態でも、再接続時に revision を検証する

通信プロトコルには revision、request ID、capability、idempotency を含め、古いクライアントからの更新で新しい編集を壊さない。

通知 payload には機密のコード内容を含めない。通知は opaque resource ID とイベント種別だけを持ち、詳細は認証済み接続で取得する。device token、通知権限、登録解除、環境（development / production）は `ClairDaemon` と `ClairPushRelay` の device registry で管理する。

モバイルへのリモート通知は、Mac の `ClairDaemon` がイベントを `ClairPushRelay` に渡し、relay が APNs provider として送信する。Apple Developer の APNs 認証情報を Mac アプリへ埋め込まない。relay は通知の配送だけを担当し、コード内容、agent の秘密、プロジェクト全体を保持しない。APNs は best-effort なので、通知を状態の正本にせず、アプリの起動・復帰時に認証済みの `ClairDaemon` から revision を取得する。

## 8. Execution phases

### Phase 0: Freeze the current state and write the contract

- 現在の未コミット変更を確認し、v1 作業として checkpoint を作る
- この plan と、v2 が捨てる経路の一覧を確定する
- 現在のテスト、fixture、失敗事例、計測値を v2 の回帰資産へ抽出する
- v2 の新しい target / module / build boundary を作る

Exit criteria: 現在状態を Git から復元でき、v2 の責務境界がコード上に存在する。

### Phase 1: Mac server and OpenCode control plane

- GUI から独立した `ClairDaemon`、project/worktree/session catalog、secure transport を実装
- one-time pairing、device identity、scope、revoke、operation replay protection を実装
- OpenCode adapter、streaming event、prompt、approval、interrupt、Git diff を実装
- session journal、gap/resync、crash recovery、resource bounds を実装

Exit criteria: fixture client が Mac GUI なしで OpenCode session を安全に操作できる。

### Phase 2: Native iPhone / iPad companion

- iOS / iPadOS の SwiftUI ネイティブ target と共有 Swift package 境界
- Apple Developer の bundle ID、signing、push entitlement、TestFlight 検証
- secure pairing と device management
- project/worktree/session 選択、OpenCode conversation、agent approval、diff review
- offline read cache と reconnect conflict handling
- APNs device token 登録、通知カテゴリ、deep link、background refresh
- 最小 `ClairPushRelay`、APNs provider 認証、device registry、通知イベントの TTL
- foreground / background / terminated 各 lifecycle の接続復旧

Exit criteria: iPhone / iPad だけを操作して Clair repository で OpenCode に開発を依頼し、承認、diff確認、follow-up、完了通知からの復帰まで行える。

### Phase 3: Clair-owned native editor

- buffer、line index、coordinates、revision、transaction、multi-cursor、undo を実装
- custom AppKit / UIKit viewport、CoreText の可視行描画、IME、accessibility を実装
- Tree-sitter、LSP、search/replace、review anchor、AI suggestion transaction を統合
- large file / long line / Unicode / IME の性能・正確性 gate を通す

Exit criteria: WebView/CodeEdit なしで Mac と mobile のコード編集・AI review が完結する。

### Phase 4: libghostty terminal

- GhosttyKit/libghostty の reproducible Swift integration
- daemon-owned PTY/session、attach/detach、resize、scrollback、gap/resync
- macOS/iOS surface、IME、selection、paste、alternate screen、backpressure
- OpenCode TUI、sleep/wake、network switch、同時入力の実機 gate

Exit criteria: libvterm へ戻らず、Mac と mobile が同じ terminal session を安全に操作できる。

G1 の実際の raw agent session を検証するため、Phase 4 のうち daemon-owned PTY/process/session backend と raw I/O bridge は Phase 2 の dogfood gate より前に先行してよい。Ghostty の rendering surface、mobile terminal UI、full terminal integration は G1 後の Phase 4 scope とする。

**Sequencing update (2026-09-15)**: `N08`（G1 の実機 dogfood gate）は、モバイル側の実装ではなく Mac 側にペアリングを開始する操作面（QR 表示等の GUI/CLI）が一つも存在しないという、計画時点で想定していなかった gap で `blocked` になった。iPhone/iPad 側の foundation shell は Simulator 実機確認済みで、G1 自体が Phase 3/4 の技術的前提には当たらないと判断し、release owner の指示で Phase 3 (editor) と Phase 4 (terminal) の POC 実装を G1 の完了を待たずに並行して優先度を上げる。Mac を「PC 側の本物の画面」として積極的に作り込む方針に転換し、G1 の残課題（Mac 側ペアリング bootstrap 面）は本転換後にあらためて優先度を判断する。`T02` の先行と同じ理由で、`E01`/`T01` の技術的前提はどちらも `N08` ではなく既存の package/build graph（`B01`）で足りるため、`N08` を必須先行条件から外す。

**Sequencing update (2026-09-16)**: `N09` は `N08` の gap（Mac 側ペアリング bootstrap 面の欠如）解消を狙って実装済みだが、`N08` 自体の実機 dogfood acceptance はまだ検証していない。それとは別に、release owner の判断で当面の目標の重心を動かす。「モバイルから Mac を安全に確認・操作できること」を確認する前に、「Mac 上で editor / terminal を実際の開発に使える精度に仕上げ、Design canvas / Workbench 準拠の見た目・操作に揃えること」を優先する。Phase 5 (Mock-faithful UI) のうち Mac 向けの範囲（AppShell chrome、editor/diff/review UI、terminal/session UI）は、Phase 3/4 の Mac 側実装（native editor rendering、macOS Ghostty surface）が揃い次第着手し、Phase 3/4 の iOS 側実装（iOS editor surface、iOS terminal surface）や G1 dogfood の完了を前提にしない。iOS 側の mock-faithful UI は、iOS 側の editor/terminal 実装と `N08` が揃ってから追い上げる。Definition of done（section 10）の対象範囲は変えない。

### Phase 5: Mock-faithful UI

- Clair UI Design canvas と Workbench mock を UI contract として freeze
- tokens、native controls、Mac/iPhone/iPad navigation と workspace chrome を実装
- editor、terminal、diff、review、agent activity を mock の見た目と操作へ一致させる
- screenshot/interaction regression、VoiceOver、keyboard、reduced motion を検証
- 仮 UI と旧 runtime/assets/dependencies を削除

Mac 向け UI（AppShell chrome、editor/diff/review UI、terminal/session UI）は、上記 2026-09-16 sequencing update により Phase 3/4 の Mac 側実装が揃い次第、iOS 側の完了や G1 を待たずに着手する。iOS 向け UI は iOS 側の editor/terminal 実装が揃ってから着手する。

Exit criteria: Design canvas / Workbench との差分が解消され、v2 native UI だけが製品経路として残る。

## 9. Migration procedure

ファイルの退避と v2 の着手は、次の順番で行う。

1. 現在の dirty worktree を確認する。内容が混ざっている場合は、先に作業単位を分ける。
2. 現在状態を checkpoint commit として保存する。これは v1 の最後の状態を復元するためのもので、公開や push は別判断とする。
3. checkpoint に archive tag を付ける。必要なら Git bundle も作る。
4. v2 用のブランチを checkpoint から作る。
5. 新しい module / target を先にビルドできる状態にする。
6. v2 の機能が置き換わった順に旧 runtime 経路と不要な依存を削除する。
7. 旧ファイルを別ディレクトリへコピーして二重管理しない。復元は archive tag から行う。

Phase 0 の間は、ユーザーの未コミット変更を勝手に stage、commit、削除、移動しない。checkpoint の対象が確定してから、コミットを作る。

## 10. Definition of done

Clair v2 の最初の製品版は、次を満たす。

- エディタ経路に WebView がない
- 10MB 級ファイルで全行 eager layout を行わない
- 日本語 IME と Unicode を含む編集が正しい
- マルチカーソル、検索/置換、Undo/Redo が一貫している
- AI review の anchor が revision-aware で、提案を安全に適用できる
- terminal は GhosttyKit/libghostty を使い、PTY/session と描画が分離している
- Mac とモバイルが secure pairing と明示的な権限で同じ session を操作できる
- モバイルは PWA ではなく署名済みの iOS/iPadOS ネイティブアプリである
- APNs 通知から workspace / review / agent の対象画面へ遷移できる
- 旧 CodeMirror、CodeEdit、libvterm、旧 bridge に戻る runtime fallback がない
- 性能・メモリ・IME・レビュー適用の回帰テストがある

## 11. Reference implementations

参照は実装のコピーではなく、境界と失敗事例を学ぶために行う。

- Muxy: session daemon、surface attach、worktree/session metadata、mobile control
- Termini / termio: libghostty の Swift surface と in-memory PTY ownership
- Crispy: SwiftUI/AppKit native IDE の feature/service 境界、GhosttyKit、agent workspace
- CodeEdit / CodeEditSourceEditor: Swift native editor API の候補と限界
- Runestone: Tree-sitter と iOS editor surface の実装例
- CotEditor: mature macOS document、encoding、IME、accessibility の実装知見

採用可否は、ライセンス、長文・大規模ファイルの挙動、IME、Undo、メンテナンス状況を確認して個別に決める。
