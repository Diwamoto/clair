---
id: ADR-0010
title: "M1 control planeのSwift所有確定とドメイン選択的Rust移行基準"
status: accepted
date: 2026-09-03
deciders:
  - Daiki
related_projects: []
related_issues:
  - 7
  - 8
supersedes:
  - ADR-0001
superseded_by: []
---

<!-- ADR-0001のsupersedeは「Rust core再利用」条項の解釈のみ。frontend選択（SwiftUI + AppKit）は本ADRでも変更せず継続する。 -->
---

# ADR-0010: M1 control planeのSwift所有確定とドメイン選択的Rust移行基準

## Context

[ADR-0001](0001-adopt-swiftui-appkit-frontend.md)はfrontend選択（SwiftUI + AppKit）を
決める際、「既存のRust実装が持つgit、filesystem、history、settings、hooks、LSP/DAP、PTY
lifecycle等のdomain/backend機能は再利用する」をdriverとし、「Rust coreはUI frameworkに
依存させず、control planeをUniFFI、必要に応じてC ABIでSwiftへ公開する」と定めた。
[product vision](../clair-spec.md)も「cceditのRust coreとterminal基盤はClairへ移管
して再利用する」と記述している。

一方、2026-09-03時点の実装はこの前提と乖離している。M1の全vertical slice（P01〜P14、
P15A）でProject kernel、Git、search/history、Command Registry、CLI/MCP adapter、
worktree/catalog、update/lifecycleのcontrol planeはすべてSwift native実装（約22,000行、
91件超のXCTest）として完成している。Rustの実稼働は`clair-ptyhost` brokerのみで、
これは[ADR-0003](0003-versioned-session-broker-protocol.md)が定めるプロセス境界経由で
動作する。`clair-core`はbootstrap smoke ABI 1関数のみを持ち、cceditのRust資産
（git/fs/history約3,600行、Tauri command郡）はClair repositoryへ未移植である。

[PoC queueのP15D](../clair-tasks.md)はこの乖離を`blocked`とし、cutover前に
「(a) Tauri非依存Rust domainとversioned Swift bridgeへ移す」または「(b) Rust ownershipを
PTY等へ狭めるsuperseding ADRとproduct docsをacceptする」のどちらかで一つのaccepted
architectureへ揃えることを要求している。このdecisionを固定するため、2026-09-03に
Swift / Rust / Goの3言語を比較調査した。

## Decision drivers

- M1 cutover（P15）を最短で達成し、実装済みvertical sliceとテスト資産を捨てない。
- 性能はframework名ではなく、同一workloadの実測で評価する（ADR-0001の原則を踏襲）。
- ライブラリ成熟度が明確に優位なドメインには、証拠駆動で移行できる経路を残す。
- ccedit廃止条件はvisionの成功基準であり、言語境界の形ではない。
- GoはmacOS file watcherの構造的欠陥により、control plane言語の候補から外す。

## Options considered

### Option A: 全control planeをTauri非依存Rust domain + versioned Swift bridgeへ移行する

- Advantages:
  - ADR-0001の原本を全面適用する最も忠実な解釈である。
  - Git（`git2`/`gix`）、全文検索（`ignore`+`regex` = ripgrep内部と同一エンジン）、
    watcher（`notify` + FSEvents backend）等、Rust ecosystemの成熟度が最も高い。
  - 将来別frontendが要件になった場合に共有domainを再利用できる。
- Disadvantages:
  - 動作中のSwift実装約22,000行と91件超のテストを再実装に置き換え、P15 cutoverが
    大幅に遅延する。queueもこの場合のtyped interface単位へのitem分割を予告している。
  - UniFFI/C ABIの設計に加え、panic containment、threading、cancellation、handle/callback
    lifecycleのcontract testを全control plane対象に整備する必要がある。
- Evidence:
  - cceditのRust資産はTauri依存でそのまま再利用できず、ドメイン抽出から始まる。
  - gitoxideは`status`やcheckoutでcanonical git比1.4〜1.8倍高速を報告する一方、`reset`、
    `rebase`は未実装であり、全面移行でもsubprocess依存は残る可能性がある。

