#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
channel="${1:?usage: run-app.sh <stable|dev>}"

case "$channel" in
    stable)
        app_path="$repo_root/.build/xcode/stable/Build/Products/Debug/Clair.app"
        process_name="Clair"
        ;;
    dev)
        app_path="$repo_root/.build/xcode/dev/Build/Products/Debug/Clair Dev.app"
        process_name="Clair Dev"
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

# Reuse an already-running instance of the same channel. Stable and Dev have
# different process names, so they can still run side-by-side.
if pgrep -x "$process_name" >/dev/null 2>&1; then
    running_pid=$(pgrep -x "$process_name" | head -n 1)
    printf 'run-app: %s is already running (pid %s); activating it.\n' "$channel" "$running_pid"
    exec osascript -e "tell application \"$process_name\" to activate"
fi

printf 'run-app: launching new %s process...\n' "$channel"
exec open -n "$app_path"
