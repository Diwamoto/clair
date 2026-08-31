# Design

## Current state

Project開始時点ではproduct docsとaccepted ADRだけがあり、Swift/Rust production workspace、
build command、test、CI workflowは存在しなかった。実装後のlocal machineはmacOS 26.6.2、
Xcode 26.6、Swift 6.3.3、macOS SDK 26.5、Rust 1.98.0を使い、Stable/Dev app build、XCTest、
static analysis、同時起動を検証済みである。実装はtoolchain未導入も`make doctor`で検知する。

[ADR-0001](../../decisions/0001-adopt-swiftui-appkit-frontend.md)により、Swift executableが
application lifecycleを所有し、Rust coreはUI非依存のcontrol planeを公開することがacceptedである。

## Proposed design

```text
Clair.xcworkspace
└── Clair.xcodeproj
    ├── ClairStable target ─┐
    ├── ClairDev target ────┼─ shared SwiftUI sources ─ C ABI ─ libclair_core.a
    └── ClairTests target ──┘

Cargo.toml
├── crates/clair-core       (rlib + staticlib)
└── crates/clair-ptyhost    (binary skeleton)
```

StableとDevはsourceを共有する別application targetとする。各targetはchannel固有xcconfigだけを変え、
同じSwift module、Rust build phase、source fileをcompileする。別targetにすることでXcode product、
bundle metadata、run actionを明示的に分け、configuration overrideに依存した誤起動を避ける。

Xcodeのpre-link Run Script phaseは`scripts/build-rust.sh`を呼び、DebugではCargo debug、Releaseでは
Cargo release profileのnative static libraryを作る。Swift bridging headerはtracked C headerをincludeし、
linkerは対応するCargo output directoryから`libclair_core.a`をlinkする。

Root `Makefile`はthin entrypointに留め、実処理を`scripts/`へ委譲する。CIも`make` targetを使い、
local専用の隠れたcommand divergenceを作らない。

## Components and responsibilities

| Component | Responsibility | Changed interface |
|---|---|---|
| `Clair.xcworkspace` / `Clair.xcodeproj` | Stable、Dev、Swift testのXcode graphとshared scheme | `Clair Stable`, `Clair Dev` schemes |
| `Config/*.xcconfig` | 共通deployment settingとchannel固有identity | bundle ID、product name、compile condition |
| `apple/ClairApp` | SwiftUI lifecycle、runtime profile、bootstrap status表示 | `ClairRuntimeProfile`, `RustCore` |
| `apple/ClairTests` | profile、data path、Rust FFIのSwift側contract test | Xcode test bundle |
| `crates/clair-core` | UI非依存coreと最小C ABI | `clair_core_smoke() -> uint32_t` |
| `crates/clair-ptyhost` | 後続PTY hostのbinary/process雛形 | `clair-ptyhost --smoke` |
| `include/clair_core.h` | Swift/C consumer向けtracked ABI declaration | C header |
| `scripts/` + `Makefile` | doctor、build、run、test、lint、smoke orchestration | documented developer commands |
| `.github/workflows/native-smoke.yml` | clean macOS runnerで同じcomplete checks | pull request / push CI |
| `THIRD_PARTY_NOTICES.md` | shipped third-party code noticeの正本 | notice placement contract |

## Data and control flow

1. DeveloperまたはCIが`make build-dev`等を実行する。
2. `doctor`がfull Xcode、Swift、Cargo、rustfmt、Clippyを検査する。
3. `xcodebuild`がselected app targetをbuildし、Run Script phaseがCargo static libraryを先に作る。
4. Swift linkerが`libclair_core.a`と`clair_core_smoke` C symbolを解決する。
5. App launch時にcompile conditionからimmutable runtime profileを選ぶ。
6. Profile固有Application Support directoryを作り、Rust smoke valueとともにbootstrap statusを表示する。
7. `make smoke`は両appを別DerivedData rootへbuildし、bundle metadata、binary、Rust symbol、
   ignored artifactを非対話で検証する。

## Interfaces and contracts

### Runtime profiles

| Channel | Bundle ID | Product/display name | Application Support | Swift condition |
|---|---|---|---|---|
| Stable | `com.diwamoto.clair` | `Clair` | `Clair` | `CLAIR_STABLE` |
| Dev | `com.diwamoto.clair.dev` | `Clair Dev` | `Clair Dev` | `CLAIR_DEV` |

Exactly one channel compile condition must be present. Unknown or simultaneous conditions are a compile-time error.
Standard `UserDefaults` is used without a shared suite, so the bundle ID remains the preferences domain.

### Rust smoke ABI

```c
uint32_t clair_core_smoke(void);
```

The function returns the constant `0x434C4149` (`CLAI`). It does not allocate, retain pointers, mutate global
state, panic, call back into Swift, or cross a thread boundary. Any future ABI is added separately and must not
change this symbol's signature or meaning silently.

### Build outputs

- Cargo output: `target/`
- Stable DerivedData: `.build/xcode/stable/`
- Dev DerivedData: `.build/xcode/dev/`
- Test DerivedData: `.build/xcode/tests/`
- Locally generated intermediate files: `.build/generated/`
- Tracked manually maintained C ABI headers: `include/`
- Third-party notice source of truth: `THIRD_PARTY_NOTICES.md`

## State, persistence, and migration

