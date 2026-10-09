#!/usr/bin/env bash
# Builds the Stable Clair.app, signs its update manifest and publishes both to the Diwamoto/clair
# GitHub Release that installed apps poll (ADR-0009, docs/runbooks/release.md).
# CI-agnostic: .github/workflows/release.yml runs it on a v* tag push, but any
# macOS arm64 host with the inputs below can run it too.
#
#   CLAIR_UPDATE_PRIVATE_KEY  Ed25519 signing key (base64); must match config/update-public-key
#   GH_TOKEN                  token that can push tags and create releases on Diwamoto/clair
#
# `--dry-run` builds, smoke-launches, packages and signs into .build/release without tagging or publishing.
# `--rc` builds "Clair RC" from HEAD instead (version VERSION.<commit count>) and replaces the rolling
# `rc` prerelease that installed RC apps poll; it never touches the Stable `--latest` release.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
repo="Diwamoto/clair"
publish=1 channel=stable
for arg in "$@"; do
  case "$arg" in
    --dry-run) publish=0 ;;
    --rc) channel=rc ;;
    *) printf 'release: unknown option %s\n' "$arg" >&2; exit 2 ;;
  esac
done

die() { printf 'release: %s\n' "$*" >&2; exit 1; }

version="$(tr -d '[:space:]' <VERSION)"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){0,3}$ ]] || die "VERSION must be <major>[.<minor>[.<patch>[.<rev>]]], got '$version'"
if [[ "$channel" == rc ]]; then
  # The commit count on main only grows, so every RC is newer than the last one (needs full history).
  [[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "an RC needs a VERSION of at most three parts, got '$version'"
  version="$version.$(git rev-list --count HEAD)"
  tag="rc" name="Clair RC" bundle_id="com.diwamoto.clair.rc" icon="AppIconRC"
  notes="RC $version from $(git rev-parse --short HEAD): $(git log -1 --format=%s)"
else
  tag="v$version" name="Clair" bundle_id="com.diwamoto.clair" icon="AppIcon"
  # A tag-triggered run must build the commit whose VERSION matches the tag.
  [[ "${GITHUB_REF_TYPE:-}" != tag || "${GITHUB_REF_NAME:-}" == "$tag" ]] ||
    die "tag ${GITHUB_REF_NAME:-} does not match VERSION ($tag)"
  if ((publish)) && gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    printf 'release: %s is already published on %s; bump VERSION to release again\n' "$tag" "$repo"
    exit 0
  fi
  # Release notes are the CHANGELOG.md section for this version (Keep a Changelog; written by the clair-release skill).
  notes="$(awk -v h="## [$version]" 'index($0, "## [") == 1 { f = (index($0, h) == 1); next } f' CHANGELOG.md)"
  [[ -n "${notes//[[:space:]]/}" ]] || die "CHANGELOG.md has no '## [$version]' section"
fi
[[ -n "${CLAIR_UPDATE_PRIVATE_KEY:-}" ]] || die "CLAIR_UPDATE_PRIVATE_KEY is not set"
public_key="$(tr -d '[:space:]' <config/update-public-key)"
[[ -f packages/Vendor/ghostty/GhosttyKit.xcframework/Info.plist ]] ||
  die "libghostty is not vendored (run scripts/ghostty.sh vendor); a release without it has no terminal"

pkg="."
printf 'release: building %s (release)...\n' "$tag"
for product in ClairMacApp ClairDaemon clair; do
  swift build -c release --package-path "$pkg" --product "$product"
done
bin="$(swift build -c release --package-path "$pkg" --show-bin-path)"

out="$repo_root/.build/release"
app="$out/$name.app"
rm -rf "$out"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# ClairDaemonLauncher finds the daemon and `clair` next to the app executable.
cp "$bin/ClairMacApp" "$bin/ClairDaemon" "$bin/clair" "$app/Contents/MacOS/"
# ponytail: SwiftPM's generated Bundle.module only looks at the .app root, so the resource bundles live
# there and the bundle cannot be sealed by codesign. Move them to Contents/Resources (custom accessor
# or an Xcode app target) when Developer ID signing/notarization is adopted.
for bundle in "$bin"/*.bundle; do [[ -e "$bundle" ]] && cp -R "$bundle" "$app/"; done
scripts/make-app-icon.sh "apps/mac/ClairMacApp/$icon.icon" "$app/Contents/Resources"
cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ClairMacApp</string>
  <key>CFBundleIdentifier</key><string>${bundle_id}</string>
  <key>CFBundleName</key><string>${name}</string>
  <key>CFBundleIconFile</key><string>${icon}</string>
  <key>CFBundleIconName</key><string>${icon}</string>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>Text</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>public.text</string><string>public.data</string></array>
  </dict></array>
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

# Ad-hoc signature: UNUserNotificationCenter ties its authorization/registration to the
# bundle's code identity, same as the dev build (scripts/run-dev.sh). --deep also seals the
# copied *.bundle resources above. Developer ID signing/notarization stays deferred (ADR-0008/0009).
codesign --force --deep --sign - "$app"

# Smoke: the shipped bundle must reach a first frame (a missing resource bundle is a launch-time crash).
# Throwaway HOME so it never touches the host's Stable workspace, daemon or update state.
smoke_home="$(mktemp -d)"
trap 'rm -rf "$smoke_home"' EXIT
first_frame="$(CLAIR_STARTUP_TRACE=exit CLAIR_STARTUP_TIMEOUT=60 CLAIR_CHANNEL="$channel" HOME="$smoke_home" \
  "$app/Contents/MacOS/ClairMacApp" 2>/dev/null | sed -n 's/^clair\.startup\.first_frame_ms=//p' | tail -n 1)" || true
[[ -n "$first_frame" ]] || die "the packaged app did not reach a first frame"
printf 'release: smoke launch reached first frame in %s ms\n' "$first_frame"

asset="${name// /-}-${version}-macos-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/$asset"
CLAIR_UPDATE_CHANNEL="$channel" xcrun swift scripts/generate-update-manifest.swift \
  --version "$version" \
  --private-key-env CLAIR_UPDATE_PRIVATE_KEY \
  --public-key "$public_key" \
  --output "$out/latest.json" \
  --notes "${name} ${version}" \
  --artifact arm64 "https://github.com/${repo}/releases/download/${tag}/${asset}" "$out/$asset"
printf 'release: packaged %s and latest.json in %s\n' "$asset" "$out"
((publish)) || exit 0

commit="$(git rev-parse HEAD)"
if [[ "$channel" == rc ]]; then
  # One rolling prerelease: replace the previous RC (and its tag) with this commit's build.
  gh release delete rc --repo "$repo" --cleanup-tag --yes 2>/dev/null || true
  gh release create rc "$out/$asset" "$out/latest.json" --repo "$repo" --target "$commit" \
    --notes "$notes" --title "$name $version" --prerelease --latest=false
  printf 'release: published https://github.com/%s/releases/tag/rc\n' "$repo"
  exit 0
fi
if ! git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null; then
  git tag "$tag" "$commit"
  git push origin "refs/tags/$tag"
fi
gh release create "$tag" "$out/$asset" "$out/latest.json" \
  --repo "$repo" \
  --notes "$notes" \
  --title "Clair ${version}" \
  --latest
printf 'release: published https://github.com/%s/releases/tag/%s\n' "$repo" "$tag"
