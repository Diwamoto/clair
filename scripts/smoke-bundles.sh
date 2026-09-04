#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

verify_bundle() {
    local app_path="$1"
    local expected_bundle_id="$2"
    local expected_display_name="$3"
    local info_plist="$app_path/Contents/Info.plist"
    local executable="$app_path/Contents/MacOS/$expected_display_name"
    local debug_dylib="$app_path/Contents/MacOS/$expected_display_name.debug.dylib"
    local cli="$app_path/Contents/Resources/clair"

    if [[ ! -f "$info_plist" ]]; then
        printf 'bundle-smoke: missing Info.plist: %s\n' "$info_plist" >&2
        return 1
    fi
    if [[ ! -x "$executable" ]]; then
        printf 'bundle-smoke: missing executable: %s\n' "$executable" >&2
        return 1
    fi
    if [[ ! -x "$cli" ]]; then
        printf 'bundle-smoke: missing native CLI: %s\n' "$cli" >&2
        return 1
    fi
    if [[ "$executable" -ef "$cli" ]]; then
        printf 'bundle-smoke: app executable and native CLI must be separate files: %s\n' "$app_path" >&2
        return 1
    fi
    "$cli" --version >/dev/null

    local actual_bundle_id
    local actual_display_name
    actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
    actual_display_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$info_plist")"

    if [[ "$actual_bundle_id" != "$expected_bundle_id" ]]; then
        printf 'bundle-smoke: expected bundle ID %s, got %s\n' "$expected_bundle_id" "$actual_bundle_id" >&2
        return 1
    fi
    if [[ "$actual_display_name" != "$expected_display_name" ]]; then
        printf 'bundle-smoke: expected display name %s, got %s\n' "$expected_display_name" "$actual_display_name" >&2
        return 1
    fi
    if ! nm -gU "$executable" | grep -q '_clair_core_smoke'; then
        if [[ ! -f "$debug_dylib" ]] || ! nm -gU "$debug_dylib" | grep -q '_clair_core_smoke'; then
            printf 'bundle-smoke: Rust smoke symbol is missing from %s and %s\n' \
                "$executable" "$debug_dylib" >&2
            return 1
        fi
    fi

    printf 'bundle-smoke: %s (%s) is valid.\n' "$expected_display_name" "$expected_bundle_id"
}

verify_bundle \
    "$repo_root/.build/xcode/stable/Build/Products/Debug/Clair.app" \
    "com.diwamoto.clair" \
    "Clair"
verify_bundle \
    "$repo_root/.build/xcode/dev/Build/Products/Debug/Clair Dev.app" \
    "com.diwamoto.clair.dev" \
    "Clair Dev"
