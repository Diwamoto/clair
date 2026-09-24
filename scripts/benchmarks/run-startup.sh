#!/usr/bin/env bash
set -euo pipefail

# BUDGET-START-HALFBOUNCE (docs/benchmarks/clair-v2-performance-budget.md §1).
#
# Builds Clair the way it ships — Release, inside a real `.app` bundle — and
# measures `exec` → first presented frame. Measuring the bare `swift build`
# executable would not be the product: a bundled app loads an Info.plist, gets
# a real bundle identifier (which the update channel reads), and is launched by
# LaunchServices rather than by the shell.
#
# The number is reported by the app itself (ClairStartupTrace), so it includes
# dyld and static initialisers that an external stopwatch cannot see.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
apps_package="$repo_root/packages/ClairApps"

# Dock launch bounce is ~600 ms per full bounce, so half a bounce is 300 ms.
# Calibration knob: measure the bounce period on the target machine and set
# this to half of it. The budget is the feel, not the constant.
HALF_BOUNCE_MS="${HALF_BOUNCE_MS:-300}"
FULL_BOUNCE_MS="${FULL_BOUNCE_MS:-600}"

trials=5
cold=0
out_file=""

usage() {
  cat <<'USAGE'
Usage: run-startup.sh [--trials N] [--cold] [--out FILE]

  --trials N   measured launches (default 5; one warm-up is always discarded)
  --cold       `sudo purge` before each trial and judge against a full bounce
  --out FILE   write a JSON report
USAGE
}

while (($# > 0)); do
  case "$1" in
    --trials) trials="$2"; shift 2 ;;
    --cold) cold=1; shift ;;
    --out) out_file="$2"; shift 2 ;;
    --help | -h) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ((cold)); then
  budget="$FULL_BOUNCE_MS"
  kind="cold"
else
  budget="$HALF_BOUNCE_MS"
  kind="warm"
fi

printf 'startup: building ClairMacApp (release)...\n'
swift build -c release --package-path "$apps_package" --product ClairMacApp >/dev/null

binary="$apps_package/.build/arm64-apple-macosx/release/ClairMacApp"
[[ -x "$binary" ]] || { echo "startup: no release binary at $binary" >&2; exit 1; }

# Assemble the shipping bundle shape. Kept in .build, never committed.
app="$apps_package/.build/release-bundle/Clair.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/ClairMacApp"
version="$(git -C "$repo_root" describe --tags --always 2>/dev/null || echo 0.0.0)"
cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ClairMacApp</string>
  <key>CFBundleIdentifier</key><string>com.diwamoto.clair</string>
  <key>CFBundleName</key><string>Clair</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
# Ad-hoc signature: unsigned bundles get extra Gatekeeper work on first launch,
# which would land in the measurement instead of in Clair's own startup.
codesign --force --sign - "$app" >/dev/null 2>&1 || printf 'startup: codesign unavailable, continuing unsigned\n'

# A throwaway workspace: measuring a restore of whatever Projects happen to be
# open on this machine would make the number unreproducible. The seed root is
# this repository, which is a realistic first frame.
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

launch() {
  ((cold)) && sudo purge
  # CLAIR_STARTUP_TRACE=exit makes the app quit right after it reports, so each
  # trial is one clean process. The watchdog inside the app means a launch that
  # never draws fails the run instead of hanging it.
  CLAIR_STARTUP_TRACE=exit \
  CLAIR_STARTUP_TIMEOUT=30 \
  CLAIR_CHANNEL=stable \
  CLAIR_PROJECT_ROOT="$repo_root" \
  HOME="$work_dir" \
    "$app/Contents/MacOS/ClairMacApp" 2>/dev/null |
    sed -n 's/^clair\.startup\.first_frame_ms=//p' | tail -n 1
}

printf 'startup: %s, %d trials, budget %s ms\n' "$kind" "$trials" "$budget"
printf 'startup: discarding one warm-up launch...\n'
launch >/dev/null || true

samples=()
for ((i = 1; i <= trials; i++)); do
  value="$(launch || true)"
  if [[ -z "$value" ]]; then
    echo "startup: trial $i reported nothing (the app did not reach a first frame)" >&2
    exit 1
  fi
  printf 'startup: trial %d  %s ms\n' "$i" "$value"
  samples+=("$value")
done

read -r median p95 max verdict < <(
  printf '%s\n' "${samples[@]}" | sort -n | awk -v budget="$budget" '
    { v[NR] = $1 }
    END {
      # §4: nearest-rank p95, sorted[ceil(0.95 * n) - 1].
      m = v[int(NR / 2) + 1]
      p = v[int(NR * 0.95 + 0.999999)]
      printf "%.2f %.2f %.2f %s\n", m, p, v[NR], (p <= budget ? "pass" : "over-budget")
    }'
)

printf 'startup: median=%s ms  p95=%s ms  max=%s ms  budget=%s ms  %s\n' \
  "$median" "$p95" "$max" "$budget" "$verdict"

if [[ -n "$out_file" ]]; then
  mkdir -p "$(dirname "$out_file")"
  {
    printf '{\n  "contract": "clair-v2-performance-budget",\n'
    printf '  "metric": "launch.%s_to_first_frame",\n' "$kind"
    printf '  "unit": "ms",\n  "budget_ms": %s,\n' "$budget"
    printf '  "build_configuration": "release",\n  "bundled": true,\n'
    printf '  "recorded_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "host": "%s",\n  "commit": "%s",\n' "$(sysctl -n hw.model)" "$(git -C "$repo_root" rev-parse HEAD)"
    printf '  "median_ms": %s,\n  "p95_ms": %s,\n  "max_ms": %s,\n' "$median" "$p95" "$max"
    printf '  "samples_ms": [%s],\n' "$(IFS=,; echo "${samples[*]}")"
    printf '  "verdict": "%s"\n}\n' "$verdict"
  } >"$out_file"
  printf 'startup: wrote %s\n' "$out_file"
fi

[[ "$verdict" == "pass" ]]
