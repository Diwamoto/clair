#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_directory="$repo_root/.build/app-link"
module_cache="$repo_root/.build/swift-module-cache"
target_triple="$(uname -m)-apple-macosx14.0"

"$repo_root/scripts/doctor.sh" rust
"$repo_root/scripts/build-rust.sh" Debug

if ! command -v swiftc >/dev/null 2>&1; then
    printf 'app-link: swiftc was not found.\n' >&2
    exit 1
fi

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
    executable="$output_directory/clair-$channel"

    swiftc \
        -parse-as-library \
        -swift-version 6 \
        -warnings-as-errors \
        -target "$target_triple" \
        -D "$condition" \
        -module-cache-path "$module_cache" \
        -import-objc-header "$repo_root/apple/ClairApp/Clair-Bridging-Header.h" \
        -Xcc "-I$repo_root/include" \
        -L "$repo_root/target/debug" \
        -lclair_core \
        "$repo_root/apple/ClairApp/ClairApp.swift" \
        "$repo_root/apple/ClairApp/ClairRuntimeProfile.swift" \
        "$repo_root/apple/ClairApp/RustCore.swift" \
        "$repo_root/apple/ClairApp/BootstrapState.swift" \
        "$repo_root/apple/ClairApp/ProjectModel.swift" \
        "$repo_root/apple/ClairApp/ProjectStore.swift" \
        "$repo_root/apple/ClairApp/CommandRegistry.swift" \
        "$repo_root/apple/ClairApp/ProjectWorkspace.swift" \
        "$repo_root/apple/ClairApp/ContentView.swift" \
        "$repo_root/apple/ClairApp/NativeEditor.swift" \
        "$repo_root/apple/ClairApp/ProjectNavigation.swift" \
        "$repo_root/apple/ClairApp/ProjectGit.swift" \
        "$repo_root/apple/ClairApp/TerminalProtocol.swift" \
        "$repo_root/apple/ClairApp/SessionBroker.swift" \
        "$repo_root/apple/ClairApp/TerminalSession.swift" \
        "$repo_root/apple/ClairApp/TerminalSurface.swift" \
        -o "$executable"

    if ! nm -gU "$executable" | grep -q ' _clair_core_smoke$'; then
        printf 'app-link: Rust smoke symbol is missing from %s.\n' "$executable" >&2
        exit 1
    fi
    if ! vtool -show-build "$executable" | grep -Eq 'minos[[:space:]]+14\.0'; then
        printf 'app-link: %s does not declare minimum macOS 14.0.\n' "$executable" >&2
        exit 1
    fi

    printf 'app-link: %s\n' "$(file "$executable")"
done
