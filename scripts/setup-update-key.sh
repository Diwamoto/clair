#!/usr/bin/env bash
# One-time: create the Stable update signing key (ADR-0009). The private half goes only to the
# login Keychain (backup) and the Diwamoto/clair Actions secret; it is never printed. The public half
# is written to Config/update-public-key, which must be committed. Rotating the key strands every
# installed app on its current version, so run this once and keep the Keychain item.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if security find-generic-password -s clair-update-signing >/dev/null 2>&1; then
  echo "setup-update-key: a clair-update-signing Keychain item already exists; refusing to rotate" >&2
  exit 1
fi
keys="$(xcrun swift "$repo_root/scripts/generate-update-key.swift" 2>/dev/null)"
private_key="$(sed -n 's/^CLAIR_UPDATE_PRIVATE_KEY=//p' <<<"$keys")"
public_key="$(sed -n 's/^CLAIR_UPDATE_PUBLIC_KEY=//p' <<<"$keys")"
unset keys
security add-generic-password -a clair -s clair-update-signing -l "Clair update signing key (Ed25519)" -w "$private_key"
gh secret set CLAIR_UPDATE_PRIVATE_KEY --repo Diwamoto/clair <<<"$private_key"
unset private_key
printf '%s\n' "$public_key" >"$repo_root/Config/update-public-key"
echo "setup-update-key: stored the private key; commit Config/update-public-key"
