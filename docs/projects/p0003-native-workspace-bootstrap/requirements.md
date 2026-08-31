# Requirements

## Motivation

Clairはまだproduction codeを持たず、acceptedなSwiftUI/AppKit frontend方針とRust core方針を
clean checkoutから実行できるworkspaceがない。StableでClairを開発し、別bundleのDevを試す
dogfooding loopを成立させるには、最初にtoolchain、target、runtime identity、FFI、CI commandを
同じ再現可能な契約へ揃える必要がある。

## Goals

- `G-01`: Swift executableがapplication lifecycleを持つ最小native macOS appを作る。
- `G-02`: Rust workspaceに再利用可能な`clair-core` static libraryと`clair-ptyhost`雛形を作る。
- `G-03`: StableとDevをbundle、Dock表示、settings、application dataの全てで分離する。
- `G-04`: SwiftからRustへ同期的な最小smoke callを通し、unit testで契約を固定する。
- `G-05`: localとCIが共用するbuild、run、test、lint、smoke commandを文書化する。
- `G-06`: build artifact、generated file、third-party noticeの配置規約を決める。

## Non-goals

- Project UI、editor、terminal renderer、Git UIを実装しない。
- `clair-ptyhost`でPTYをspawn、detach、reattachしない。
- UniFFI binding、async callback、high-frequency data pathを設計しない。
- Sparkle、code signing、notarization、正式配布を実装しない。
- ccedit settings/dataのimportまたは互換層を作らない。
- 正式app iconやrelease branding assetを制作しない。

## User-visible behavior

- `make doctor`は必要なXcode、Swift、Rust componentの不足を具体的に報告する。
- `make build-stable`と`make build-dev`は署名なしの`Clair.app`と`Clair Dev.app`を別の
  DerivedData rootへ生成する。
- `make run-stable`と`make run-dev`は各bundleを新しいprocessとして起動する。
- Stableは`Clair`、Devは`Clair Dev`として表示され、同時起動してもpreferencesと
  Application Support directoryを共有しない。
- 初期windowは実行channel、bundle ID、data directory、Rust smoke resultを表示する。
- `make test`、`make lint`、`make smoke`はlocalとCIで同じ検証入口になる。

## Requirements

### Functional

- `FR-01`: repository rootに`Clair.xcworkspace`を置き、shared scheme `Clair Stable`と
  `Clair Dev`からnative app targetをbuildできる。
- `FR-02`: root Cargo workspaceは`crates/clair-core`と`crates/clair-ptyhost`をmemberに持つ。
- `FR-03`: `clair-core`はRust testから利用できるlibrary APIと、Swiftからlinkする
  `clair_core_smoke() -> UInt32` C ABIを公開する。
- `FR-04`: Xcode buildは対象configurationとnative architectureに対応するRust static libraryを
  buildしてからSwift executableをlinkする。
- `FR-05`: Stableはbundle ID `com.diwamoto.clair`、product/display name `Clair`、
  Application Support directory `Clair`を使う。
- `FR-06`: Devはbundle ID `com.diwamoto.clair.dev`、product/display name `Clair Dev`、
  Application Support directory `Clair Dev`を使う。
- `FR-07`: preferencesは各bundleのstandard `UserDefaults` domainを使い、共有suiteを使わない。
- `FR-08`: app launch時にprofile固有のApplication Support directoryを作成し、作成失敗は
  UIに診断可能なstatusとして出す。
- `FR-09`: `clair-ptyhost`はversion/smoke情報を出力して成功終了する雛形とunit testを持つ。
- `FR-10`: GitHub ActionsはRust test/lint、Swift test、Stable/Dev unsigned build、bundle metadata
  smoke checkをmacOS runnerで実行する。
- `FR-11`: root commandはtoolchain診断、build、run、test、lint、smokeを提供し、CIもそれを使う。
- `FR-12`: generated artifactをcommit対象から除外し、third-party noticeの正本位置を定義する。

### Quality attributes

- `QR-01`: app buildはnetworkを必要とするthird-party source dependencyを持たない。
- `QR-02`: Stable/Devのidentity値はxcconfigとSwift testから検証可能で、scheme内へ重複させない。
- `QR-03`: C ABIはfixed-width integerと`extern \"C\"`だけを使い、ownershipやallocationを跨がない。
- `QR-04`: build commandはrepository外のuser dataを削除またはmigrationしない。
- `QR-05`: command失敗時は実行したsub-toolのnon-zero statusを保持する。
- `QR-06`: tracked sourceと設定はformat/lint checkを非対話で実行できる。

## Constraints

- Frontend boundaryは[ADR-0001](../../decisions/0001-adopt-swiftui-appkit-frontend.md)に従う。
- Runtime identityとdeployment baselineは[ADR-0008](../../decisions/0008-stable-dev-runtime-identity.md)に従う。
- minimum deployment targetはmacOS 14.0、Swift language modeは6、Rustはrepository-pinned
  1.98.0 toolchainとする。
- Local smoke buildはcode signingを要求しない。
- Xcode project/workspaceはcommitし、生成toolをclean checkoutの前提にしない。
- Issue #2はopenだが、利用者の明示的なordering overrideにより#3を先行する。

## Acceptance criteria

- `AC-01`: clean checkout相当の生成物がない状態からdocumented commandでStableとDevをbuildでき、
  それぞれ正しい`.app` bundleが生成される。
- `AC-02`: Stable/Devのbundle ID、display name、preferences domain、Application Support directoryが
  異なり、`open -n`で同時起動できる。
- `AC-03`: Rust workspace unit testとSwift unit testがlocal commandおよびCI workflowに含まれる。
- `AC-04`: Swift unit testとapp初期画面の両方で`clair_core_smoke()`の期待値を確認できる。
- `AC-05`: GitHub ActionsがStable/Dev unsigned smoke build、test、lint、metadata checkを実行する。
- `AC-06`: Cargo、Xcode、DerivedData、generated outputが`.gitignore`とtracked-file guardで
  commit対象から除外される。
- `AC-07`: `make doctor/build-stable/build-dev/run-stable/run-dev/test/lint/smoke`がREADMEとrunbookに
  記載され、失敗時にdiagnosticを返す。
- `AC-08`: `clair-ptyhost --smoke`が雛形のversioned success responseを返す。

## Out of scope

- Stable/Devの正式icon差分はbranding projectで扱う。今projectではdisplay nameとbundle identityで
  Dock上のprocessを区別する。
- Release archive、Developer ID signing、notarization、update feedはdistribution projectで扱う。
- Rust coreの実domain移管とPTY protocolは後続issueで扱う。

## Assumptions

- `Diwamoto/clair` repository ownershipに対応するreverse-DNS prefixとして`com.diwamoto`を使える。
- 利用者のMacはmacOS 14.0以降であり、Xcode 16以降を導入できる。
- GitHub-hosted `macos-26` runnerでfull Xcodeとnative Rust toolchainを利用できる。

## Open questions

None.
