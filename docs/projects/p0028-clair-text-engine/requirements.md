# Requirements

## Motivation

Clairの利用者は、VS CodeのeditorとGhosttyのterminalを別アプリで行き来する代わりに、ひとつのProject workspaceで
同等以上の操作感を得たい。現在のClairはeditorがWKWebView上のCodeMirror 6、terminalが全セル個別描画の
`NSTextView`派生viewであり、どちらも体感でcceditを超える構成になっていない。editorだけならVS Code、terminalだけなら
Ghosttyで足りるため、両方が借り物である限りClairの存在理由が成立しない。判断の根拠は
[ADR-0014](../../decisions/0014-clair-owned-text-engine.md)にある。

## Goals

- editorとterminalが同一のClair所有surface engineを共有する。
- 大規模fileと長行でlayoutが破綻せず、file sizeがlayout性能へほぼ効かない。
- 日本語IMEの変換、確定、取消、再変換が実機で正しく動く。
- diff、merge、AI提案、行コメントをsurfaceの一級市民として描く。
- WKWebViewとCodeMirrorをhot pathから外す。

## Non-goals

- 汎用のtext framework、rich text、word processor機能。
- VS Code extension互換、CodeMirror互換API。
- iOS/iPadOS surfaceへの移植。mobileは引き続きraw terminal controlに限定する。
- language intelligence（LSP）とdebugger（DAP）の実装。engineはそれらの描画先を用意するだけとする。
- terminalのGPU renderer。CoreTextで要件を満たせない実測が出るまで着手しない。

## User-visible behavior

- 10MBのsource fileを開いてもUIが固まらず、scrollとcaret移動が滑らかである。
- Claude Code、Codex、OpenCodeのTUIが正しく描画され、出力floodでも入力を取りこぼさない。
- editorとterminalでIME、選択、theme、scrollの挙動が一致する。
- diffとmerge、AI提案、行コメントが同じsurface上で操作できる。
- VoiceOverでeditorの行、選択、caret位置が読み上げられる。

## Requirements

### Functional

- `FR-01`: surfaceはmonospaceのASCII行を整形なしで描画し、CJK、絵文字、結合文字、合字を含む行だけCoreTextで整形する。
- `FR-02`: layoutは可視範囲とその近傍だけを構築し、文書全体のlayoutを保持しない。
- `FR-03`: `NSTextInputClient`を完全に実装し、marked text、候補window位置、再変換、取消を扱う。
- `FR-04`: 選択、複数caret、語・行・段落選択、CJKの語境界、drag選択とautoscrollを扱う。
- `FR-05`: `NSAccessibility`のtext protocolへ対応し、VoiceOverで行、選択、caret位置を取得できる。
- `FR-06`: editor modelはpiece tableとline indexを持ち、既存の`ProjectEditorDocumentModel`のtransaction契約へ接続する。
- `FR-07`: syntax highlightはTree-sitterの増分解析をmain thread外で行い、revisionで結果をgateする。
- `FR-08`: 複数caretの編集が一回のUndoで復元できる。
- `FR-09`: gutterにline number、git状態、breakpoint、コメントanchorのrailを描画する。
- `FR-10`: soft wrapとfoldingを扱い、その状態でもanchorとrailの位置が正しい。
- `FR-11`: 既存の`ProjectEditorDiffModel`を使い、unifiedと左右のdiffおよびthree-way mergeをengine上で描画する。
- `FR-12`: 既存の`ProjectEditorSuggestion`を使い、AI提案の部分適用とstale拒否をinline surfaceで扱う。
- `FR-13`: terminal surfaceはlibvterm gridのdamageを受け取り、変更セルだけを再描画する。
- `FR-14`: terminalのscrollback、選択、OSC 52、alternate screen、resize時のreflowを扱う。
- `FR-15`: CodeMirror経路をfallbackとして保持し、設定で切り替えられる。

### Quality attributes

- `QR-01`: 実キー入力から可視glyphまでのp95が、現行既定の基準値以下である。
- `QR-02`: scrollとterminal floodのframe timeが、60Hz表示で16.7msを超えるframeの比率で現行既定以下である。
- `QR-03`: 10MB fixtureの初回表示が現行既定より短く、常駐RSSが現行既定以下である。
- `QR-04`: layoutに要するメモリが文書サイズではなく可視行数に比例する。
- `QR-05`: 実機の日本語IMEで変換、確定、取消、再変換、tab切替中のcompositionが破綻しない。
- `QR-06`: VoiceOverでeditorの基本的な読み上げが成立する。

## Constraints

- macOS 14.0以降、Swift 6、SwiftUI application shellとAppKit high-frequency view（[ADR-0001](../../decisions/0001-adopt-swiftui-appkit-frontend.md)）。
- control planeはSwift所有を維持する（[ADR-0010](../../decisions/0010-m1-control-plane-swift-with-selective-rust-migration.md)）。
- private repositoryからbinaryを配布できるlicenseだけを使う。GPL系を採用しない。
- 既存の文書契約、comment anchor、diff model、suggestion modelを再実装しない。
- terminalのbroker protocolと`clair-ptyhost`を変更しない。

## Acceptance criteria

- `AC-01`: editorとterminalの双方がひとつの`ClairTextKit` surface上で動作する。
- `AC-02`: 実機の日本語IMEによる変換、確定、取消、再変換が、editorとterminalの両方で通る。
- `AC-03`: 10MBと長行のfixtureで、初回表示、scroll、編集応答が現行既定より改善している。
- `AC-04`: Claude Code、Codex、OpenCodeのTUIが正しく描画され、floodで入力を取りこぼさない。
- `AC-05`: diff、merge、AI提案、行コメントがengine上で操作でき、anchorがwrapとfoldingで正しい。
- `AC-06`: `P34`のgateで全metricが現行既定と同等以上であり、大規模fixtureで明確に優位である。
- `AC-07`: 既定切替後もCodeMirror fallbackが動作し、切り戻せる。

## Out of scope

- `L01`の最終負荷試験。engineのgateは`P34`で行い、`L01`はcutover全体の判断として残す。
- Rustへのdomain移行。ADR-0010の基準を満たす実測が出た場合の後続itemとする。
- Go LSPとDAPの機能実装。engineは描画先だけを用意する。

## Assumptions

- CoreTextのrun描画とglyph atlasで、60Hzのscrollとterminal floodに必要な描画性能が得られる。
- Tree-sitterのSwift bindingと必要言語のgrammarを、配布可能なlicenseで確保できる。
- 可視範囲限定layoutにより、文書サイズがlayout性能へ効かなくなる。

## Open questions

None.
