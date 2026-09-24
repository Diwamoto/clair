#!/usr/bin/env bash
# Builds the Stable Clair.app, signs its update manifest and publishes both to the Diwamoto/clair
# GitHub Release that installed apps poll (ADR-0009, docs/runbooks/release.md).
# CI-agnostic: .github/workflows/release.yml runs it on a push that changes VERSION, but any
# macOS arm64 host with the inputs below can run it too.
#
#   CLAIR_UPDATE_PRIVATE_KEY  Ed25519 signing key (base64); must match Config/update-public-key
#   GH_TOKEN                  token that can push tags and create releases on Diwamoto/clair
#
# `--dry-run` builds, smoke-launches, packages and signs into .build/release without tagging or publishing.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
repo="Diwamoto/clair"
publish=1
[[ "${1:-}" == "--dry-run" ]] && publish=0

die() { printf 'release: %s\n' "$*" >&2; exit 1; }

version="$(tr -d '[:space:]' <VERSION)"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){0,3}$ ]] || die "VERSION must be <major>[.<minor>[.<patch>[.<rev>]]], got '$version'"
tag="v$version"
if ((publish)) && gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  printf 'release: %s is already published on %s; bump VERSION to release again\n' "$tag" "$repo"
  exit 0
fi
[[ -n "${CLAIR_UPDATE_PRIVATE_KEY:-}" ]] || die "CLAIR_UPDATE_PRIVATE_KEY is not set"
public_key="$(tr -d '[:space:]' <Config/update-public-key)"
[[ -f packages/ClairCore/Vendor/ghostty/GhosttyKit.xcframework/Info.plist ]] ||
  die "libghostty is not vendored (run scripts/ghostty.sh vendor); a release without it has no terminal"

pkg="packages/ClairApps"
printf 'release: building %s (release)...\n' "$tag"
for product in ClairMacApp ClairDaemon clair; do
  swift build -c release --package-path "$pkg" --product "$product"
done
bin="$(swift build -c release --package-path "$pkg" --show-bin-path)"

out="$repo_root/.build/release"
app="$out/Clair.app"
rm -rf "$out"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# ClairDaemonLauncher finds the daemon and `clair` next to the app executable.
cp "$bin/ClairMacApp" "$bin/ClairDaemon" "$bin/clair" "$app/Contents/MacOS/"
# ponytail: SwiftPM's generated Bundle.module only looks at the .app root, so the resource bundles live
# there and the bundle cannot be sealed by codesign. Move them to Contents/Resources (custom accessor
# or an Xcode app target) when Developer ID signing/notarization is adopted.
cp -R "$bin"/*.bundle "$app/"
scripts/make-icns.sh "$pkg/Sources/ClairMacApp/Resources/AppIcon.png" "$app/Contents/Resources/AppIcon.icns"
cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ClairMacApp</string>
  <key>CFBundleIdentifier</key><string>com.diwamoto.clair</string>
  <key>CFBundleName</key><string>Clair</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>ClairUpdatePublicKey</key><string>${public_key}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Smoke: the shipped bundle must reach a first frame (a missing resource bundle is a launch-time crash).
# Throwaway HOME so it never touches the host's Stable workspace, daemon or update state.
smoke_home="$(mktemp -d)"
trap 'rm -rf "$smoke_home"' EXIT
first_frame="$(CLAIR_STARTUP_TRACE=exit CLAIR_STARTUP_TIMEOUT=60 CLAIR_CHANNEL=stable HOME="$smoke_home" \
  "$app/Contents/MacOS/ClairMacApp" 2>/dev/null | sed -n 's/^clair\.startup\.first_frame_ms=//p' | tail -n 1)" || true
[[ -n "$first_frame" ]] || die "the packaged app did not reach a first frame"
printf 'release: smoke launch reached first frame in %s ms\n' "$first_frame"

asset="Clair-${version}-macos-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/$asset"
xcrun swift scripts/generate-update-manifest.swift \
  --version "$version" \
  --private-key-env CLAIR_UPDATE_PRIVATE_KEY \
  --public-key "$public_key" \
  --output "$out/latest.json" \
  --notes "Clair ${version}" \
  --artifact arm64 "https://github.com/${repo}/releases/download/${tag}/${asset}" "$out/$asset"
printf 'release: packaged %s and latest.json in %s\n' "$asset" "$out"
((publish)) || exit 0

commit="$(git rev-parse HEAD)"
if ! git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null; then
  git tag "$tag" "$commit"
  git push origin "refs/tags/$tag"
fi
gh release create "$tag" "$out/$asset" "$out/latest.json" \
  --repo "$repo" \
  --generate-notes \
  --title "Clair ${version}" \
  --latest
printf 'release: published https://github.com/%s/releases/tag/%s\n' "$repo" "$tag"
