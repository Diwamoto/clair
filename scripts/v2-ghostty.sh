#!/usr/bin/env bash
# Manage the pinned libghostty / GhosttyKit vendor artifact for Clair v2.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pin_path="$repo_root/Config/ghostty-pin.json"
vendor_dir="$repo_root/packages/ClairV2Core/Vendor/ghostty"
framework_path="$vendor_dir/GhosttyKit.xcframework"

usage() {
  printf 'usage: %s <status|verify|vendor|clean>\n' "$(basename "$0")" >&2
}

require_pin() {
  if [[ ! -f "$pin_path" ]]; then
    printf 'ghostty-pin: missing pin manifest at %s\n' "$pin_path" >&2
    return 1
  fi
}

pin_value() {
  python3 - "$pin_path" "$1" <<'PY'
import json, sys
obj = json.load(open(sys.argv[1]))
for key in sys.argv[2].split('.'):
    obj = obj[key]
print(obj)
PY
}

status() {
  require_pin
  if [[ -d "$framework_path" ]]; then
    printf 'present: %s\n' "$framework_path"
    # TODO: verify the embedded Info.plist matches the pin commit/version.
  else
    printf 'absent: %s (run "%s vendor")\n' "$framework_path" "$(basename "$0")" >&2
    return 2
  fi
}

verify() {
  require_pin
  local errors=0

  if ! python3 - "$pin_path" <<'PY' 2>/dev/null; then
import json
json.load(open(__import__('sys').argv[1]))
PY
    printf 'verify: pin manifest is not valid JSON\n' >&2
    errors=$((errors + 1))
  fi

  if [[ ! -d "$framework_path" ]]; then
    printf 'verify: framework absent (expected at %s)\n' "$framework_path" >&2
    errors=$((errors + 1))
  fi

  # TODO: verify upstream LICENSE text, commit SHA, and ABI subset header.

  if [[ $errors -gt 0 ]]; then
    return 1
  fi
  printf 'verify: pin manifest and framework layout OK\n'
}

vendor() {
  require_pin
  mkdir -p "$vendor_dir"

  local upstream commit zig_version zig_url zig_sha
  upstream="$(pin_value upstream)"
  commit="$(pin_value commit)"
  zig_version="$(pin_value toolchain.version)"
  zig_url="$(pin_value toolchain.archive_url)"
  zig_sha="$(pin_value toolchain.archive_sha256)"

  if [[ "$zig_sha" == "0000000000000000000000000000000000000000000000000000000000000000" ]]; then
    printf 'vendor: toolchain archive SHA256 is a placeholder; update %s with the real digest.\n' "$pin_path" >&2
    return 1
  fi

  printf 'vendor: upstream=%s commit=%s zig=%s\n' "$upstream" "$commit" "$zig_version"
  printf 'vendor: this operation fetches and builds libghostty. It is intentionally not silent.\n'

  # TODO: fetch Zig, verify digest, clone Ghostty at pinned commit, build
  # GhosttyKit.xcframework for macOS/iOS/simulator, stage terminfo/resources,
  # and capture LICENSE/THIRD_PARTY_NOTICES.md entry.

  printf 'vendor: not yet implemented; placeholder artifact remains absent.\n' >&2
  return 1
}

clean() {
  rm -rf "$vendor_dir"
  printf 'clean: removed %s\n' "$vendor_dir"
}

case "${1:-}" in
  status)
    status
    ;;
  verify)
    verify
    ;;
  vendor)
    vendor
    ;;
  clean)
    clean
    ;;
  *)
    usage
    exit 2
    ;;
esac
