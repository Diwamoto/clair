---
id: ADR-0014
title: "editorとterminalが共有するClair所有のtext engineを実装する"
status: accepted
date: 2026-09-11
deciders:
  - Daiki
related_projects:
  - p0028-clair-text-engine
related_issues: []
supersedes: []
superseded_by: []
---

# ADR-0014: editorとterminalが共有するClair所有のtext engineを実装する

## Context

2026-09-11時点で、Clairの体感を決める二つのhot pathはどちらも暫定実装である。

- 本番editorはWKWebView上のCodeMirror 6である（[CodeMirrorEditor.swift](../../apple/ClairApp/CodeMirrorEditor.swift)、
  [editor-web](../../editor-web)）。cceditと同一engineの上にSwiftとの往復を一段足した構成であり、
  構造上cceditを超えない。`NativeEditor.swift`のAppKit経路はDev限定のopt-inで、正規表現ハイライトのままである。
- terminalはlibvterm 0.3.3のgridを`NSTextView`派生viewが全セル個別に描画する（[TerminalSurface.swift](../../apple/ClairApp/TerminalSurface.swift)）。
  `draw(_:)`は`dirtyRect`を使わず、scrollback上限4,000行と全列を毎回走査する。cceditのxterm.jsは差分描画である。

P15AとP15Bはfunctional correctnessとして完了しており、性能評価は`L01`へ先送りされている。`L01`は未実行であり、
「cceditより明確に快適」という[vision](../product/vision.md)の成功条件は現時点で一度も検証されていない。

[native editor PoC](../issues/native-editor/README.md)はCodeEditSourceEditor系を条件付き候補としたが、
NE-01（grammar許諾）、NE-03（実IME）、NE-11（本番接続）がblockedのままである。PoCの実測は10MBの初回色付けが
約4.7秒、累積RSSが約1.1GiBであり、報告自身が「VS Code相当との判定は未達」と記録している。

製品としての位置づけも判断に含める。editorだけで良ければVS Codeがあり、terminalだけで良ければGhosttyがある。
Clairの存在理由は、その両方を一つのProject workspaceで妥協なく持つことである。両方のhot pathが借り物である限り、
この主張は成立しない。

技術的な鍵は、editorとterminalが別物に見えて、monospace text surfaceとしては下層を共有できることである。
font metrics、glyph atlas、run描画、damage管理、viewport scroll、選択geometry、`NSTextInputClient`は両者で同じものが要る。
分岐するのはmodelとlayoutだけで、editorは可変長行とwrapとfolding、terminalは固定gridとscrollbackである。
この共有は、VS CodeとGhosttyを個別に使う構成に対してClairが持てる構造的な差でもある。

## Decision drivers

- 日常操作の体感がcceditより明確に快適であること。これは[vision](../product/vision.md)の成功条件である。
- editorとterminalの双方をdaily-driver品質にすること。片方の妥協を製品の前提にしない。
- 日本語IME、marked text、再変換、grapheme単位の操作の品質を落とさないこと。
- 大規模fileと長行でlayoutが破綻しないこと。
- private repositoryからbinaryを配布できるlicenseを維持すること。
- 製品の中核をupstreamの破壊的変更に人質へ取られないこと。
- [ADR-0001](0001-adopt-swiftui-appkit-frontend.md)のSwiftUI/AppKit選択と、
  [ADR-0010](0010-m1-control-plane-swift-with-selective-rust-migration.md)のSwift所有を維持すること。

## Options considered

### Option A: CodeMirrorを維持し、terminal描画だけ局所修正する

- Advantages:
  - 最小の工数で、editorのfeature parityは自動的に満たされる。
  - 既存のbridge契約とtestをそのまま使える。
- Disadvantages:
  - editorはcceditと同一engineであるため、体感でcceditを超える根拠がない。
  - WKWebViewのprocessとメモリが常駐し続ける。
  - diff、merge、AI提案、コメントrailが常にbridge越しの後付けになる。
- Evidence:
  - PoC測定では10MBの`setDocument`往復が約3秒、20回の選択で本文209,714,700 bytesがbridgeを通過した
    （[poc-measurements.md](../issues/native-editor/evidence/poc-measurements.md)）。

### Option B: CodeEdit系を本番採用する（既存のNE-15〜NE-23）