### Option B: Swift所有を確定し、ドメイン選択的にRustへ移行する基準を設ける

- Advantages:
  - 実装済み・検証済みのvertical sliceを維持し、cutover経路を短くする。
  - subprocess方針（`/usr/bin/git`や外部検索toolの利用）は正確性と保守性が高く、L01の
    実測で問題にならない限りそのまま維持できる。
  - Rust移行が必要になったときに、ドメイン単位でversioned FFIを追加する経路が保証される。
- Disadvantages:
  - ADR-0001の「Rust domain再利用」の原義を狭めるrevisionである。
  - 移行判断が遅延した場合、subprocess実装の性能問題をlong-termに抱える可能性がある。
  - Swift/Rustの二言語保守は継続する。
- Evidence:
  - 現状の唯一の実測性能問題（P15B audit: 大repoでfile tree/watcherがUIを占有）は
    言語性能ではなく同期処理と無制限watcherというアーキテクチャ起因である。

### Option C: Goでcontrol planeを新実装する

- Advantages:
  - 利用者にとって最も読み書きしやすい言語であり、goroutineと標準libで擬似的な
    local serviceを早く組める。
- Disadvantages:
  - `fsnotify`のmacOS backendはkqueueで、監視対象のfile/directoryごとにfile descriptorを
    消費する。実測で単一repoが39,894 fd（上限の65%）に達した報告があり、FSEvents
    backendは約10年間未実装のままである。Clairのfile watcher要件（P15B）を構造的に
    満たせない。
  - Go標準`regexp`はripgrep系のDFA/SIMD最適化がなく、pure Go再実装はripgrep比で
    大幅に遅いことが報告されている。
  - `go-git`はpure Go実装だが、Gitalyがcorruption問題で利用を縮小した経緯があり、
    大規模repoやpack処理でcanonical git/libgit2に及ばない。
  - 新実装のため既存テスト資産はすべて失われ、cutoverが最も遅れる。
- Evidence:
  - fsnotify READMEのkqueue backend注記と、FSEvents supportのopen issue。
  - Gitalyのgo-git離脱、pure Go ripgrep再実装のベンチマーク（約46倍低速報告）。

## Decision

1. M1のcontrol plane（Project kernel、workspace persistence、file tree/navigation、
   search/history、Git/review、agent workflow、worktree/catalog、Command Registry、
   CLI/MCP adapter、update/lifecycle）はSwift所有を確定する。ADR-0001のfrontend選択
   （SwiftUI application shell + AppKit high-frequency views）は変更しない。
2. Rustの恒常的所有範囲は`clair-ptyhost`（PTY lifecycleとbroker protocol、ADR-0003）と
   する。`clair-core`のbootstrap smoke C ABIはlink/lifecycle検証用であり、将来の
   domain interfaceへの拡張を意味しない。
3. Rust domainへの移行はドメイン単位で選択的に行う。移行が許されるのは次のどちらかを
   満たす場合に限る。
   - L01または個別itemのfunctional checkで、Swift/subprocess実装がcutoverまたは
     acceptanceのblockerとなる実測証拠がある。
   - 要件を満たすSwift/macOS側のライブラリが存在せず、Rust側に成熟した実装がある
     （例: `ignore`+`regex`、`git2`/`gix`、`notify`）。
   候補ドメインの例は全文検索、Git操作、大規模file tree/watcherである。Goは除外する。
4. 移行はtyped interface単位とし、versioned request/result/error、panic containment、
   threading、cancellation、handle/callback lifecycleのcontract testを伴わない移行を
   行わない。Command Registryのstable command ID、typed parameter/result/error、
   `aiAvailable`、static riskの外部契約は言語境界に関わらず維持する。Tauriをlinkしない
   build/testであること。リリースに同梱する`clair` CLIはRust製の薄いlocal IPC client
   として実装してよいが、これはadapterのprocess boundaryを選ぶものであり、commandの
   semantics、agent state、authorizationのownershipをRustへ移すdomain migrationではない。
   CLIはこのversioned external contractを維持する。
