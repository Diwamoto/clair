#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
process_name="Clair Dev"
poll_interval="${CLAIR_WATCH_INTERVAL:-1}"
# PID of the Clair Dev process this watcher launched. The watcher shares its
# lifecycle: when this process exits outside a hot restart, the watcher stops.
app_pid=""

watch_paths=(
    "$repo_root/apple"
    "$repo_root/crates"
    "$repo_root/include"
    "$repo_root/Config"
    "$repo_root/Clair.xcodeproj"
    "$repo_root/Clair.xcworkspace"
    "$repo_root/Cargo.toml"
    "$repo_root/Cargo.lock"
    "$repo_root/rust-toolchain.toml"
    "$repo_root/scripts/build-rust.sh"
    "$repo_root/scripts/build-vterm.sh"
    "$repo_root/scripts/agent-hook.sh"
)

case "$poll_interval" in
    ''|*[!0-9.]* )
        printf 'watch-dev: CLAIR_WATCH_INTERVAL must be a number of seconds\n' >&2
        exit 2
        ;;
esac

snapshot() {
    local path
    local file

    for path in "${watch_paths[@]}"; do
        if [[ -d "$path" ]]; then
            while IFS= read -r -d '' file; do
                stat -f '%m %z %N' "$file"
            done < <(find "$path" -type f -print0)
        elif [[ -f "$path" ]]; then
            stat -f '%m %z %N' "$path"
        fi
    done | LC_ALL=C sort
}

quit_running_dev() {
    if ! pgrep -x "$process_name" >/dev/null 2>&1; then
        return 0
    fi

    printf 'watch-dev: stopping the running %s...\n' "$process_name"
    if ! osascript -e 'tell application "Clair Dev" to quit' >/dev/null 2>&1; then
        printf 'watch-dev: could not ask %s to quit\n' "$process_name" >&2
        return 1
    fi

    for _ in $(seq 1 50); do
        if ! pgrep -x "$process_name" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.2
    done

    printf 'watch-dev: %s did not exit within 10 seconds\n' "$process_name" >&2
    return 1
}

dev_broker_socket_pattern="/Clair Dev/session-broker-v1.sock"

dev_broker_pid() {
    local pid candidates

    candidates="$(pgrep -f 'clair-ptyhost --broker' 2>/dev/null || true)"
    for pid in $candidates; do
        if ps -o command= -p "$pid" 2>/dev/null | grep -qF "$dev_broker_socket_pattern"; then
            printf '%s\n' "$pid"
            return 0
        fi
    done
    return 1
}

descendant_pids() {
    local frontier="$1"
    local all="" children pid

    while [[ -n "$frontier" ]]; do
        children=""
        for pid in $frontier; do
            children="$children $(pgrep -P "$pid" 2>/dev/null || true)"
        done
        children="$(printf '%s\n' $children | awk 'NF')"
        if [[ -n "$children" ]]; then
            all="$all
$children"
        fi
        frontier="$children"
    done

    printf '%s\n' $all | awk 'NF' | sort -un
}

cleanup_dev_broker_sessions() {
    local broker_pid pids remaining pid

    broker_pid="$(dev_broker_pid || true)"
    if [[ -z "$broker_pid" ]]; then
        return 0
    fi

    pids="$(descendant_pids "$broker_pid")"
    if [[ -z "$pids" ]]; then
        return 0
    fi

    printf 'watch-dev: clearing stale Clair Dev broker session shells...\n'
    printf '%s\n' $pids | xargs kill -TERM 2>/dev/null || true
    sleep 0.2

    remaining=""
    for pid in $pids; do
        if kill -0 "$pid" 2>/dev/null; then
            remaining="$remaining $pid"
        fi
    done
    if [[ -n "$remaining" ]]; then
        printf '%s\n' $remaining | xargs kill -KILL 2>/dev/null || true
    fi
}

track_app_pid() {
    app_pid=""
    for _ in $(seq 1 50); do
        app_pid="$(pgrep -nx "$process_name" 2>/dev/null || true)"
        if [[ -n "$app_pid" ]]; then
            return 0
        fi
        sleep 0.2
    done

    printf 'watch-dev: could not find the launched %s process\n' "$process_name" >&2
    return 1
}

stop_if_app_exited() {
    if [[ -z "$app_pid" ]] || kill -0 "$app_pid" 2>/dev/null; then
        return 0
    fi

    printf 'watch-dev: %s exited; stopping the watcher\n' "$process_name"
    exit 0
}

restart_dev() {
    printf 'watch-dev: building Clair Dev...\n'
    if ! "$repo_root/scripts/xcode.sh" build "Clair Dev" dev; then
        printf 'watch-dev: build failed; keeping the current app running\n' >&2
        return 1
    fi

    # The app may have been quit while the build was running.
    stop_if_app_exited

    # Forget the old PID first so a hot restart is not mistaken for a user quit.
    app_pid=""
    if ! quit_running_dev; then
        printf 'watch-dev: restart cancelled; keeping the current app running\n' >&2
        track_app_pid || true
        return 1
    fi

    printf 'watch-dev: launching the new Clair Dev build...\n'
    "$repo_root/scripts/run-app.sh" dev
    track_app_pid || true
    cleanup_dev_broker_sessions
}

on_interrupt() {
    trap - INT TERM
    printf '\nwatch-dev: stopping %s and the watcher...\n' "$process_name"
    app_pid=""
    quit_running_dev || true
    printf 'watch-dev: stopped\n'
    exit 0
}

trap on_interrupt INT TERM

printf 'watch-dev: watching native sources (poll interval: %ss)\n' "$poll_interval"
printf 'watch-dev: quit %s or press Ctrl-C to stop\n' "$process_name"

last_snapshot="$(snapshot)"
restart_dev || true

while true; do
    sleep "$poll_interval"
    stop_if_app_exited

    current_snapshot="$(snapshot)"
    if [[ "$current_snapshot" == "$last_snapshot" ]]; then
        continue
    fi

    last_snapshot="$current_snapshot"
    restart_dev || true
done
