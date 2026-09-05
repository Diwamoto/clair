#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="${CLAIR_MOBILE_DESTINATION:-generic/platform=iOS Simulator}"
derived_data="${CLAIR_MOBILE_DERIVED_DATA:-$repo_root/.build/xcode/mobile-simulator}"

"$repo_root/scripts/doctor.sh" xcode

xcodebuild \
    -project "$repo_root/Clair.xcodeproj" \
    -scheme "Clair Mobile" \
    -configuration Debug \
    -destination "$destination" \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

app_path="$derived_data/Build/Products/Debug-iphonesimulator/Clair Mobile.app"
if [[ ! -d "$app_path" ]]; then
    printf 'mobile-simulator: expected app product is missing: %s\n' "$app_path" >&2
    exit 1
fi

printf 'mobile-simulator: built unsigned app: %s\n' "$app_path"
