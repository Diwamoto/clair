# Implementation plan

## Acceptance mapping

| Acceptance criterion | Implementation slices | Validation |
|---|---|---|
| `AC-01` | Slice 1, Slice 2, Slice 3 | `make build-stable build-dev`; app bundle existence |
| `AC-02` | Slice 3, Slice 5 | Swift profile tests; `make smoke`; manual `open -n` check |
| `AC-03` | Slice 2, Slice 3, Slice 4 | `make test`; CI workflow definition |
| `AC-04` | Slice 2, Slice 3 | Rust unit test; Swift FFI test; bootstrap window status |
| `AC-05` | Slice 4 | workflow syntax review and GitHub Actions run after integration |
| `AC-06` | Slice 1, Slice 4 | `make smoke`; `git check-ignore`; tracked artifact guard |
| `AC-07` | Slice 1, Slice 4 | command help/doctor checks; README and runbook link check |
| `AC-08` | Slice 2 | `cargo run -p clair-ptyhost -- --smoke`; unit test |

## Dependencies

- [ADR-0001](../../decisions/0001-adopt-swiftui-appkit-frontend.md) is accepted.
- [ADR-0008](../../decisions/0008-stable-dev-runtime-identity.md) fixes the runtime identity required by this project.
- Issue #2 remains open; the user explicitly authorized issue #3 to proceed first on 2026-08-30.
- A complete local app build requires full Xcode 16+ and Rust stable with `rustfmt` and `clippy`.

## Slice 1: Reproducible workspace and command contract

### Changes

- Add `.gitignore`, `rust-toolchain.toml`, root `Makefile`, doctor/build/test/lint/smoke scripts.
- Add committed Xcode workspace/project graph, shared schemes, and channel xcconfig files.
- Define build output, generated file, and third-party notice locations.

### Validation

- `make help`
- `make doctor` reports missing local prerequisites precisely.
- `plutil -lint Clair.xcodeproj/project.pbxproj` and `xmllint --noout` for workspace/schemes
- `git check-ignore` recognizes representative Cargo, DerivedData, and generated artifacts.

### Completion

- [x] code
- [x] tests
- [x] relevant docs

## Slice 2: Rust core and process skeleton

### Changes

- Add Cargo workspace manifests and pinned toolchain channel/components.
- Implement `clair-core` pure Rust smoke value and ownership-free C ABI export.
- Add tracked C header and `clair-ptyhost --smoke` process skeleton.

### Validation

- `cargo test --workspace`
- `cargo fmt --all -- --check`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo run -p clair-ptyhost -- --smoke`

### Completion

- [x] code
- [x] tests
- [x] relevant docs

## Slice 3: Stable and Dev native app targets

### Changes

- Implement shared SwiftUI lifecycle, bootstrap view, runtime profiles, data directory creation, and Rust wrapper.
- Configure Stable/Dev app targets with separate product names, bundle IDs, compile conditions, and DerivedData roots.
- Add Swift tests for profile isolation, data paths, and Rust smoke link.

### Validation

- `make test-swift`
- `make build-stable build-dev`
- `make smoke-ffi`
- `make smoke-app-link`
- `make smoke-bundles`
- Inspect bootstrap output for both profiles.

### Completion

- [x] code
- [x] tests
- [x] relevant docs

## Slice 4: CI and durable developer guidance

### Changes

- Add GitHub Actions smoke workflow using root commands.
- Add root quick start, architecture current state, local development runbook, and third-party notice source.
- Add tracked-artifact and metadata smoke guards.

### Validation

- `make lint`
- `make test`
- `make smoke`
- Resolve all repository-relative documentation links.
- Review workflow command parity with local runbook.

### Completion

- [x] code
- [x] tests
- [x] relevant docs

## Slice 5: Complete verification and reconciliation

### Changes

- Run complete local checks available on the host.
- With full toolchains, launch Stable and Dev concurrently and confirm identity/data separation.
- Record exact command results and any environment-only gap in the project README.
- Update plan, design, architecture, and runbook to match implemented mechanics.

### Validation

- `make clean-artifacts` followed by `make ci`
- `make run-stable` and `make run-dev`, with both processes visible concurrently.
- `git status --short` and scoped diff review.

### Completion

- [x] code
- [x] tests
- [x] relevant docs

## Final verification

- [x] 全acceptance criteriaにvalidation evidenceがある
- [x] relevant test、build、format、static checkが通る
- [x] regressionまたは既知制約が記録されている
- [x] architectureとrunbookが実装を表している
- [x] issue #3のscoped diffをreviewし、既存のunrelated working-tree changesを変更していない

## Deferred follow-ups

- Formal Stable/Dev icon artwork is deferred to product branding/distribution work.
- Signing, notarization, release archives, and updater integration remain outside issue #3.
- The first GitHub Actions execution is deferred until the reviewed working tree is committed and pushed.