The app creates only its channel-specific Application Support directory. No schema or user record is written in
this bootstrap. There is no migration from ccedit and no Stable/Dev sharing. Changing a bundle ID or directory name
after persistent schemas exist requires a new migration decision; this project performs no cleanup or rename.

## Failure handling and recovery

- `doctor` exits before build with the missing executable/component and installation guidance.
- Rust build failure stops Xcode linking and preserves Cargo diagnostics.
- An unavailable Application Support location or directory-creation failure is captured as a visible bootstrap
  error; the app neither invents a manual `~/Library/Application Support` path nor falls back to the other channel's
  directory.
- Smoke metadata mismatch exits non-zero and prints the expected and actual value.
- All build outputs are disposable. Recovery is to remove only the documented `.build/` and `target/` directories
  and rebuild; scripts do not delete user data.

## Security and privacy

The bootstrap app is unsigned for local/CI smoke builds and disables App Sandbox because the eventual IDE must open
user-selected development trees and spawn tooling. It opens no network listener, reads no secrets, launches no shell,
and persists no content beyond an empty channel-specific Application Support directory. Signing, hardened runtime,
entitlements, and notarization require a later distribution decision.

## Observability

The initial window exposes channel, bundle ID, resolved data directory, and Rust smoke status. CLI commands retain
underlying diagnostics. `clair-ptyhost --smoke` prints a stable single-line response suitable for CI.

## Test strategy

- Rust unit tests validate the library smoke constant and `clair-ptyhost` response construction.
- Swift unit tests validate both profile definitions, distinct identities/paths, and the linked Rust smoke call.
- A Command Line Tools smoke compiles Stable and Dev Swift executables against the Rust static library, validating
  both runtime profiles and the real C ABI without substituting for the Xcode app tests.
- A second Command Line Tools smoke links the complete SwiftUI source graph for both channel conditions and verifies
  that each Mach-O executable contains the Rust smoke symbol.
- Shell smoke checks build both app bundles, inspect `Info.plist`, verify executables and C symbol linkage, and confirm
  generated outputs are ignored. On Xcode 26 Debug builds, the linkage check follows the generated `*.debug.dylib`
  image when the main executable is the Xcode debug stub.
- `xcodebuild analyze`, `swift format lint`, `cargo fmt --check`, and Clippy cover static checks.
- Manual verification launches both bundles with `open -n`, confirms two Dock processes/windows, then inspects their
  displayed identity and data directory.

## Options considered

### Option A: Committed Xcode project with two app targets

- Advantages: clean checkout needs no project generator; products and schemes make Stable/Dev identity explicit;
  normal Xcode UI and `xcodebuild` use the same graph.
- Disadvantages: shared files appear in multiple targets and `project.pbxproj` must be reviewed carefully.
- Evidence: issue #3 explicitly requires an Xcode workspace and separately launchable app bundles.

### Option B: One app target with channel build configurations

- Advantages: smaller target graph and one product definition.
- Disadvantages: product name, output path, test host, and run action depend on configuration selection; accidental
  Stable/Dev identity mixing is easier.
- Evidence: channel identity is a primary acceptance boundary, not a release-only flag.

### Option C: Generate the Xcode project with a third-party tool

- Advantages: declarative project file and less handwritten PBX syntax.
- Disadvantages: introduces a bootstrap dependency before the app has any third-party dependency policy or cache.
- Evidence: the initial graph is small enough to keep a committed project readable.

### Option D: UniFFI for the first smoke call

- Advantages: establishes a future typed binding generator immediately.
- Disadvantages: generated Swift support and dependency setup are disproportionate for a constant, ownership-free
  smoke function.
- Evidence: ADR-0001 explicitly allows C ABI where appropriate; the first contract is synchronous and scalar-only.

## Decision and rationale

Use a committed Xcode workspace/project with two app targets sharing sources, a Cargo workspace with a tracked minimal
C ABI, and root scripts used by both local development and CI. This is the smallest graph that exercises the accepted
Swift-owned lifecycle and Rust-core boundary while making Stable/Dev isolation observable and hard to configure
accidentally.

## Risks and mitigations

| Risk | Impact | Mitigation or exit condition |
|---|---|---|
| Hand-maintained PBX graph drifts | Xcode load/build failure | shared schemes, `plutil` syntax check, and clean CI build |
| Rust archive architecture differs from Xcode | linker failure | build native architecture inside each target and smoke both schemes |
| Runtime identity is later changed for signing | preferences/data migration | central xcconfig/profile values and ADR revisit condition |
| Local machine lacks full Xcode or Rust | local complete check unavailable | actionable `doctor`; pinned Rust 1.98.0; clean `macos-26` CI; record local gap explicitly |
| Dev writes Stable data | dogfooding corruption | compile-time profile, distinct bundle IDs/directories, tests, no fallback |

## Rollout and rollback

There is no existing binary or persistent state to migrate. Land the workspace as one foundation slice. Rollback removes
only repository files and disposable build output; it does not touch `~/Library/Application Support` or preferences.

## Documentation impact

- Add current-state `docs/architecture/development-workspace.md`.
- Add `docs/runbooks/local-development.md`.
- Add root README quick start and artifact/notice conventions.
- Record runtime identity in [ADR-0008](../../decisions/0008-stable-dev-runtime-identity.md).

## Open questions

None.
