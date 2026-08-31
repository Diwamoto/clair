#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${1:-${CONFIGURATION:-Debug}}"

if ! command -v cargo >/dev/null 2>&1; then
    printf 'build-rust: cargo was not found; run make doctor.\n' >&2
    exit 1
fi

case "$configuration" in
    Debug)
        cargo_args=(build -p clair-core --locked)
        ;;
    Release)
        cargo_args=(build -p clair-core --locked --release)
        ;;
    *)
        printf 'build-rust: unsupported Xcode configuration: %s\n' "$configuration" >&2
        exit 2
        ;;
esac

cd "$repo_root"
cargo "${cargo_args[@]}"
