#!/usr/bin/env bash
# Usage: make-app-icon.sh NAME.icon RESOURCES_DIR — compiles an Icon Composer .icon (Liquid Glass) into
# NAME.icns (pre-macOS-26 fallback) + Assets.car in RESOURCES_DIR. Info.plist needs CFBundleIconFile/Name = NAME.
set -euo pipefail
icon="$1" res="$2" name="$(basename "$1" .icon)" out="$(mktemp -d)"
xcrun actool "$icon" --compile "$out" --output-format human-readable-text --errors --warnings \
  --platform macosx --minimum-deployment-target 14.0 --app-icon "$name" --output-partial-info-plist "$out/p.plist" >/dev/null
cp "$out/$name.icns" "$out/Assets.car" "$res/"
rm -rf "$out"
