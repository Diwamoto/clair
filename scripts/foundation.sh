#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
core_package="$repo_root"
apps_package="$repo_root"

core_targets=(
  ClairPush
  ClairPushRelay
  ClairShared
  ClairWorkspace
  ClairAgent
  ClairReview
  ClairTerminal
  ClairTransport
  ClairDaemonKit
  ClairMobileKit
  ClairAppKit
)

app_targets=(
  ClairMacApp
  ClairMobileApp
  ClairDaemon
  clair
)

usage() {
  printf 'usage: %s <build|mobile-build|test|test-integration|check|all>\n' "$(basename "$0")" >&2
}

build_core() {
  local target
  for target in "${core_targets[@]}"; do
    swift build --package-path "$core_package" --target "$target"
  done
}

build_apps() {
  local target
  for target in "${app_targets[@]}"; do
    swift build --package-path "$apps_package" --target "$target"
  done
}

build_mobile_simulator() {
  local sdk_path
  sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path)"
  swift build \
    --package-path "$apps_package" \
    --target ClairMobileApp \
    --triple arm64-apple-ios17.0-simulator \
    --sdk "$sdk_path"
}

test_packages() {
  swift test --package-path "$core_package" --parallel --filter ClairCoreTests
  swift test --package-path "$core_package" --parallel --filter ClairDesignSystemTests
  swift test --package-path "$apps_package" --parallel --filter ClairAppsTests
}

test_integration_packages() {
  # --no-parallel: these tests spawn and reap real OS processes/sockets and block their
  # thread on them. Swift Testing otherwise runs suites concurrently on the cooperative
  # pool (one thread per core); on a 3-core CI runner the blocked tests filled the pool and
  # the async bridges they wait on never ran, hanging the job. --num-workers did not cap it.
  swift test --package-path "$core_package" --no-parallel \
    --filter ClairCoreIntegrationTests
}

check_package() {
  local package_path="$1"
  swift package --package-path "$package_path" dump-package >/dev/null
}

check_sources() {
  # grep, not rg: CI runners do not ship ripgrep, and `if rg` on a missing binary silently passed.
  # Match real v1 dependencies (a WebKit editor, libvterm calls), not prose that names them.
  # ClairHTMLPreview.swift is the HTML preview pane, which spec §5.11 / ADR-0018 allow to use WebKit
  # (never the editor's input or rendering path).
  if grep -rnE --include='*.swift' --exclude='ClairHTMLPreview.swift' \
    '^[[:space:]]*import (WebKit|ClairTextKit)$|WKWebView\(|vterm_[a-z_]+\(' \
    "$repo_root/packages" "$repo_root/apps" "$repo_root/Package.swift"; then
    printf 'foundation: v1 runtime dependency found in packages.\n' >&2
    return 1
  fi
}

check() {
  check_package "$repo_root"
  check_sources
  printf 'foundation: package manifests and v1 dependency boundary passed.\n'
}

case "${1:-}" in
  build)
    build_core
    build_apps
    build_mobile_simulator
    ;;
  mobile-build)
    build_mobile_simulator
    ;;
  test)
    test_packages
    ;;
  test-integration)
    test_integration_packages
    ;;
  check)
    check
    ;;
  all)
    check
    build_core
    build_apps
    build_mobile_simulator
    test_packages
    ;;
  *)
    usage
    exit 2
    ;;
esac
