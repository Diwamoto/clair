# Design

## Current state

| 対象 | 現在の実装 | 問題 |
|---|---|---|
| editor（本番） | [CodeMirrorEditor.swift](../../../apple/ClairApp/CodeMirrorEditor.swift) + WKWebView + [editor-web](../../../editor-web) | cceditと同一engine。bridge往復が一段増える。常駐processとメモリ |
| editor（Dev opt-in） | `NativeEditor.swift`の`ProjectSourceEditorView` | `NSTextView`と正規表現ハイライト。文書全体layout |
| terminal | [TerminalSurface.swift](../../../apple/ClairApp/TerminalSurface.swift) | `draw(_:)`が`dirtyRect`を無視し、scrollback 4,000行×全列を毎回走査 |
| 文書契約 | [ProjectEditorDocument.swift](../../../apple/ClairApp/ProjectEditorDocument.swift) | engine非依存で完成済み。**再実装しない** |
| anchor / diff / suggestion | [anchor](../../../apple/ClairApp/ProjectEditorCommentAnchor.swift)、[diff](../../../apple/ClairApp/ProjectEditorDiffModel.swift)、[suggestion](../../../apple/ClairApp/ProjectEditorSuggestion.swift) | engine非依存で完成済み。**再実装しない** |

engine自作の前提となる文書層はすでに存在する。本projectが作るのは、その下のstorageと、上のviewである。

## Proposed design

`ClairTextKit`をapp target内の独立moduleとして追加し、editorとterminalが同じsurfaceを共有する。

```text
ClairTextKit
├─ Font        TextFontMetrics      font metrics、glyph atlas、run cache、fallback解決
├─ Render      TextSurfaceRenderer  damageに基づくCoreText run描画、theme色
├─ Geometry    TextSurfaceGeometry  position↔point、選択矩形、scroll、hit test
├─ Input       TextInputSurface     NSView + NSTextInputClient + NSAccessibility
└─ Model                            ここから下が分岐する
   ├─ Editor   TextBuffer           piece table + line index + wrap + folding
   │           SyntaxHighlighter    Tree-sitter増分解析、revision gate
   └─ Terminal TerminalGridSource   libvterm gridのadapter、damage、scrollback
```

上の4層は両surfaceで共有し、`Model`だけが分岐する。共有層はmodelの実体を知らず、
`TextSurfaceSource` protocolを通じて「可視行の内容と属性」を受け取る。

### monospace fast path

行が単一幅ASCIIだけで構成される場合、桁から座標を算術で求め、事前計算したglyph tableでrunを直接描く。
CJK、絵文字、結合文字、合字、RTLを含む行だけCoreTextの整形へ落とし、結果を行単位でcacheする。
これはterminalが速い理由そのものであり、editorにも同じ経路を使う。

### 可視範囲限定layout

`TextBuffer`は行頭offsetの索引だけを常時保持し、layoutは可視範囲とその近傍にのみ構築する。
`NSLayoutManager`とCodeMirrorが大規模fileで詰まるのは文書全体のlayoutを持とうとするためで、
この構成にすると文書サイズはlayout性能へほぼ効かなくなる。索引は編集時に増分更新する。

## Components and responsibilities

| Component | Responsibility | Changed interface |
|---|---|---|
| `TextFontMetrics` | font metrics、glyph atlas、run cache、CJK/emoji fallback | 新規 |
| `TextSurfaceRenderer` | damage矩形の再描画、theme適用 | 新規 |
| `TextSurfaceGeometry` | position↔point、選択矩形、hit test、scroll | 新規 |
| `TextInputSurface` | `NSView`、`NSTextInputClient`、`NSAccessibility`、key/pointer | 新規 |
| `TextSurfaceSource` | 可視行の内容と属性を供給するprotocol | 新規 |
| `TextBuffer` | piece table、line index、wrap、folding | 新規 |
| `SyntaxHighlighter` | Tree-sitter増分解析、revision gate、行単位span | 新規 |
| `TerminalGridSource` | libvterm gridのadapter、damage、scrollback | `TerminalSurface.swift`を置換 |
| `ProjectEditorTab` | 文書所有、保存、外部変更、履歴 | 内部storageを`TextBuffer`へ差し替え。公開契約は不変 |
| `ProjectEditorDocumentModel` | revision付きtransaction契約 | **変更しない** |

