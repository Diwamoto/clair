#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

ignored_paths=(
    "target/debug/libclair_core.a"
    ".build/xcode/dev/Build/Products/Debug/Clair Dev.app"
    "DerivedData/Build/Products/Debug/Clair.app"
    "generated/clair_core.swift"
    "Clair.xcodeproj/xcuserdata/example.xcuserdatad/xcschemes/xcschememanagement.plist"
)

for path in "${ignored_paths[@]}"; do
    if ! git check-ignore -q "$path"; then
        printf 'artifact-check: expected ignored path is not ignored: %s\n' "$path" >&2
        exit 1
    fi
done

tracked_artifacts="$(
    git ls-files |
        grep -E '(^|/)(target|\.build|DerivedData|generated)/|(^|/)xcuserdata/' ||
        true
)"

if [[ -n "$tracked_artifacts" ]]; then
    printf 'artifact-check: generated artifacts are tracked:\n%s\n' "$tracked_artifacts" >&2
    exit 1
fi

printf 'artifact-check: generated and user-local outputs are excluded.\n'
