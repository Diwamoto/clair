SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help doctor dev dev-ios build-mobile-simulator lint-swift lint ci
.PHONY: v2-build v2-mobile-build v2-test v2-test-integration v2-check v2-foundation

help: ## Show the supported development commands.
	@awk 'BEGIN {FS = ":.*## "; printf "Clair development commands:\n"} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

doctor: ## Check full Xcode and Swift format.
	@./scripts/doctor.sh

dev: ## Build and launch the Clair v2 macOS app (Ctrl-C to stop).
	@./scripts/run-v2-dev.sh

dev-ios: ## Build and launch Clair v2 Mobile in an iOS Simulator.
	@./scripts/run-mobile-simulator.sh

build-mobile-simulator: ## Build the Clair v2 Mobile app for iOS Simulator.
	@./scripts/build-mobile-simulator.sh

v2-build: ## Build every Clair v2 core, macOS, mobile, and daemon target.
	@./scripts/v2-foundation.sh build

v2-mobile-build: ## Cross-build the Clair v2 mobile app for the iOS Simulator SDK.
	@./scripts/v2-foundation.sh mobile-build

v2-test: ## Run the fast Clair v2 core and application unit tests.
	@./scripts/v2-foundation.sh test

v2-test-integration: ## Run the slow real-subprocess/PTY/daemon Clair v2 integration tests.
	@./scripts/v2-foundation.sh test-integration

v2-check: ## Validate the Clair v2 package graph and v1 dependency boundary.
	@./scripts/v2-foundation.sh check

v2-foundation: v2-check v2-build v2-test v2-test-integration ## Run the complete Clair v2 foundation lane.

lint-swift: ## Check Swift formatting.
	@swift format lint --recursive --parallel --strict apple

lint: lint-swift ## Run all formatting and static checks.

ci: lint v2-foundation build-mobile-simulator ## Run the checks GitHub Actions runs.
