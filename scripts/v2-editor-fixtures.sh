#!/usr/bin/env bash
# Generate on-disk fixtures for Clair v2 editor tests.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_dir="${CLAIR_EDITOR_FIXTURE_DIR:-$repo_root/.build/v2-editor-fixtures}"
_TMP_BUILD_DIR=""

cleanup_tmp() {
  if [[ -n "$_TMP_BUILD_DIR" && -d "$_TMP_BUILD_DIR" ]]; then
    rm -rf "$_TMP_BUILD_DIR"
  fi
}

trap cleanup_tmp EXIT

usage() {
  printf 'usage: %s <generate|clean|list>\n' "$(basename "$0")" >&2
}

generate() {
  mkdir -p "$fixture_dir"
  _TMP_BUILD_DIR="$(mktemp -d)"

  # Generate via a small SwiftPM executable target so fixture logic stays in one place.
  swift run --package-path "$repo_root/packages/ClairV2Core" \
    --build-path "$_TMP_BUILD_DIR/.build" \
    EditorFixtureGenerator "$fixture_dir"

  printf 'Generated fixtures in %s\n' "$fixture_dir"
}

clean() {
  rm -rf "$fixture_dir"
  printf 'Removed %s\n' "$fixture_dir"
}

list() {
  if [[ -d "$fixture_dir" ]]; then
    ls -lh "$fixture_dir"
  else
    printf 'No fixtures at %s\n' "$fixture_dir"
  fi
}

case "${1:-}" in
  generate)
    generate
    ;;
  clean)
    clean
    ;;
  list)
    list
    ;;
  *)
    usage
    exit 2
    ;;
esac
