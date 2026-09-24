#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_path="$repo_root/packages/ClairApps"
bin_dir="$package_path/.build/arm64-apple-macosx/debug"

# Dev must never touch Stable's workspace/socket/update state (ADR-0008); `clair` needs the same CLAIR_CHANNEL.
export CLAIR_CHANNEL=dev

daemon_pid=""
app_pid=""
session_file=""

# The dev daemon is shared: every `make dev` reuses a running one, restarts it if it dies, and the
# last session to exit stops it. Sessions register as pid files so a crashed script is pruned.
live_sessions() {
    local f
    for f in "$sessions_dir"/*; do
        [[ -e "$f" ]] || continue
        if kill -0 "$(basename "$f")" 2>/dev/null; then echo "$f"; else rm -f "$f"; fi
    done
}

daemon_up() { "$bin_dir/clair" daemon status --directory "$dev_dir" 2>/dev/null; }

# Starts a daemon unless one answers. Two sessions racing is harmless: the daemon's lock admits one.
ensure_daemon() {
    daemon_up && return 0
    [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null && return 0 # ours, still starting
    printf 'dev: starting ClairDaemon (log: %s)...\n' "$daemon_log"
    # bash 3.2 (macOS) treats an empty array as unbound under `set -u`, hence the ${arr[@]+...} guard.
    "$bin_dir/ClairDaemon" ${daemon_args[@]+"${daemon_args[@]}"} >>"$daemon_log" 2>&1 &
    daemon_pid=$!
}

stop_all() {
    trap - INT TERM
    printf '\ndev: stopping Clair...\n'
    if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
        kill -TERM "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    [[ -n "$session_file" ]] && rm -f "$session_file"
    if [[ -n "$(live_sessions)" ]]; then
        printf 'dev: other dev sessions remain; leaving the daemon running\n'
    else
        "$bin_dir/clair" daemon stop --directory "$dev_dir" 2>/dev/null || true
        [[ -n "$daemon_pid" ]] && wait "$daemon_pid" 2>/dev/null || true
    fi
    printf 'dev: stopped\n'
    exit 0
}
trap stop_all INT TERM

printf 'dev: building Clair (daemon + macOS app)...\n'
swift build --package-path "$package_path" --product ClairDaemon
swift build --package-path "$package_path" --product clair
swift build --package-path "$package_path" --product ClairMacApp

# The GUI's terminals are daemon-owned shells reached through `clair attach`; both live next to the app.
export CLAIR_BIN_DIR="$bin_dir"
dev_dir="$HOME/Library/Application Support/Clair Dev"

sessions_dir="$dev_dir/dev-sessions"
daemon_log="$dev_dir/dev-daemon.log"
mkdir -p "$sessions_dir"
session_file="$sessions_dir/$$"
touch "$session_file"
# Tells the app not to stop the shared daemon on quit; this script owns its lifecycle.
export CLAIR_DEV_SUPERVISED=1

# N11: same loopback remote port the app would pass (ClairDaemonLauncher.ensureRunning).
daemon_args=(--directory "$dev_dir" --remote-port 47612)
[[ -n "${CLAIR_DEV_PROJECT_ROOT:-}" ]] && daemon_args+=(--project-root "$CLAIR_DEV_PROJECT_ROOT")
[[ -n "${CLAIR_DEV_OPENCODE_EXECUTABLE:-}" ]] && daemon_args+=(--opencode-executable "$CLAIR_DEV_OPENCODE_EXECUTABLE")

if daemon_up; then
    printf 'dev: reusing the running ClairDaemon (`make dev-daemon-restart` picks up daemon changes)\n'
else
    ensure_daemon
    for _ in $(seq 50); do daemon_up && break; sleep 0.1; done
fi

# A bare executable shows the generic exec icon to anything reading the bundle (AltTab, Finder), so launch
# from a minimal .app wrapper. Bundle.module still resolves through SwiftPM's debug build-path fallback.
app="$package_path/.build/dev-bundle/Clair Dev.app"
icon_png="$package_path/Sources/ClairMacApp/Resources/AppIconDev.png"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
[[ "$icon_png" -nt "$app/Contents/Resources/AppIcon.icns" ]] && "$repo_root/scripts/make-icns.sh" "$icon_png" "$app/Contents/Resources/AppIcon.icns"
cat >"$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ClairMacApp</string>
  <key>CFBundleIdentifier</key><string>com.diwamoto.clair.dev</string>
  <key>CFBundleName</key><string>Clair Dev</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
launch_app() {
    cp "$bin_dir/ClairMacApp" "$app/Contents/MacOS/ClairMacApp"
    "$app/Contents/MacOS/ClairMacApp" &
    app_pid=$!
}

printf 'dev: launching Clair macOS app (Ctrl-C to stop everything)...\n'
launch_app

# Hot reload: when Swift sources change, rebuild the app and relaunch it. The daemon keeps
# running (terminals survive); daemon-side changes need `make dev-daemon-restart`.
# ponytail: mtime polling (no fswatch dependency); swap for fswatch if the 1s scan gets slow.
stamp="$(mktemp)"
trap 'rm -f "$stamp"' EXIT
watch_dirs=("$package_path/Sources" "$repo_root/packages/ClairCore/Sources")

# The app exiting ends the session; the daemon exiting just gets it restarted. (`wait -n` needs
# bash 4.3+; macOS ships bash 3.2, so poll instead.)
tick=0
while kill -0 "$app_pid" 2>/dev/null; do
    sleep 1
    (( ++tick % 3 == 0 )) && ensure_daemon
    if [[ -n "$(find "${watch_dirs[@]}" -name '*.swift' -newer "$stamp" -print -quit)" ]]; then
        touch "$stamp" # before the build, so edits made mid-build trigger another round
        printf 'dev: change detected, rebuilding ClairMacApp...\n'
        if swift build --package-path "$package_path" --product ClairMacApp; then
            kill -TERM "$app_pid" 2>/dev/null || true
            wait "$app_pid" 2>/dev/null || true
            launch_app
            printf 'dev: reloaded\n'
        else
            printf 'dev: build failed; keeping the running app\n'
        fi
    fi
done
stop_all
