SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help doctor workspace-check build-editor-web build-stable build-dev build-mobile-simulator run-stable run-dev watch-dev
.PHONY: test test-rust test-swift test-mobile lint lint-rust lint-swift analyze
.PHONY: smoke smoke-ffi smoke-app-link smoke-bundles artifact-check ci clean-artifacts

help: ## Show the supported development commands.
	@awk 'BEGIN {FS = ":.*## "; printf "Clair development commands:\n"} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

doctor: ## Check full Xcode, Swift format, Rust, rustfmt, and Clippy.
	@./scripts/doctor.sh all

workspace-check: ## Validate committed Xcode metadata and channel configuration.
	@./scripts/check-workspace.sh

build-editor-web: ## Build and embed the local CodeMirror editor bundle.
	@./scripts/build-editor-web.sh

build-stable: ## Build the unsigned Clair Stable app.
	@./scripts/xcode.sh build "Clair Stable" stable

build-dev: ## Build the unsigned Clair Dev app.
	@./scripts/xcode.sh build "Clair Dev" dev

build-mobile-simulator: ## Build the unsigned Clair Mobile app for iOS Simulator.
	@./scripts/build-mobile-simulator.sh

run-stable: build-stable ## Build and launch a new Clair Stable process.
	@./scripts/run-app.sh stable

run-dev: ## Watch native sources and hot-restart Clair Dev after changes.
	@./scripts/watch-dev.sh

watch-dev: run-dev ## Backward-compatible alias for run-dev.

test-rust: ## Run all Rust workspace unit tests.
	@./scripts/doctor.sh rust
	@cargo test --workspace --locked

test-swift: ## Run Swift unit tests through the Clair Dev host app.
	@./scripts/xcode.sh test "Clair Dev" tests

test-mobile: ## Run the cross-platform mobile protocol package tests.
	@swift test --package-path packages/ClairMobileKit

test: test-rust test-swift test-mobile ## Run Rust, desktop Swift, and mobile protocol tests.

lint-rust: ## Check Rust formatting and run Clippy with warnings denied.
	@./scripts/doctor.sh rust
	@cargo fmt --all -- --check
	@cargo clippy --workspace --all-targets --locked -- -D warnings

lint-swift: ## Check Swift formatting.
	@swift format lint --recursive --parallel --strict apple

analyze: ## Run Xcode static analysis for the shared Dev source graph.
	@./scripts/xcode.sh analyze "Clair Dev" analyze

lint: lint-rust lint-swift analyze workspace-check ## Run all formatting and static checks.

smoke-bundles: build-stable build-dev ## Validate app metadata, binaries, and Rust linkage.
	@./scripts/smoke-bundles.sh

smoke-ffi: ## Compile Stable/Dev Swift-to-Rust CLI smoke executables.
	@./scripts/smoke-swift-rust.sh

smoke-app-link: ## Link Stable/Dev SwiftUI executables against the Rust core.
	@./scripts/smoke-app-link.sh

artifact-check: ## Confirm generated and local outputs are ignored.
	@./scripts/check-ignored-artifacts.sh

smoke: test smoke-ffi smoke-app-link smoke-bundles artifact-check ## Run the complete unsigned local smoke path.

ci: lint smoke build-mobile-simulator ## Run the same complete checks used by GitHub Actions.

clean-artifacts: ## Remove only disposable repository build outputs.
	@./scripts/clean-artifacts.sh
