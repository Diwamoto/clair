#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_directory="$repo_root/.build/smoke"
module_cache="$repo_root/.build/swift-module-cache"

"$repo_root/scripts/doctor.sh" rust
"$repo_root/scripts/build-rust.sh" Debug

mkdir -p "$output_directory" "$module_cache"

for channel in stable dev; do
    case "$channel" in
        stable)
            condition="CLAIR_STABLE"
            ;;
        dev)
            condition="CLAIR_DEV"
            ;;
    esac
    executable="$output_directory/swift-rust-$channel"

    swiftc \
        -parse-as-library \
        -swift-version 6 \
        -warnings-as-errors \
        -D "$condition" \
        -module-cache-path "$module_cache" \
        -import-objc-header "$repo_root/apple/ClairApp/Clair-Bridging-Header.h" \
        -Xcc "-I$repo_root/include" \
        -L "$repo_root/target/debug" \
        -lclair_core \
        "$repo_root/apple/ClairApp/ClairRuntimeProfile.swift" \
        "$repo_root/apple/ClairApp/RustCore.swift" \
        "$repo_root/apple/ClairApp/BootstrapState.swift" \
        "$repo_root/apple/Smoke/SwiftRustSmoke.swift" \
        -o "$executable"

    "$executable"
done
