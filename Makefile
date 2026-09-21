SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help doctor dev dev-ios build-mobile-simulator lint-swift lint ci
.PHONY: build mobile-build test test-integration check foundation

help: ## Show the supported development commands.
	@awk 'BEGIN {FS = ":.*## "; printf "Clair development commands:\n"} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

doctor: ## Check full Xcode and Swift format.
	@./scripts/doctor.sh

dev: ## Build and launch the Clair macOS app (Ctrl-C to stop).
	@./scripts/run-dev.sh

dev-ios: ## Build and launch Clair Mobile in an iOS Simulator.
	@./scripts/run-mobile-simulator.sh

build-mobile-simulator: ## Build the Clair Mobile app for iOS Simulator.
	@./scripts/build-mobile-simulator.sh

build: ## Build every Clair core, macOS, mobile, and daemon target.
	@./scripts/foundation.sh build

mobile-build: ## Cross-build the Clair mobile app for the iOS Simulator SDK.
	@./scripts/foundation.sh mobile-build

test: ## Run the fast Clair core and application unit tests.
	@./scripts/foundation.sh test

test-integration: ## Run the slow real-subprocess/PTY/daemon Clair integration tests.
	@./scripts/foundation.sh test-integration

check: ## Validate the Clair package graph and v1 dependency boundary.
	@./scripts/foundation.sh check

foundation: check build test test-integration ## Run the complete Clair foundation lane.

lint-swift: ## Check Swift formatting.
	@swift format lint --recursive --parallel --strict apple

lint: lint-swift ## Run all formatting and static checks.

ci: lint foundation build-mobile-simulator ## Run the checks GitHub Actions runs.
