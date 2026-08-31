---
id: ADR-0001
title: "macOS frontendにSwiftUIとAppKitを採用する"
status: accepted
date: 2026-08-26
deciders:
  - Daiki
related_projects: []
related_issues: []
supersedes: []
superseded_by: []
---

# ADR-0001: macOS frontendにSwiftUIとAppKitを採用する

## Context

Clairは、Tauri、React、TypeScriptで実装されているcceditの次世代版を、WebViewに依存しないnative macOS IDEとして再構築するプロジェクトである。既存のRust実装が持つgit、filesystem、history、settings、hooks、LSP/DAP、PTY lifecycle等のdomain/backend機能は再利用する。

Frontendの候補として、次の2方式を2026-08-26時点のupstreamとClairの要件に照らして比較した。

- Swift executableがapplication lifecycleを所有し、SwiftUIで画面を構成しつつ、高頻度またはmacOS固有のviewにAppKitを使う。
- Rust executableがapplication lifecycleとdomainを所有し、GPUIでfrontend全体を実装する。

ここでいうnative化は、単にnative machine codeへcompileすることだけではない。WebViewとJavaScriptのhot pathを除去し、macOSのwindow、menu、responder chain、text input、accessibility、drag and drop、update/distribution機構と自然に統合することも含む。

## Decision drivers

- ClairはmacOS専用製品であり、cross-platform UI codebaseは現在の要件ではない。
- terminalはdaily-driver品質が必要で、libghosttyのmacOS embedded surfaceを利用したい。
- editorは日本語IME、marked text、Unicode offset変換、大規模file、LSP、git/debug gutterを扱う必要がある。
- terminalやeditorのhot pathをframework間の高頻度serializationへ載せない。
- 既存Rust domain/backendを捨てずに再利用する。
- private source repositoryからbinaryを配布できる依存licenseを維持する。
- upstreamのbreaking changeを追従する保守負担を、製品価値に見合う範囲へ抑える。
- 性能はframework名ではなく、同一workloadの計測で評価できる構成にする。

## Options considered

### Option A: SwiftUI application shell + AppKit high-frequency views + Rust core

- Advantages:
  - SwiftUIでsettings、history、git panel等の状態駆動UIを比較的少ないcodeで構築できる。
  - `NSViewRepresentable`を通じて、libghostty surface、source editor、`NSOutlineView`等のAppKit viewを正式な仕組みで埋め込める。
  - macOSのwindow、menu、keyboard focus、IME、accessibility、drag and drop、Sparkleとの統合経路が明確である。
  - terminalとeditorをSwiftUIの再描画やUniFFIのrequest/responseから分離できる。
  - SwiftUIが適さない箇所だけAppKitへownershipを広げられる。
- Disadvantages:
  - Swift、AppKit/SwiftUI、Rustの複数のtoolchainとruntime boundaryを保守する必要がある。
  - Rust coreをTauri adapterから分離し、UniFFIまたはC ABIを設計する作業が発生する。
  - SwiftUI、AppKit、Rust間でstate、thread、object lifetimeを明示的に管理する必要がある。
  - native source editorは依然として大きな実装リスクである。
- Evidence:
  - AppleはSwiftUIへの`NSView`埋め込みと、AppKitへのSwiftUI埋め込みを正式に提供している。
  - libghosttyのembedded C APIはmacOSのnative viewを受け取る構成を提供している。
  - UniFFIはSwift binding、async function、callback interfaceを提供している。
  - CodeEditTextViewはlarge document向けのSwift/AppKit editor基盤を提供するが、`NSTextView`完全互換ではないためspikeが必要である。

### Option B: Rust + GPUI frontend

- Advantages:
  - frontendとdomain/backendをRustへ統一し、通常のcontrol pathでFFIを不要にできる。
  - GPU accelerated renderingと、IDEのようなcustom UIに適したlow-level element APIを持つ。
  - Zedで大規模なeditor UIを動かしている実績がある。
  - gpui-componentにはdock、tree、virtual list、settings、code editor、LSP表示等、Clairと近い部品が存在する。
  - 将来Windows/Linuxを対象にする場合、同一frontendを共有できる可能性がある。
