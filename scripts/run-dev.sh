#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_path="$repo_root/packages/ClairApps"
bin_dir="$package_path/.build/arm64-apple-macosx/debug"

# Dev must never touch Stable's workspace/socket/update state (ADR-0008); `clair` needs the same CLAIR_CHANNEL.
export CLAIR_CHANNEL=dev

daemon_pid=""
app_pid=""

stop_all() {
    trap - INT TERM
    printf '\ndev: stopping Clair...\n'
    if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
        kill -TERM "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
        kill -TERM "$daemon_pid" 2>/dev/null || true
        wait "$daemon_pid" 2>/dev/null || true
    fi
    printf 'dev: stopped\n'
    exit 0
}
trap stop_all INT TERM

printf 'dev: building Clair (daemon + macOS app)...\n'
swift build --package-path "$package_path" --product ClairDaemon
swift build --package-path "$package_path" --product ClairMacApp

daemon_args=()
[[ -n "${CLAIR_DEV_PROJECT_ROOT:-}" ]] && daemon_args+=(--project-root "$CLAIR_DEV_PROJECT_ROOT")
[[ -n "${CLAIR_DEV_OPENCODE_EXECUTABLE:-}" ]] && daemon_args+=(--opencode-executable "$CLAIR_DEV_OPENCODE_EXECUTABLE")

printf 'dev: starting ClairDaemon...\n'
# bash 3.2 (macOS) treats an empty array as unbound under `set -u`, hence the ${arr[@]+...} guard.
"$bin_dir/ClairDaemon" ${daemon_args[@]+"${daemon_args[@]}"} &
daemon_pid=$!

printf 'dev: launching Clair macOS app (Ctrl-C to stop everything)...\n'
"$bin_dir/ClairMacApp" &
app_pid=$!

# Either process exiting on its own also ends the session. (`wait -n` needs
# bash 4.3+; macOS ships bash 3.2, so poll instead.)
while kill -0 "$daemon_pid" 2>/dev/null && kill -0 "$app_pid" 2>/dev/null; do
    sleep 0.5
done
stop_all
