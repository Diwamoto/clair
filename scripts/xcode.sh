#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action="${1:?usage: xcode.sh <build|test|analyze> <scheme> <derived-data-key>}"
scheme="${2:?usage: xcode.sh <build|test|analyze> <scheme> <derived-data-key>}"
derived_data_key="${3:?usage: xcode.sh <build|test|analyze> <scheme> <derived-data-key>}"

"$repo_root/scripts/doctor.sh" all

case "$action" in
    build|test|analyze)
        ;;
    *)
        printf 'xcode: unsupported action: %s\n' "$action" >&2
        exit 2
        ;;
esac

exec xcodebuild \
    -workspace "$repo_root/Clair.xcworkspace" \
    -scheme "$scheme" \
    -configuration Debug \
    -derivedDataPath "$repo_root/.build/xcode/$derived_data_key" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    "$action"
