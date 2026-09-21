#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
core_package="$repo_root/packages/ClairCore"
apps_package="$repo_root/packages/ClairApps"

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
  swift test --package-path "$apps_package" --parallel
}

test_integration_packages() {
  # --num-workers 1: these tests spawn and reap real OS processes/sockets.
  # Swift Testing parallelizes across suites within one process by default
  # regardless of --parallel, and concurrent real waitpid()/socket work from
  # different suites races (observed as ~300s hangs and spurious transport
  # errors) unless capped to one worker.
  swift test --package-path "$core_package" --parallel --num-workers 1 \
    --filter ClairCoreIntegrationTests
}

check_package() {
  local package_path="$1"
  swift package --package-path "$package_path" dump-package >/dev/null
}

check_sources() {
  if rg -n --glob '*.swift' --glob 'Package.swift' \
    'ClairMobileKit|ClairApp|ClairMobileApp|libvterm|CodeMirror|WKWebView|WebView' \
    "$core_package/Sources" "$apps_package/Sources" \
    "$core_package/Package.swift" "$apps_package/Package.swift"; then
    printf 'foundation: v1 runtime dependency found in packages.\n' >&2
    return 1
  fi
}

check() {
  check_package "$core_package"
  check_package "$apps_package"
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