- Advantages:
  - AppKit向けで唯一まとまって再利用できるSwift部品であり、licenseはMITである。
  - 複数カーソルと行ストレージを持つ。
- Disadvantages:
  - NE-01、NE-03、NE-11がblockedで、grammarとSymbolsの配布許諾が未解決、実IMEが未検証である。
  - 10MBで初回色付け約4.7秒、累積RSS約1.1GiBであり、採用ゲートを通っていない。
  - gutterがcontroller内部にあるため独自railを左へ別置きする必要があり、左右diffも独自projectionだった。
  - upstreamのREADMEがproduction readyでないと明記している。
  - terminalには何も寄与しない。
- Evidence:
  - [poc-report.md](../issues/native-editor/evidence/poc-report.md)。

### Option C: SwiftTerm（terminal）とCodeEdit（editor）を個別に採用する

- Advantages:
  - 両方の surface が短期間で動作水準に達する。
- Disadvantages:
  - 製品の中核を二つの独立したupstreamへ預ける。
  - IME、選択、theme、scrollの挙動がeditorとterminalで別実装になり、同一workspaceとしての一貫性を失う。
  - 共有engineによる構造的優位を最初から放棄する。
- Evidence:
  - STTextViewはGPLv3または商用licenseであり、現在のclosed-source方針と衝突する（PoC調査）。

### Option D: Clair所有の共有text engineを実装する

- Advantages:
  - 下層をeditorとterminalで共有し、両方を同時にdaily-driver品質へ引き上げられる。
  - 可視範囲だけをlayoutする構成にできるため、file sizeがlayout性能へほぼ効かなくなる。
  - diff、merge、AI提案、コメントrailをbridge越しの後付けではなく一級市民として描ける。
  - upstream依存をCoreText、font、Tree-sitterへ限定できる。
- Disadvantages:
  - `NSTextInputClient`と`NSAccessibility`の正しさを自分で負う。
  - 検証が実機手動に依存する領域を抱える。
  - 上流が存在しないため、欠陥も保守も恒久的に自分のものになる。
- Evidence:
  - Xcode、Nova、BBEdit、TextMate、Sublime Textはいずれも独自text engineを持つ。
  - CodeEditTextViewも同じ理由で`NSTextView`を使わず独自のCoreText layoutを実装している。
  - Ghosttyはmonospace gridの独自renderingでdaily-driver品質を達成している。

## Decision

**Option D**を採用する。適用範囲は次のとおりとする。

1. `ClairTextKit`をmacOS app target内の独立moduleとして実装し、editor surfaceとterminal surfaceの双方がこれを使う。
2. 共有する層は、font metricsとglyph atlasとrun cache、damageに基づく描画、viewport scroll、選択geometry、
   `NSTextInputClient`、`NSAccessibility`とする。
3. 分岐する層は、editorがpiece table・line index・soft wrap・folding、terminalがlibvterm gridのadapterとする。
4. 文書契約は既存の`ProjectEditorDocumentModel`を正本として維持する。engineが置き換えるのはその下のstorageとview
   だけであり、[comment anchor](../../apple/ClairApp/ProjectEditorCommentAnchor.swift)、
   [diff model](../../apple/ClairApp/ProjectEditorDiffModel.swift)、
   [suggestion model](../../apple/ClairApp/ProjectEditorSuggestion.swift)は再実装しない。
5. 実装言語はSwiftとする。Rustへ移すのはADR-0010の選択基準を満たす実測証拠が出た場合に限り、その場合も境界は
   「可視範囲の行と属性をbatchで返す」に限定する。打鍵ごとにFFIを跨ぐ設計を作らない。
6. CodeMirror経路は既定を外した後もfallbackとして残す。既存の`clair.editor.native-v1` opt-inを逆向きの切替に使う。
7. NE-11およびNE-15〜NE-23のCodeEdit本番採用経路はこの決定で置き換え、着手しない。NE-00〜NE-10とNE-14の成果、
   すなわち文書契約、anchor、任意差分model、安全な部分適用modelは前提として使う。
8. 本programの各queue itemはslice単位のperformance evidenceを持つ。engineは性能そのものが受け入れ条件であるため、
   「benchmarkは`L01`まで行わない」という[queue方針](../plans/clair-poc-queue.md)を本programに限り改める。
   比較対象は同一hostで取得した現行既定（CodeMirror editorと現行terminal surface）の基準値とする。