- Disadvantages:
  - GPUIはpre-1.0でbreaking changeが多く、公式文書も現時点ではZed sourceの参照を前提としている。
  - GPU描画されるnative binaryではあるが、AppKit標準controlを中心に構成するframeworkではない。macOS固有機能の不足はClair側またはupstreamで補う必要がある。
  - libghosttyの完成済みmacOS surfaceをGPUIのpane、focus、clip、overlay、drag lifecycleへ統合する標準adapterがない。
  - 公開されているgpui-terminal 0.1.0は、評価時点でmouse text selectionとscrollback navigationが未実装である。
  - Zed本体の高度な`editor`、`ui`、`terminal_view` crateはGPL-3.0-or-laterであり、GPUIがApache-2.0であることだけを根拠にZed実装をprivate製品へ転用できない。
  - Zedのmain branchには、GPUIのdependency graphへGPL crateが入る可能性について未解決のlicense issueがある。採用する場合は固定revisionとdependency単位のlicense auditが必要になる。
- Evidence:
  - GPUI 0.2.2およびupstream README。
  - gpui-component 0.5.1とupstream mainのcomponent/editor/dock機能。
  - gpui-terminal 0.1.0のfeature matrix。
  - Zedの`editor`、`ui`、`terminal_view` crate manifest。

## Decision

Clairのfrontendには **SwiftUI application shell + AppKit high-frequency views** を採用する。Rust + GPUIは採用しない。

適用範囲は次のとおりとする。

- Swift executableがapplication lifecycleを所有する。
- SwiftUIはwindow内の主要layout、settings、history、git panel等の一般的なUIを構成する。
- terminal、source editor、大規模file tree等、描画頻度、text input、macOS固有制御が重要な箇所はAppKit viewとして実装し、SwiftUIへ埋め込む。
- window、menu、responder chain、pane drag and drop等でSwiftUIが制約になる場合、そのcomponentのownershipをAppKitへ移してよい。全面的なSwiftUI実装を要件にしない。
- Rust coreはUI frameworkに依存させず、control planeをUniFFI、必要に応じてC ABIでSwiftへ公開する。
- PTY byte stream等のhot pathは、per-message JSONやUniFFI record変換を避け、binary Unix socket、shared buffer、または薄いC ABI callbackを使用する。
- GPUIおよびZed固有UI crateを初期architectureへ含めない。

## Rationale

ClairはmacOS専用であるため、GPUIのcross-platform性より、macOS integrationとAppKit ecosystemを直接利用できることを優先する。

特にterminalが判断を支配する。SwiftUIとAppKitの公式bridgeを使えば、libghosttyが提供するmacOS surfaceを`NSView`として保持できる。一方、GPUIで同じsurfaceを使うにはnative child viewのfocus、layout、clipping、overlay、pane移動を独自に統合する必要がある。純GPUI terminalの既存選択肢も、評価時点ではClairのdaily-driver要件を満たしていない。

GPUIの性能上限とRust code reuseは魅力的である。しかしClairの採用案ではterminalとeditorをSwiftUIのhot pathへ置かず、Rustとの境界もcontrol planeへ限定する。このため、GPUIの利点がそのままClair全体の体感性能差になるとは限らない。性能差はvertical sliceの実測なしに採用理由としない。

gpui-componentのeditorとdockは有望であり、GPUI案を非現実的とは判断しない。ただし、frameworkのpre-1.0状態、macOS integrationの追加実装、terminalの不足、Zed固有crateのlicense境界を同時に引き受ける理由は、現在のClair要件にはない。

## Consequences

### Positive

- libghosttyとAppKit text/input systemを自然なboundaryで利用できる。
- macOS固有のUXとOS更新への追従をApple platform API上で行える。
- SwiftUIの開発速度とAppKitの低レベル制御をcomponent単位で使い分けられる。
- Rust coreをUI非依存にすることで、V1 adapter、Clair、将来の別frontendから再利用できる。
- GPUI/Zed mainのAPI churnおよびlicense uncertaintyを初期releaseのcritical pathから外せる。

### Negative

