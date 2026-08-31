#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
channel="${1:?usage: run-app.sh <stable|dev>}"

case "$channel" in
    stable)
        app_path="$repo_root/.build/xcode/stable/Build/Products/Debug/Clair.app"
        ;;
    dev)
        app_path="$repo_root/.build/xcode/dev/Build/Products/Debug/Clair Dev.app"
        ;;
    *)
        printf 'run-app: unknown channel: %s\n' "$channel" >&2
        exit 2
        ;;
esac

if [[ ! -d "$app_path" ]]; then
    printf 'run-app: app bundle is missing: %s\n' "$app_path" >&2
    exit 1
fi

exec open -n "$app_path"
