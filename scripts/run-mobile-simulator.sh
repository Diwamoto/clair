#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="${CLAIR_MOBILE_DERIVED_DATA:-$repo_root/.build/xcode/v2-mobile-simulator}"

# Prefer an already-booted iPhone; allow an explicit device name or UDID.
device_id="$(xcrun simctl list devices available --json | python3 -c '
import json, os, sys
requested = os.environ.get("CLAIR_IOS_DEVICE", "")
devices = [device for runtime, group in json.load(sys.stdin)["devices"].items()
           if ".iOS-" in runtime for device in group if device.get("isAvailable")]
if requested:
    devices = [d for d in devices if requested in (d["udid"], d["name"])]
else:
    devices = [d for d in devices if d["name"].startswith("iPhone")]
devices.sort(key=lambda d: d["state"] != "Booted")
if not devices:
    sys.exit("dev-ios: no matching iOS simulator. Install an iOS runtime in Xcode Settings > Components, or set CLAIR_IOS_DEVICE to an available name/UDID.")
print(devices[0]["udid"])
')"

simulator_app="$(xcode-select -p)/Applications/Simulator.app"
bundle_id=""
app_started=false

terminate_app() {
    if [[ "$app_started" == true ]]; then
        xcrun simctl terminate "$device_id" "$bundle_id" >/dev/null 2>&1 || true
    fi
}

on_interrupt() {
    trap - INT TERM
    printf '\ndev-ios: stopping %s...\n' "${bundle_id:-startup}"
    terminate_app
    app_started=false
    printf 'dev-ios: stopped (the simulator keeps running; close it or run: xcrun simctl shutdown %s)\n' "$device_id"
    exit 0
}

trap on_interrupt INT TERM
trap terminate_app EXIT

CLAIR_MOBILE_DESTINATION="platform=iOS Simulator,id=$device_id" \
    "$repo_root/scripts/build-mobile-simulator.sh"

app_path="$derived_data/Build/Products/Debug-iphonesimulator/Clair v2 Mobile.app"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")"

# bootstatus -b boots a shutdown device and reuses a running one.
xcrun simctl bootstatus "$device_id" -b
open -a "$simulator_app" --args -CurrentDeviceUDID "$device_id"
xcrun simctl install "$device_id" "$app_path"
app_started=true
xcrun simctl launch --terminate-running-process "$device_id" "$bundle_id"
printf 'dev-ios: launched %s on %s\n' "$bundle_id" "$device_id"
printf 'dev-ios: press Ctrl-C to stop the app (the simulator stays open)\n'

# Stay in the foreground so Ctrl-C reaches this script; watch the app process.
while true; do
    sleep 1
    if ! xcrun simctl spawn "$device_id" launchctl list 2>/dev/null | grep -F "$bundle_id" >/dev/null; then
        printf 'dev-ios: %s exited; stopping the watcher\n' "$bundle_id"
        exit 0
    fi
done
