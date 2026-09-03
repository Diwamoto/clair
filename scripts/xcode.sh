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

# Use the project directly for command-line builds. The checked-in workspace is
# still available for opening the project in Xcode, while direct project builds
# work reliably with the current Xcode command-line tools.
xcodebuild \
    -project "$repo_root/Clair.xcodeproj" \
    -scheme "$scheme" \
    -configuration Debug \
    -derivedDataPath "$repo_root/.build/xcode/$derived_data_key" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    "$action"

if [[ "$action" == "build" ]]; then
    case "$scheme" in
        "Clair Stable")
            product_name="Clair.app"
            ;;
        "Clair Dev")
            product_name="Clair Dev.app"
            ;;
        *)
            printf 'xcode: cannot locate the app product for scheme: %s\n' "$scheme" >&2
            exit 2
            ;;
    esac

    cli_path="$repo_root/target/debug/clair"
    bundle_cli_path="$repo_root/.build/xcode/$derived_data_key/Build/Products/Debug/$product_name/Contents/MacOS/clair"
    if [[ ! -x "$cli_path" ]]; then
        printf 'xcode: native CLI is missing: %s\n' "$cli_path" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$bundle_cli_path")"
    install -m 0755 "$cli_path" "$bundle_cli_path"
    printf 'xcode: bundled native CLI: %s\n' "$bundle_cli_path"
fi