## Data and control flow

### 座標系

engineが扱う座標系は5つある。**この対応表を破ると全域にバグが出る。**

| 座標系 | 用途 | 所有者 |
|---|---|---|
| UTF-8 byte offset | 内部storage、Tree-sitterのinput | `TextBuffer` |
| UTF-16 offset | `ProjectEditorDocumentModel`契約、`NSTextInputClient`、`NSRange`、accessibility | engineの公開API |
| grapheme cluster | caret移動、文字単位の削除と選択 | `TextBuffer`の境界API |
| line / column | gutter、LSP/DAP、`clair open path:line:column`、git diff | `TextBuffer`のline index |
| visual row / x | 描画、hit test、wrap後の位置 | `TextSurfaceGeometry` |

規則は次のとおりとする。

1. storageはUTF-8 byte、engineの公開APIはUTF-16とする。既存の文書契約とAppKitがUTF-16のためである。
2. 変換は境界2か所でだけ行う。`TextBuffer`↔Tree-sitterはbyte、`TextInputSurface`↔AppKitはUTF-16。
3. caret移動と文字単位の削除はgrapheme境界APIを必ず経由する。UTF-16 offsetの加減算でcaretを動かさない。
4. `TextBuffer`の外側でbyte offsetとUTF-16 offsetが等しいと仮定しない。

### threading

- main actorが所有するのは、view、入力、描画submission、`TextBuffer`の変更適用である。
- Tree-sitterの解析、file IO、全文検索はmain thread外で行う。
- 解析結果はrevisionでgateし、古いrevisionの結果を適用しない。NE-04と同じ規律を引き継ぐ。
- main threadで解析完了を待たない。ハイライト未了の行は無色で描き、後から差し替える。

### damage

`TextSurfaceSource`は変更範囲を`invalidate(rows:)`で通知し、rendererはdirty矩形だけを再描画する。
文書全体やgrid全体の再描画経路を作らない。これは現行terminalの主要な欠陥への直接の対処である。

## Interfaces and contracts

- `ProjectEditorDocumentModel`のtransaction契約、revision、UTF-16レンジ、検証順序は本projectで変更しない。
  engineはその実装先を差し替えるだけとする。
- `ProjectEditorCommentAnchor`、`ProjectEditorDiffModel`、`ProjectEditorSuggestion`のmodelは再実装せず、
  描画とinteractionだけをengine側へ実装する。
- `SessionBrokerFrame`、`clair-ptyhost`、broker protocolは変更しない。terminalはgridの描画層だけを置き換える。
- Command Registryのstable command ID、typed parameter/result/error、`aiAvailable`、static riskは維持する。
- `ClairTextKit`はClairのProject/workspace型へ依存しない。依存方向はapp → ClairTextKitの一方向に限る。

## State, persistence, and migration

保存形式は変更しない。tab状態（選択、scroll位置、folding）はengine固有表現を直接保存せず、
既存のworkspace snapshotが持つUTF-16 offsetとline/columnへ射影して保存する。
CodeMirror既定からengine既定への切替は`clair.editor.native-v1`で行い、切り戻しを常に可能にする。

## Failure handling and recovery

- glyph atlasの確保失敗、font fallback不在は、代替glyphで描画を継続し、無描画にしない。
- Tree-sitterの解析失敗、grammar不在は、ハイライトなしで編集を継続する。編集経路を止めない。
- `TextBuffer`の不変条件違反は、部分適用ではなくtransaction全体を拒否する。既存の文書契約と同じ規律とする。
- terminal gridのdamage欠落を検知した場合は、当該viewportを全再描画してから通常経路へ戻す。
- IME composition中にtabやProjectが切り替わった場合は、compositionを確定せず破棄し、文書を変更しない。

## Security and privacy

untrusted inputはterminal出力とfile内容である。どちらも描画対象であり実行しない。
制御sequenceは既存のsanitizerとlibvtermの解釈に委ね、engineは描画だけを行う。
terminal transcriptをsession終了後に保存しない方針は変更しない。secretとcredentialは扱わない。