- Swift/Rust FFIと2つの言語ecosystemを保守する。
- MainActor、Rust worker、callback解除、opaque handleのlifetime ruleを設計・testする必要がある。
- SwiftUIとAppKitをまたぐfocus、layout、state同期の不具合が発生し得る。
- GPUIなら直接利用できた可能性があるRust製dock/editor componentを再利用しない。
- Windows/Linux frontendを追加する場合は別実装または新しいarchitecture decisionが必要になる。

## Validation

PoC期間はSwiftUI/AppKit/Rust境界のbuild、unit/integration、IME、terminal/editor操作の
functional smokeだけを各featureで確認する。V1とのformal performance comparisonは
[PoC queueの`L01`](../plans/clair-poc-queue.md#l01-final-load-and-performance)まで行わない。
L01では同一のfixtureと操作scriptを用いて、統合済みClairとV1を比較する。

- cold/warm launchからfirst interactiveまでの時間。
- idle RSS、CPU、process数、energy impact。
- terminal flood時のCPU、p95 frame time、drop frame、input-to-glyph latency。
- terminalのresize、selection、scrollback、OSC 52、OSC 633、IME/CJK、wide glyph。
- 10MB/100MB fileのopen、scroll、edit、find、save。
- editorの日本語IME、marked text、emoji、combining character、UTF-8/UTF-16/grapheme offset変換。
- 大規模file tree、git status更新、pane drag and drop。
- application restart後のPTY reattach。
- Rust callbackがMainActor ruleとlifetime ruleに違反しないことをunit/integration testで確認する。

SwiftUIのhitchが観測された場合は、直ちにframework全体を変更せず、該当componentをAppKitへ移して再計測する。

## Revisit conditions

次のいずれかが成立した場合、新しいADRで本判断を再検討する。

- WindowsまたはLinux対応がcommitted product requirementになり、単一frontendの価値がmacOS固有UXを上回る。
- GPUIがstable API policyを持つ1.0相当へ到達し、Clairが必要とするmacOS integrationと文書が提供される。
- permissive licenseで利用できるGPUI terminalが、selection、scrollback、OSC 52/633、IME/CJK、wide glyph、reattachを満たす。
- libghosttyがGPUIへ直接組み込めるrenderer/surface APIを提供するか、Clairのspikeでnative view統合が低riskと実証される。
- permissive licenseのGPUI editorがClairのeditor vertical sliceを満たし、Swift/AppKit案との実測で大幅な性能または実装量の差を示す。
- FFIが実測上の主要bottleneckとなり、batching、binary transport、C ABIでも解消できない。
- ClairをGPL互換でsource公開する方針へ変更し、Zed由来crateの採用可能範囲が変わる。

## References

- [Apple: Integrating AppKit](https://developer.apple.com/tutorials/app-dev-training/integrating-appkit)
- [Apple: NSViewRepresentable](https://developer.apple.com/documentation/swiftui/nsviewrepresentable)
- [Apple: NSHostingView](https://developer.apple.com/documentation/swiftui/nshostingview)
- [GPUI README](https://github.com/zed-industries/zed/blob/main/crates/gpui/README.md)
- [GPUI crate manifest](https://github.com/zed-industries/zed/blob/main/crates/gpui/Cargo.toml)
- [GPUI Component](https://github.com/longbridge/gpui-component)
- [gpui-terminal](https://docs.rs/gpui-terminal/latest/gpui_terminal/)
- [Ghostty and libghostty](https://github.com/ghostty-org/ghostty)
- [libghostty embedding header](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty.h)
- [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView)
- [UniFFI Swift bindings](https://mozilla.github.io/uniffi-rs/latest/swift/overview.html)
- [Zed editor crate manifest](https://github.com/zed-industries/zed/blob/main/crates/editor/Cargo.toml)
- [Zed UI crate manifest](https://github.com/zed-industries/zed/blob/main/crates/ui/Cargo.toml)
- [Zed terminal_view crate manifest](https://github.com/zed-industries/zed/blob/main/crates/terminal_view/Cargo.toml)
- [GPUI dependency license issue #55470](https://github.com/zed-industries/zed/issues/55470)