## Rationale

decision driversのうち決定的なのは、体感でcceditを超えることと、両方のsurfaceを妥協しないことの二つである。
Option AとOption Bはそれぞれ片方のsurfaceにしか効かず、Option Aはeditorでcceditと同じ上限を共有し続ける。
Option Cは両方を動かせるが、IMEと選択とthemeが二実装に割れ、同一workspaceという製品の主張を実装レベルで裏切る。

Option Dの費用は明確で、`NSTextInputClient`と`NSAccessibility`の正しさである。ただしこれはOption Bでも
NE-03として未解決のまま残っていた項目であり、CodeEditを採用しても消えない。自作へ移ることで、少なくとも
その正しさが自分の管理下に入る。

可視範囲だけをlayoutする構成は、TextKitとCodeMirrorの双方が大規模fileで詰まる原因を構造的に取り除く。
これは実装の巧拙ではなくデータ構造の選択であり、PoCが記録した10MBでの4.7秒と1.1GiBに対する直接の回答である。

Rustを使わずSwiftで実装するのは、ADR-0001が「terminalやeditorのhot pathをframework間の高頻度serializationへ
載せない」と定めているためである。ADR-0010のRust移行基準は成熟したライブラリの存在を条件にしており、text buffer
そのものは該当し得るが、hot pathがFFIを跨ぐ代償のほうが大きい。実測で覆るまではSwiftで所有する。

## Consequences

### Positive

- editorとterminalの体感を、一つのengineの改善で同時に引き上げられる。
- file sizeがlayout性能へ効かなくなり、PoCが記録した大規模fileの制約が構造的に解消する。
- diff、merge、AI提案、コメントrailをsurfaceの一級市民として実装できる。
- WKWebViewとCodeMirrorをhot pathから外し、常駐processとメモリを減らせる。
- 配布許諾の不確実性が、未解決だったgrammar資産の範囲まで縮む。

### Negative

- `NSTextInputClient`、`NSAccessibility`、grapheme境界、CJKの語境界の正しさを恒久的に自分で負う。
- 日本語IMEとVoiceOverの検証は実機手動に依存し、unit testだけでは完了を判定できない。
- upstreamが存在しないため、macOSの更新追従も自分の作業になる。
- programが完了するまでCodeMirrorとengineの二経路を保守する期間が生じる。

## Validation

`P34`のgateで、同一host・同一fixture・同一操作scriptにより、engine既定と現行既定を比較する。

- 実キー入力から可視glyphまでの時間、p50とp95。
- scrollとterminal flood時のframe time、drop frame。
- 10MBおよび長行fixtureの初回表示、初回色付け、編集応答。
- idle RSS、process数、terminal flood時のCPU。
- 実機の日本語IMEによる変換、確定、取消、再変換、tab切替中のcomposition。
- VoiceOverによる行・選択・caret位置の読み上げ。

engineがすべての指標で現行既定と同等以上、かつ大規模fixtureで明確に優位でない限り、既定を切り替えない。

## Revisit conditions

- `P19`の実装反復を二度行っても、実機の日本語IME要件を満たせない場合。この場合はOption Cへ退避し、
  editorをCodeEdit、terminalをSwiftTermとする判断を新しいADRで行う。
- `P34`のgateで、engineが現行既定に対して明確な優位を示せない場合。
- Apple がTextKit 2に、可視範囲限定layoutと大規模文書を実用水準で扱えるAPIを追加した場合。
- WindowsまたはLinux frontendがcommitted product requirementになり、共有Rust coreの価値がmacOS UXへの
  直結性を上回る場合。

## References

- Project: [p0028-clair-text-engine](../projects/p0028-clair-text-engine/README.md)
- Frontend decision: [ADR-0001](0001-adopt-swiftui-appkit-frontend.md)
- Control plane ownership: [ADR-0010](0010-m1-control-plane-swift-with-selective-rust-migration.md)
- Investigation: [native editor PoC](../issues/native-editor/README.md)、
  [poc-report.md](../issues/native-editor/evidence/poc-report.md)、
  [poc-measurements.md](../issues/native-editor/evidence/poc-measurements.md)
- Benchmark: [ccedit V1 baseline procedure](../benchmarks/clair-v1-baseline.md)
- Queue: [P17〜P34](../plans/clair-poc-queue.md)