## Observability

- Dev buildのみのdiagnostic overlayで、可視行数、layout cache件数、直近frameのdamage矩形数、
  解析中revisionを表示する。Stableでは無効にする。
- 計測は`P34`のgateで行い、通常itemはfunctional checkと必要最小限のslice計測に留める。

## Test strategy

| 層 | 責務 |
|---|---|
| unit | `TextBuffer`の編集と索引、座標変換、grapheme境界、wrap計算、damage算出、revision gate |
| integration | 文書契約との接続、anchorのwrap/folding追従、diffとsuggestionの適用、broker reattach |
| manual | 実機の日本語IME一式、VoiceOver、agent TUI、flood、大規模fixture |
| performance | `P34`のgateのみ。基準値は`P17`で取得した現行既定とする |

IMEとVoiceOverはunit testで完了を判定しない。手順は
[local development runbook](../../runbooks/clair-v2-verification.md)へ追記し、実施結果をitemへ記録する。

## Options considered

### Option A: editorとterminalで別々のsurfaceを実装する

- Advantages: 各surfaceを独立に最適化でき、片方の変更が他方へ波及しない。
- Disadvantages: IME、選択、theme、scrollの実装が二重化し、挙動が割れる。共有による優位を失う。
- Evidence: 現状がまさにこれで、editorとterminalでIMEの扱いが別物になっている。

### Option B: 共有surfaceにmodelだけを差し替える

- Advantages: 入力とaccessibilityという最も難しい層を一度だけ正しく作れば両方へ効く。
- Disadvantages: 共有層の抽象がterminalとeditorの双方に適合する必要があり、初期設計の難度が上がる。
- Evidence: 両surfaceの要求はmonospace grid描画、選択、IMEでほぼ一致し、分岐はlayoutとmodelに閉じる。

## Decision and rationale

Option Bを採用する。長期の保守費用を決めるのは入力とaccessibilityの正しさであり、これを二度実装しないことが
最大の節約になる。共有層の抽象は`TextSurfaceSource`一枚に閉じるため、想定される設計難度は許容範囲である。
背景の判断は[ADR-0014](../../decisions/0014-clair-owned-text-engine.md)に記録した。

## Risks and mitigations

| Risk | Impact | Mitigation or exit condition |
|---|---|---|
| 日本語IMEの要件を満たせない | project全体が成立しない | `P19`を早期の独立itemにし、最小probeで先に潰す。二度の実装反復で通らなければADR-0014のrevisit条件によりOption Cへ退避 |
| 共有抽象がterminalに合わない | 共有の前提が崩れる | `P30`をfoundation直後に置き、editor側の機能を積む前に適合性を検証する |
| Tree-sitter grammarの配布許諾 | 言語対応が縮む | `P23`のscope内で許諾を確認し、確保できた言語だけ同梱する。未解決の言語はplain textへfallbackする |
| accessibilityの後回し | 恒久的に壊れる | `P21`を既定切替`P29`のdependencyにする |
| CoreTextで描画性能が足りない | 目標未達 | `P34`で判定し、必要ならglyph atlasのMetal化を後続itemとして起票する |
| 二経路の保守期間が延びる | 開発速度の低下 | CodeMirrorはfallbackとして凍結し、新機能をそちらへ足さない |

## Rollout and rollback

`clair.editor.native-v1`のopt-inをそのまま利用し、Devでengineを既定にして実利用で検証した後、
`P29`でStableの既定を切り替える。CodeMirror経路は削除せず残し、設定で即座に切り戻せる状態を維持する。
terminalは`P32`で切り替え、現行surfaceは同一commit内で置換する。broker経路は変更しないため、
切り戻しはrevertで足りる。

## Documentation impact

- [development workspace architecture](../../architecture/development-workspace.md)にengineの境界とthreading契約を追記する。
- [local development runbook](../../runbooks/clair-v2-verification.md)にIMEとVoiceOverの手動確認手順を追記する。
- native editor issues(2026-09-21 に削除、Git 履歴を参照)のNE-11とNE-15〜NE-23へsupersede注記を入れる。
- 言語資産を同梱する際は`THIRD_PARTY_NOTICES.md`を更新する。

## Open questions

None.
