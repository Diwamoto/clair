#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$repo_root/Cargo.toml" || ! -d "$repo_root/Clair.xcworkspace" ]]; then
    printf 'clean-artifacts: refusing to clean an unrecognized repository root: %s\n' "$repo_root" >&2
    exit 1
fi

rm -rf -- "$repo_root/.build" "$repo_root/target"
printf 'clean-artifacts: removed disposable .build and target outputs.\n'
