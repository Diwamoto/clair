#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

plutil -lint "$repo_root/apple/ClairMobileApp/Info.plist"
xmllint --noout "$repo_root/Clair.xcworkspace/contents.xcworkspacedata"
xmllint --noout \
    "$repo_root/Clair.xcodeproj/xcshareddata/xcschemes/Clair Stable.xcscheme" \
    "$repo_root/Clair.xcodeproj/xcshareddata/xcschemes/Clair Dev.xcscheme" \
    "$repo_root/Clair.xcodeproj/xcshareddata/xcschemes/Clair Mobile.xcscheme"
ruby "$repo_root/scripts/validate-xcode-project.rb"

grep -Fq 'SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) CLAIR_STABLE' "$repo_root/Config/Stable.xcconfig"
grep -Fq 'SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) CLAIR_DEV' "$repo_root/Config/Dev.xcconfig"

printf 'workspace-check: project, schemes, and channel configs are structurally valid.\n'
