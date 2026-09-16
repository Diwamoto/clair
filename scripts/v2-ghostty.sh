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

cache_dir="$repo_root/.cache/v2-ghostty"

# Downloads $2 to $3 (if not already present with the right digest) and
# verifies its SHA-256 against $1. Fails closed: a mismatch removes the
# partial download and returns non-zero rather than continuing with an
# unverified artifact.
fetch_and_verify() {
  local expected_sha="$1" url="$2" dest="$3"
  if [[ -f "$dest" ]]; then
    local existing_sha
    existing_sha="$(shasum -a 256 "$dest" | awk '{print $1}')"
    if [[ "$existing_sha" == "$expected_sha" ]]; then
      return 0
    fi
    printf 'vendor: cached %s has wrong digest, re-fetching\n' "$dest" >&2
    rm -f "$dest"
  fi
  mkdir -p "$(dirname "$dest")"
  printf 'vendor: fetching %s\n' "$url"
  curl -fL --max-time 120 -o "$dest" "$url"
  local got_sha
  got_sha="$(shasum -a 256 "$dest" | awk '{print $1}')"
  if [[ "$got_sha" != "$expected_sha" ]]; then
    printf 'vendor: SHA-256 mismatch for %s\n  expected: %s\n  got:      %s\n' \
      "$url" "$expected_sha" "$got_sha" >&2
    rm -f "$dest"
    return 1
  fi
}

vendor() {
  require_pin
  mkdir -p "$vendor_dir" "$cache_dir"

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

  # --- 1. Pinned Zig toolchain: fetch + verify digest, never trust PATH. ---
  local zig_archive="$cache_dir/zig-${zig_version}.tar.xz"
  local zig_extract_dir="$cache_dir/zig-${zig_version}"
  fetch_and_verify "$zig_sha" "$zig_url" "$zig_archive"
  if [[ ! -x "$zig_extract_dir/zig" ]]; then
    rm -rf "$zig_extract_dir"
    mkdir -p "$zig_extract_dir"
    tar -xJf "$zig_archive" -C "$zig_extract_dir" --strip-components=1
  fi
  local zig_bin="$zig_extract_dir/zig"
  local reported_zig_version
  reported_zig_version="$("$zig_bin" version)"
  if [[ "$reported_zig_version" != "$zig_version" ]]; then
    printf 'vendor: fetched zig reports version %s, pin expects %s\n' \
      "$reported_zig_version" "$zig_version" >&2
    return 1
  fi

  # --- 2. Ghostty source at the pinned commit, verified after checkout. ---
  local src_dir="$cache_dir/ghostty-src"
  if [[ ! -d "$src_dir/.git" ]]; then
    rm -rf "$src_dir"
    git clone --filter=blob:none "$upstream" "$src_dir"
  fi
  git -C "$src_dir" fetch --quiet origin "$commit" || true
  git -C "$src_dir" checkout --quiet "$commit"
  local checked_out_commit
  checked_out_commit="$(git -C "$src_dir" rev-parse HEAD)"
  if [[ "$checked_out_commit" != "$commit" ]]; then
    printf 'vendor: checked out %s, pin expects %s\n' "$checked_out_commit" "$commit" >&2
    return 1
  fi

  # --- 3. License verification: fail closed if it stops being MIT. ---
  local license_path="$src_dir/LICENSE"
  local pin_license pin_copyright
  pin_license="$(pin_value license)"
  pin_copyright="$(pin_value copyright)"
  if [[ ! -f "$license_path" ]]; then
    printf 'vendor: upstream LICENSE missing at %s\n' "$license_path" >&2
    return 1
  fi
  if [[ "$pin_license" == "MIT" ]] && ! grep -qi "MIT License" "$license_path"; then
    printf 'vendor: upstream LICENSE does not look like MIT; pin claims %s\n' "$pin_license" >&2
    return 1
  fi
  if ! grep -qF "$pin_copyright" "$license_path"; then
    printf 'vendor: upstream LICENSE does not contain the pinned copyright line:\n  %s\n' \
      "$pin_copyright" >&2
    return 1
  fi
  cp "$license_path" "$vendor_dir/LICENSE-ghostty"

  # --- 4. Build. This task (T08) verified only the native macos-arm64
  # slice end to end; the macOS x86_64 half of the universal slice and both
  # iOS slices are deferred to T05 (see ghostty-pin.json's
  # vendored_slices_note). `-Demit-macos-app=false` skips the full macOS
  # app/xcodebuild bundle, which this vendor step does not need. Building
  # the xcframework requires Apple's Metal shader compiler
  # (`xcrun -sdk macosx metal`); if the local Xcode install has not
  # downloaded the Metal Toolchain component, this fails with an actionable
  # message telling the operator to run
  # `xcodebuild -downloadComponent MetalToolchain` once.
  (
    cd "$src_dir"
    "$zig_bin" build \
      -Doptimize=ReleaseFast \
      -Dapp-runtime=none \
      -Demit-xcframework=true \
      -Dxcframework-target=native \
      -Demit-macos-app=false
  )

  local built_framework="$src_dir/macos/GhosttyKit.xcframework"
  if [[ ! -f "$built_framework/Info.plist" ]]; then
    printf 'vendor: build finished but %s/Info.plist is missing\n' "$built_framework" >&2
    return 1
  fi

  rm -rf "$framework_path"
  cp -R "$built_framework" "$framework_path"
  mkdir -p "$vendor_dir/include"
  cp "$src_dir/include/ghostty.h" "$vendor_dir/include/ghostty.h"

  printf 'vendor: GhosttyKit.xcframework materialized at %s\n' "$framework_path"
  printf 'vendor: done (macos-arm64 slice only; see vendored_slices_note in %s)\n' "$pin_path"
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