5. cceditのRust資産の「移管」は上記の選択基準に従う個別移行として扱い、M1のcutover
   条件から外す。terminal基盤の移管は`clair-ptyhost`で完了と見なす。

## Rationale

Option Bは、ADR-0001が掲げた「性能はframework名ではなく実測で評価する」という原則に
最も忠実な形である。Option Aの全面移行は、動作中の実装と検証資産を捨ててcutoverを
遅らせる対価に見合わない。Option CはGoのmacOS watcher backendが監視対象ごとにfdを
消費する構造的欠陥を持ち、Clairのfile watcher要件そのものを満たせないため除外する。

subprocess方針はspawn costを伴うが、canonical gitの正確性と保守性をそのまま利用でき、
L01のfrozen corpusで実測して問題がなければ長期的にも有効である。問題が実測された場合も、
本ADRの選択基準に従って対象ドメインだけをversioned FFIでRustへ移せばよく、全面的な
言語境界の引き直しは不要である。

vision.mdの「cceditのRust coreとterminal基盤はClairへ移管して再利用」は、terminal基盤の
移管（`clair-ptyhost`）が完了済みであり、Rust coreの各ドメインは本ADRの選択基準を
満たしたものだけを移管する、と解釈を更新する。

## Consequences

### Positive

- M1 cutover（P15）への経路が最短になり、91件超の既存XCTestと22,000行の実装を維持する。
- product docs、accepted ADR、architecture、実装ownershipの矛盾が解消される。
- Goがcontrol plane言語候補から明確に除外される。
- 全文検索、Git、watcher等のドメインについて、実測またはライブラリ成熟度に基づく
  段階的Rust移行パスが保証される。
- `clair-ptyhost`の所有範囲が確認され、ADR-0003のbroker protocolは変更なしで継続する。

### Negative

- ADR-0001の「Rust domain再利用」条項は本ADRで解釈をrevisionする。
- Gitと検索のsubprocess依存は当面継続し、spawn/overheadの実測評価はL01に残る。
- 選択的移行が発生した時点でUniFFI/C ABIの設計と保守が追加される。
- cceditのRust資産は、選択基準を満たさない限り移管せず放置する。
- Swift/Rustの二言語保守は継続する。

## Validation

- product docs、accepted ADR、architecture、実装ownershipに矛盾がないことをreviewする。
- 選択的移行を行うitemでは、Tauriをlinkしないbuild/test、versioned request/result/error、
  panic containment、threading、cancellation、handle/callback lifecycleのcontract testを
  追加する。
- L01ではqueueのルールに従い、frozen corpusでSwift/subprocess実装の実測を行い、
  cutover blockerがないことを確認する。

## Revisit conditions

- L01またはitemのfunctional checkで、Swift/subprocess実装がcutover/acceptanceの
  blockerになる実測証拠が得られた。
- 要件を満たすSwift/macOS側ライブラリの不在が明らかになり、対象ドメインの選択的Rust
  移行が開始される。
- 別frontend（Windows/Linux等）がcommitted product requirementになり、共有Rust domainの
  価値がmacOS UXへの直結性を上回る。
- `fsnotify`にFSEvents backendが実装される等、Goの構造的欠陥が解消された場合でも、
  本ADRのSwift所有確定は原則維持し、Goは新規ドメインの評価対象にのみ復帰する。

## References

- Frontend decision: [ADR-0001](0001-adopt-swiftui-appkit-frontend.md)
- Broker protocol: [ADR-0003](0003-versioned-session-broker-protocol.md)
- Command Registry: [ADR-0007](0007-unify-operations-in-a-typed-command-registry.md)
- Product vision: [Clair product vision](../clair-spec.md)
- Queue block: [P15D in PoC queue](../clair-tasks.md)
- P15B audit evidence: [PoC queue P15B entry](../clair-tasks.md)
- Language comparison (2026-09-03): fsnotify kqueue fd消費、Gitalyのgo-git離脱、
  pure Go ripgrep再実装のベンチマーク、gitoxideのstatus/checkoutベンチマーク
- Issue: [#7](https://github.com/Diwamoto/clair/issues/7)、[#8](https://github.com/Diwamoto/clair/issues/8)
