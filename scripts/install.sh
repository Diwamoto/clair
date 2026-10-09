#!/bin/sh
# Installs (or reinstalls) Clair Stable into /Applications from the latest GitHub Release:
#   curl -fsSL https://raw.githubusercontent.com/Diwamoto/clair/main/scripts/install.sh | sh
# curl leaves no quarantine attribute, so the unnotarized app opens without a Gatekeeper prompt.
# RC (prerelease builds of main, own app "Clair RC"): `... | CLAIR_CHANNEL=rc sh`.
# Later versions arrive through the in-app updater (Ed25519-verified); this is only for the first install.
# ponytail: trusts the TLS-served manifest's sha256 instead of verifying its Ed25519 signature;
# verify with the embedded key if this script ever installs from a mirror.
set -eu
if [ "${CLAIR_CHANNEL:-stable}" = rc ]; then
  name="Clair RC" default_feed="https://github.com/Diwamoto/clair/releases/download/rc/latest.json"
else
  name="Clair" default_feed="https://github.com/Diwamoto/clair/releases/latest/download/latest.json"
fi
feed="${CLAIR_INSTALL_FEED:-$default_feed}"
dest="${CLAIR_INSTALL_DIR:-/Applications}"
app="$dest/$name.app"

fail() { echo "clair-install: $*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || fail "Clair runs on macOS only"
[ "$(uname -m)" = arm64 ] || fail "Clair releases are built for Apple Silicon (arm64) only"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$feed" -o "$tmp/latest.json" || fail "could not download $feed"
field() { plutil -extract "$1" raw -o - "$tmp/latest.json" 2>/dev/null || fail "latest.json has no $1"; }
version="$(field version)"
[ "$(field artifacts.0.architecture)" = arm64 ] || fail "latest.json has no arm64 build"
url="$(field artifacts.0.url)"
sha="$(field artifacts.0.sha256)"

echo "clair-install: downloading $name $version"
curl -fL --progress-bar "$url" -o "$tmp/Clair.zip" || fail "could not download $url"
echo "$sha  $tmp/Clair.zip" | shasum -a 256 -c - >/dev/null 2>&1 || fail "checksum mismatch; not installing"
ditto -x -k "$tmp/Clair.zip" "$tmp/unpacked"
[ -d "$tmp/unpacked/$name.app" ] || fail "the archive has no $name.app"

if osascript -e "application \"$name\" is running" 2>/dev/null | grep -q true; then
  echo "clair-install: quitting the running $name"
  osascript -e "quit app \"$name\"" >/dev/null 2>&1 || true
  sleep 2
fi
rm -rf "$app"
ditto "$tmp/unpacked/$name.app" "$app"
xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
echo "clair-install: installed $name $version to $app"
[ -n "${CLAIR_INSTALL_NO_OPEN:-}" ] || open "$app"
