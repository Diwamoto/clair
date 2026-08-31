#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
umask 077

readonly pinned_source_commit="80eef4d30f66c4520445872bed73e95c594e2695"
readonly normal_bundle_identifier="dev.daiki.ccedit"
readonly idle_sample_interval_seconds=1

trial_count=5
idle_sample_count=30
startup_timeout_seconds=30

app_bundle=""
source_commit=""
corpus_dir=""
operation_script=""
metric_contract=""
output_path=""
bundle_identifier=""

active_root_pid=""
scratch_base=""
scratch_dir=""
lock_dir=""
output_temp=""
account_root=""
app_support_dir=""
cache_dir=""
webkit_dir=""
preferences_file=""
sandbox_profile=""
profile_prepared=0
created_profile_parents=()

usage() {
  cat <<'USAGE'
Usage: collect-v1-baseline.sh \
  --app APP_BUNDLE \
  --source-commit FULL_SHA \
  --corpus DIRECTORY \
  --operation-script FILE \
  --metric-contract FILE \
  --output RESULT.json \
  [--trials COUNT] \
  [--idle-samples COUNT] \
  [--startup-timeout SECONDS]

Collect ccedit V1 lifecycle phases and idle process metrics with sandboxed,
benchmark-only app storage. Defaults are 5 trials, 30 idle samples per run,
and a 30-second first-paint timeout. The normal ccedit bundle is refused.
USAGE
}

die() {
  echo "collect-v1-baseline.sh: $*" >&2
  exit 1
}

warn() {
  echo "collect-v1-baseline.sh: warning: $*" >&2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

remove_created_profile() {
  local candidate=""
  local candidate_parent=""
  local canonical_parent=""
  local parent_index=0

  ((profile_prepared == 1)) || return 0

  if [[ -z "$account_root" || -z "$bundle_identifier" ]]; then
    warn "profile ownership cannot be verified; refusing cleanup"
    return 1
  fi
  [[ "$app_support_dir" == "$account_root/Library/Application Support/$bundle_identifier" ]] || return 1
  [[ "$cache_dir" == "$account_root/Library/Caches/$bundle_identifier" ]] || return 1
  [[ "$webkit_dir" == "$account_root/Library/WebKit/$bundle_identifier" ]] || return 1
  [[ "$preferences_file" == "$account_root/Library/Preferences/$bundle_identifier.plist" ]] || return 1

  for candidate in "$app_support_dir" "$cache_dir" "$webkit_dir" "$preferences_file"; do
    candidate_parent="${candidate%/*}"
    if ! canonical_parent="$(canonical_existing_path "$candidate_parent")"; then
      warn "profile parent disappeared; refusing cleanup: $candidate_parent"
      return 1
    fi
    if [[ "$canonical_parent" != "$candidate_parent" ]]; then
      warn "profile parent changed canonical location; refusing cleanup: $candidate_parent"
      return 1
    fi
  done

  for candidate in "$app_support_dir" "$cache_dir" "$webkit_dir"; do
    if [[ -L "$candidate" ]]; then
      rm -f -- "$candidate"
    elif [[ -d "$candidate" ]]; then
      rm -rf -- "$candidate"
    elif [[ -e "$candidate" ]]; then
      warn "refusing to recursively remove non-directory profile path: $candidate"
      return 1
    fi
  done

  if [[ -L "$preferences_file" || -f "$preferences_file" ]]; then
    rm -f -- "$preferences_file"
  elif [[ -e "$preferences_file" ]]; then
    warn "refusing to remove non-file preferences path: $preferences_file"
    return 1
  fi

  parent_index=${#created_profile_parents[@]}
  while ((parent_index > 0)); do
    parent_index=$((parent_index - 1))
    rmdir "${created_profile_parents[$parent_index]}" 2>/dev/null || true
  done
  created_profile_parents=()
  profile_prepared=0
}

stop_active_app() {
  local root_pid="${active_root_pid:-}"
  local pgid=""
  local attempt=0

  [[ -n "$root_pid" ]] || return 0

  # Every benchmark launch calls setsid(2), so its process group belongs only
  # to this collector. Never use a process name, bundle name, killall, or pgrep
  # for cleanup: those could target the user's normal ccedit instance.
  if kill -0 "$root_pid" 2>/dev/null; then
    pgid="$(ps -o pgid= -p "$root_pid" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$pgid" == "$root_pid" ]]; then
      kill -TERM -- "-$root_pid" 2>/dev/null || true
    else
      warn "benchmark process group could not be verified; terminating only its root process"
      kill -TERM "$root_pid" 2>/dev/null || true
    fi
  fi

  while kill -0 "$root_pid" 2>/dev/null && ((attempt < 50)); do
    sleep 0.1
    attempt=$((attempt + 1))
  done

  if kill -0 "$root_pid" 2>/dev/null; then
    if [[ "$pgid" == "$root_pid" ]]; then
      kill -KILL -- "-$root_pid" 2>/dev/null || true
    else
      kill -KILL "$root_pid" 2>/dev/null || true
    fi
  fi

  wait "$root_pid" 2>/dev/null || true
  active_root_pid=""
}

cleanup() {
  local exit_status=$?

  trap - EXIT INT TERM HUP
  stop_active_app || true
  remove_created_profile || true

  if [[ -n "${output_temp:-}" && -f "$output_temp" ]]; then
    rm -f -- "$output_temp"
  fi

  if [[ -n "${lock_dir:-}" && -d "$lock_dir" ]]; then
    rm -f -- "$lock_dir/owner"
    rmdir "$lock_dir" 2>/dev/null || true
  fi

  if [[ -n "${scratch_dir:-}" && -d "$scratch_dir" ]]; then
    case "$scratch_dir" in
      "$scratch_base"/clair-v1-baseline.*)
        rm -rf -- "$scratch_dir"
        ;;
      *)
        warn "refusing to remove unexpected scratch path"
        ;;
    esac
  fi

  exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

while (($# > 0)); do
  case "$1" in
    --app)
      (($# >= 2)) || die "--app requires an app bundle"
      app_bundle="$2"
      shift 2
      ;;
    --source-commit)
      (($# >= 2)) || die "--source-commit requires a full SHA"
      source_commit="$2"
      shift 2
      ;;
    --corpus)
      (($# >= 2)) || die "--corpus requires a directory"
      corpus_dir="$2"
      shift 2
      ;;
    --operation-script)
      (($# >= 2)) || die "--operation-script requires a JSON file"
      operation_script="$2"
      shift 2
      ;;
    --metric-contract)
      (($# >= 2)) || die "--metric-contract requires a JSON file"
      metric_contract="$2"
      shift 2
      ;;
    --output)
      (($# >= 2)) || die "--output requires a JSON file"
      output_path="$2"
      shift 2
      ;;
    --trials)
      (($# >= 2)) || die "--trials requires a positive integer"
      trial_count="$2"
      shift 2
      ;;
    --idle-samples)
      (($# >= 2)) || die "--idle-samples requires a positive integer"
      idle_sample_count="$2"
      shift 2
      ;;
    --startup-timeout)
      (($# >= 2)) || die "--startup-timeout requires a positive integer"
      startup_timeout_seconds="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$app_bundle" ]] || die "--app is required"
[[ -n "$source_commit" ]] || die "--source-commit is required"
[[ -n "$corpus_dir" ]] || die "--corpus is required"
[[ -n "$operation_script" ]] || die "--operation-script is required"
[[ -n "$metric_contract" ]] || die "--metric-contract is required"
[[ -n "$output_path" ]] || die "--output is required"
[[ "$trial_count" =~ ^[1-9][0-9]*$ ]] || die "--trials must be a positive integer"
[[ "$idle_sample_count" =~ ^[1-9][0-9]*$ ]] || die "--idle-samples must be a positive integer"
[[ "$startup_timeout_seconds" =~ ^[1-9][0-9]*$ ]] || die "--startup-timeout must be a positive integer"

for required_command in \
  awk chmod grep ioreg ln mkdir mktemp plutil ps python3 rm rmdir sandbox-exec shasum sleep sw_vers sysctl tr uname; do
  require_command "$required_command"
done

[[ -x /usr/libexec/PlistBuddy ]] || die "/usr/libexec/PlistBuddy is unavailable"
[[ -x /usr/bin/sandbox-exec ]] || die "/usr/bin/sandbox-exec is unavailable"
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || die "--source-commit must be a 40-character lowercase SHA"
[[ "$source_commit" == "$pinned_source_commit" ]] || \
  die "source commit must be the pinned ccedit V1 commit $pinned_source_commit"

canonical_existing_path() {
  python3 - "$1" <<'PY'
import os
import sys

path = os.path.realpath(os.path.abspath(sys.argv[1]))
if not os.path.exists(path):
    raise SystemExit(1)
print(path)
PY
}

if ! app_bundle="$(canonical_existing_path "$app_bundle")"; then
  die "app bundle does not exist"
fi
if ! corpus_dir="$(canonical_existing_path "$corpus_dir")"; then
  die "corpus directory does not exist"
fi
if ! operation_script="$(canonical_existing_path "$operation_script")"; then
  die "operation script does not exist"
fi
if ! metric_contract="$(canonical_existing_path "$metric_contract")"; then
  die "metric contract does not exist"
fi

[[ -d "$app_bundle" && "$app_bundle" == *.app ]] || die "--app must name an existing .app bundle"
[[ -d "$corpus_dir" ]] || die "--corpus must name a directory"
[[ -f "$operation_script" ]] || die "--operation-script must name a JSON file"
[[ -f "$metric_contract" ]] || die "--metric-contract must name a JSON file"

output_path="$(python3 - "$output_path" <<'PY'
import os
import sys

path = os.path.abspath(sys.argv[1])
parent = os.path.realpath(os.path.dirname(path) or ".")
os.makedirs(parent, exist_ok=True)
print(os.path.join(parent, os.path.basename(path)))
PY
)"
[[ -n "${output_path##*/}" ]] || die "--output must name a file"
if [[ -e "$output_path" || -L "$output_path" ]]; then
  die "refusing to overwrite existing output: $output_path"
fi

info_plist="$app_bundle/Contents/Info.plist"
[[ -f "$info_plist" ]] || die "app bundle is missing Contents/Info.plist"

if ! executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist" 2>/dev/null)"; then
  die "app bundle is missing CFBundleExecutable"
fi
if ! bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null)"; then
  die "app bundle is missing CFBundleIdentifier"
fi
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist" 2>/dev/null || true)"
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null || true)"

[[ -n "$executable_name" && "$executable_name" != */* && "$executable_name" != *$'\n'* ]] || \
  die "app bundle has an unsafe CFBundleExecutable"
[[ "$bundle_identifier" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || \
  die "app bundle has an invalid CFBundleIdentifier"
[[ "$bundle_identifier" != *..* ]] || die "app bundle identifier must not contain consecutive dots"

if [[ "$bundle_identifier" == "$normal_bundle_identifier" || "$bundle_identifier" == "dev.daiki.ccedit.dev" ]]; then
  die "refusing the normal ccedit bundle identifier; build a benchmark bundle with a unique identity override"
fi

if ! app_executable="$(canonical_existing_path "$app_bundle/Contents/MacOS/$executable_name")"; then
  die "app bundle executable does not exist"
fi
case "$app_executable" in
  "$app_bundle"/Contents/MacOS/*) ;;
  *) die "app executable resolves outside the supplied bundle" ;;
esac
[[ -f "$app_executable" && -x "$app_executable" ]] || die "app bundle executable is not executable"

account_root="$(python3 - <<'PY'
import os
import pwd

print(os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir))
PY
)"
[[ -d "$account_root" && "$account_root" == /* ]] || die "cannot resolve the current account directory"

app_support_dir="$account_root/Library/Application Support/$bundle_identifier"
cache_dir="$account_root/Library/Caches/$bundle_identifier"
webkit_dir="$account_root/Library/WebKit/$bundle_identifier"
preferences_file="$account_root/Library/Preferences/$bundle_identifier.plist"

for profile_path in "$app_support_dir" "$cache_dir" "$webkit_dir" "$preferences_file"; do
  if [[ -e "$profile_path" || -L "$profile_path" ]]; then
    die "refusing pre-existing benchmark app storage: $profile_path"
  fi
done

host_arch="$(uname -m)"
[[ "$host_arch" == "arm64" ]] || die "the V1 baseline procedure requires Apple Silicon (arm64)"

corpus_metadata="$(python3 - "$corpus_dir" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
manifest_path = root / "MANIFEST.json"
try:
    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes)
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid corpus manifest: {error}")

if manifest.get("manifest_version") != 1:
    raise SystemExit("corpus manifest_version must be 1")
if str(manifest.get("generator_version")) != "1":
    raise SystemExit("corpus generator_version must be 1")

expected_sizes = {
    "large-files/text-10MiB.txt": 10_485_760,
    "large-files/text-100MiB.txt": 104_857_600,
}
for relative, expected_size in expected_sizes.items():
    path = root / relative
    if not path.is_file() or path.stat().st_size != expected_size:
        raise SystemExit(f"corpus file is missing or has the wrong size: {relative}")

if not (root / "unicode/unicode-fixture.txt").is_file():
    raise SystemExit("corpus Unicode fixture is missing")
if not (root / "git-status" / ".git").is_dir():
    raise SystemExit("corpus Git status fixture is missing")

file_tree_profile = manifest.get("file_tree_profile")
if not isinstance(file_tree_profile, dict) or file_tree_profile.get("files") != 10_000:
    raise SystemExit("corpus file_tree_profile.files must be 10000")
actual_file_tree_count = sum(
    1
    for path in (root / "file-tree").glob("module-*/package-*/file-*.txt")
    if path.is_file()
)
if actual_file_tree_count != 10_000:
    raise SystemExit("corpus file tree must contain 10000 fixture files")
if len(manifest.get("files", [])) != 10_011:
    raise SystemExit("corpus manifest must contain 10011 file entries")

digest = hashlib.sha256(manifest_bytes).hexdigest()
print(
    "\t".join(
        str(value)
        for value in (
            1,
            1,
            digest,
            len(manifest["files"]),
            file_tree_profile["files"],
            file_tree_profile.get("directories", "unknown"),
            file_tree_profile.get("levels_below_root", "unknown"),
        )
    )
)
PY
)" || die "corpus validation failed"

IFS=$'\t' read -r \
  manifest_version \
  generator_version \
  manifest_digest \
  manifest_file_count \
  file_tree_files \
  file_tree_directories \
  file_tree_levels <<< "$corpus_metadata"
IFS=$'\n\t'
[[ "$manifest_digest" =~ ^[0-9a-f]{64}$ ]] || die "failed to calculate corpus manifest digest"

operation_metadata="$(python3 - "$operation_script" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
try:
    raw = path.read_bytes()
    operation_script = json.loads(raw)
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid operation script: {error}")

if operation_script.get("schema_version") != 1:
    raise SystemExit("operation script schema_version must be 1")
workload_id = operation_script.get("workload_id")
if not isinstance(workload_id, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", workload_id):
    raise SystemExit("operation script workload_id is missing or invalid")
if not isinstance(operation_script.get("actions"), list) or not operation_script["actions"]:
    raise SystemExit("operation script actions must be a non-empty array")

print(f"1\t{workload_id}\t{hashlib.sha256(raw).hexdigest()}")
PY
)" || die "operation script validation failed"
IFS=$'\t' read -r operation_schema_version workload_id operation_script_digest <<< "$operation_metadata"
IFS=$'\n\t'
[[ "$operation_script_digest" =~ ^[0-9a-f]{64}$ ]] || die "failed to hash operation script"

metric_contract_metadata="$(python3 - "$metric_contract" <<'PY'
import hashlib
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    raw = path.read_bytes()
    contract = json.loads(raw)
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid metric contract: {error}")

if contract.get("schema_version") != 1:
    raise SystemExit("metric contract schema_version must be 1")
if contract.get("contract_id") != "clair-v1-performance-gate-v1":
    raise SystemExit("metric contract_id must be clair-v1-performance-gate-v1")
if not isinstance(contract.get("metrics"), dict) or not contract["metrics"]:
    raise SystemExit("metric contract metrics must be a non-empty object")

print(f"1\t{contract['contract_id']}\t{hashlib.sha256(raw).hexdigest()}")
PY
)" || die "metric contract validation failed"
IFS=$'\t' read -r metric_schema_version contract_id metric_contract_digest <<< "$metric_contract_metadata"
IFS=$'\n\t'
[[ "$metric_contract_digest" =~ ^[0-9a-f]{64}$ ]] || die "failed to hash metric contract"

app_executable_digest="$(shasum -a 256 "$app_executable" | awk '{print $1}')"
[[ "$app_executable_digest" =~ ^[0-9a-f]{64}$ ]] || die "failed to hash app executable"

# Refuse another process from this exact app, and also check any running app
# whose executable resolves to a bundle with the same benchmark identifier.
# These are read-only checks; the collector never stops a pre-existing process.
process_commands="$(ps -axo pid=,command= 2>/dev/null)" || die "cannot inspect existing processes safely"
existing_exact_process="$(printf '%s\n' "$process_commands" | awk -v executable="$app_executable" '
  {
    line = $0
    sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", line)
    if (line == executable || index(line, executable " ") == 1) print $1
  }
')"
[[ -z "$existing_exact_process" ]] || die "the supplied benchmark app is already running"

same_identifier_process=""
while read -r candidate_pid candidate_executable; do
  [[ -n "${candidate_pid:-}" && -n "${candidate_executable:-}" ]] || continue
  case "$candidate_executable" in
    */Contents/MacOS/*)
      candidate_bundle="${candidate_executable%/Contents/MacOS/*}"
      candidate_plist="$candidate_bundle/Contents/Info.plist"
      [[ -f "$candidate_plist" ]] || continue
      candidate_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate_plist" 2>/dev/null || true)"
      if [[ "$candidate_identifier" == "$bundle_identifier" ]]; then
        same_identifier_process="$candidate_pid"
        break
      fi
      ;;
  esac
done < <(ps -axo pid=,comm= 2>/dev/null)
[[ -z "$same_identifier_process" ]] || die "another app with the benchmark bundle identifier is already running"

scratch_base="${TMPDIR:-/tmp}"
[[ -d "$scratch_base" && -w "$scratch_base" ]] || die "temporary directory is unavailable"
scratch_base="$(canonical_existing_path "$scratch_base")"

lock_key="$(printf '%s' "$bundle_identifier" | shasum -a 256 | awk '{print $1}')"
lock_dir="$scratch_base/clair-v1-baseline-$lock_key.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  die "another collector may be using this benchmark bundle identifier"
fi
printf '%s\n' "$$" > "$lock_dir/owner"

scratch_dir="$(mktemp -d "$scratch_base/clair-v1-baseline.XXXXXX")"
chmod 700 "$scratch_dir"
mkdir -p "$scratch_dir/runs" "$scratch_dir/warmups"

sandbox_profile="$scratch_dir/ccedit-benchmark.sb"
python3 - \
  "$sandbox_profile" \
  "$account_root" \
  "$app_bundle" \
  "$corpus_dir" \
  "$scratch_dir" \
  "$app_support_dir" \
  "$cache_dir" \
  "$webkit_dir" \
  "$preferences_file" <<'PY'
import json
import pathlib
import sys

(
    profile_path,
    account_root,
    app_bundle,
    corpus_dir,
    scratch_dir,
    app_support_dir,
    cache_dir,
    webkit_dir,
    preferences_file,
) = sys.argv[1:]


def quoted(path):
    return json.dumps(path)


metadata_paths = [
    account_root,
    str(pathlib.Path(account_root) / "Library"),
    str(pathlib.Path(app_support_dir).parent),
    str(pathlib.Path(cache_dir).parent),
    str(pathlib.Path(webkit_dir).parent),
    str(pathlib.Path(preferences_file).parent),
]

lines = [
    "(version 1)",
    "(allow default)",
    f"(deny file-read* file-write* (subpath {quoted(account_root)}))",
]
for path in dict.fromkeys(metadata_paths):
    lines.append(f"(allow file-read-metadata (literal {quoted(path)}))")
lines.extend(
    [
        f"(allow file-read* (subpath {quoted(app_bundle)}))",
        f"(allow file-read* (subpath {quoted(corpus_dir)}))",
        f"(allow file-read* file-write* (subpath {quoted(scratch_dir)}))",
        f"(allow file-read* file-write* (subpath {quoted(app_support_dir)}))",
        f"(allow file-read* file-write* (subpath {quoted(cache_dir)}))",
        f"(allow file-read* file-write* (subpath {quoted(webkit_dir)}))",
        f"(allow file-read* file-write* (literal {quoted(preferences_file)}))",
    ]
)
pathlib.Path(profile_path).write_text("\n".join(lines) + "\n")
PY
chmod 600 "$sandbox_profile"
if ! /usr/bin/sandbox-exec -f "$sandbox_profile" /usr/bin/true >/dev/null 2>&1; then
  die "sandbox profile validation failed; run the collector with the required escalation"
fi

ensure_profile_parent() {
  local parent="$1"
  local canonical_parent=""

  if [[ -L "$parent" ]]; then
    die "refusing symlinked benchmark storage parent: $parent"
  fi
  if [[ -e "$parent" ]]; then
    [[ -d "$parent" ]] || die "benchmark storage parent is not a directory: $parent"
    canonical_parent="$(canonical_existing_path "$parent")"
    [[ "$canonical_parent" == "$parent" ]] || die "benchmark storage parent is not canonical: $parent"
    return 0
  fi
  mkdir "$parent"
  canonical_parent="$(canonical_existing_path "$parent")"
  [[ "$canonical_parent" == "$parent" ]] || die "created benchmark storage parent is not canonical: $parent"
  created_profile_parents+=("$parent")
}

prepare_app_profile() {
  local profile_path=""

  ((profile_prepared == 0)) || die "benchmark app profile is already prepared"
  for profile_path in "$app_support_dir" "$cache_dir" "$webkit_dir" "$preferences_file"; do
    if [[ -e "$profile_path" || -L "$profile_path" ]]; then
      die "refusing pre-existing benchmark app storage: $profile_path"
    fi
  done

  profile_prepared=1
  created_profile_parents=()
  ensure_profile_parent "${app_support_dir%/*}"
  ensure_profile_parent "${cache_dir%/*}"
  ensure_profile_parent "${webkit_dir%/*}"
  ensure_profile_parent "${preferences_file%/*}"
  mkdir "$app_support_dir" "$cache_dir" "$webkit_dir"
  plutil -create xml1 "$preferences_file"
}

start_app() {
  local log_path="$1"
  local pgid=""
  local attempt=0

  : > "$log_path"

  # The account environment is inherited unchanged. sandbox-exec denies the
  # account directory, then permits only this immutable bundle/corpus and the
  # collector-owned app support, cache, WebKit, preferences, and scratch paths.
  # setsid(2) gives cleanup a process group that cannot contain a pre-existing
  # ccedit process. RUST_LOG is explicit because the host value may be `warn`.
  python3 - "$sandbox_profile" "$app_executable" "$corpus_dir" >"$log_path" 2>&1 <<'PY' &
import os
import sys

profile, executable, corpus = sys.argv[1:]
os.chdir(corpus)
os.setsid()
os.environ["RUST_LOG"] = "info,ccedit_lib=debug,ccedit::perf=info,ccedit::perf::fe=info"
os.execv(
    "/usr/bin/sandbox-exec",
    ["sandbox-exec", "-f", profile, executable, corpus],
)
PY
  active_root_pid=$!

  while ((attempt < 20)); do
    if ! kill -0 "$active_root_pid" 2>/dev/null; then
      wait "$active_root_pid" 2>/dev/null || true
      active_root_pid=""
      return 1
    fi
    pgid="$(ps -o pgid= -p "$active_root_pid" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$pgid" == "$active_root_pid" ]]; then
      return 0
    fi
    sleep 0.05
    attempt=$((attempt + 1))
  done

  warn "new benchmark process did not enter its private process group"
  kill -TERM "$active_root_pid" 2>/dev/null || true
  wait "$active_root_pid" 2>/dev/null || true
  active_root_pid=""
  return 1
}

wait_for_first_paint_marker() {
  local log_path="$1"
  local attempts=$((startup_timeout_seconds * 10))
  local attempt=0

  while ((attempt < attempts)); do
    if grep -Eq 'phase="?fe\.first_paint_after_raf"?' "$log_path"; then
      return 0
    fi
    if ! kill -0 "$active_root_pid" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done

  return 2
}

sample_process_family() {
  local root_pid="$1"
  local process_table=""

  if ! process_table="$(ps -axo pid=,ppid=,rss=,%cpu= 2>/dev/null)"; then
    return 1
  fi

  printf '%s\n' "$process_table" | awk -v root="$root_pid" '
    NF >= 4 {
      count += 1
      pid[count] = $1
      parent[count] = $2
      rss[count] = $3
      cpu[count] = $4
      if ($1 == root) found_root = 1
    }
    END {
      if (!found_root) exit 2
      included[root] = 1
      for (pass = 0; pass < count; pass += 1) {
        changed = 0
        for (row_index = 1; row_index <= count; row_index += 1) {
          if (!included[pid[row_index]] && included[parent[row_index]]) {
            included[pid[row_index]] = 1
            changed = 1
          }
        }
        if (!changed) break
      }
      for (row_index = 1; row_index <= count; row_index += 1) {
        if (included[pid[row_index]]) {
          rss_total += rss[row_index]
          cpu_total += cpu[row_index]
          process_count += 1
        }
      }
      if (process_count == 0) exit 3
      printf "%.0f\t%.3f\t%d\n", rss_total, cpu_total, process_count
    }
  '
}

run_warmup() {
  local warmup_id="$1"
  local warmup_dir="$scratch_dir/warmups/$warmup_id"
  local marker_result=0

  mkdir -p "$warmup_dir"
  ((profile_prepared == 1)) || die "benchmark app profile is not prepared"
  if ! start_app "$warmup_dir/app.log"; then
    warn "$warmup_id app exited during launch"
    return 1
  fi

  if wait_for_first_paint_marker "$warmup_dir/app.log"; then
    marker_result=0
  else
    marker_result=$?
  fi
  stop_active_app

  case "$marker_result" in
    0) return 0 ;;
    1) warn "$warmup_id app exited before the first-paint marker" ;;
    2) warn "$warmup_id timed out waiting for the first-paint marker" ;;
  esac
  return 1
}

collect_measured_run() {
  local run_id="$1"
  local launch_kind="$2"
  local run_dir="$scratch_dir/runs/$run_id"
  local marker_result=0
  local run_status="measured"
  local run_reason=""
  local sample_index=1
  local process_sample=""
  local rss_kib=""
  local cpu_percent=""
  local process_count=""

  mkdir -p "$run_dir"
  ((profile_prepared == 1)) || die "benchmark app profile is not prepared"
  : > "$run_dir/process-samples.tsv"
  printf '%s\n' "$launch_kind" > "$run_dir/kind"

  if ! start_app "$run_dir/app.log"; then
    printf '%s\n' "failed" > "$run_dir/status"
    printf '%s\n' "app-exited-during-launch" > "$run_dir/reason"
    return 1
  fi

  if wait_for_first_paint_marker "$run_dir/app.log"; then
    marker_result=0
  else
    marker_result=$?
    if ((marker_result == 1)); then
      run_status="failed"
      run_reason="app-exited-before-first-paint"
    else
      run_status="partial"
      run_reason="first-paint-marker-timeout"
    fi
  fi

  if kill -0 "$active_root_pid" 2>/dev/null; then
    while ((sample_index <= idle_sample_count)); do
      sleep "$idle_sample_interval_seconds"
      if ! process_sample="$(sample_process_family "$active_root_pid")"; then
        if [[ "$run_status" == "measured" ]]; then
          run_status="partial"
          run_reason="app-exited-during-process-sampling"
        elif [[ -n "$run_reason" ]]; then
          run_reason="$run_reason;app-exited-during-process-sampling"
        fi
        break
      fi
      IFS=$'\t' read -r rss_kib cpu_percent process_count <<< "$process_sample"
      IFS=$'\n\t'
      printf '%d\t%d\t%s\t%s\t%s\n' \
        "$sample_index" \
        "$((sample_index * idle_sample_interval_seconds))" \
        "$rss_kib" \
        "$cpu_percent" \
        "$process_count" >> "$run_dir/process-samples.tsv"
      sample_index=$((sample_index + 1))
    done
  fi

  stop_active_app

  printf '%s\n' "$run_status" > "$run_dir/status"
  printf '%s\n' "$run_reason" > "$run_dir/reason"
  [[ "$run_status" == "measured" ]]
}

failure_count=0

screen_locked_state="not-measured"
if screen_locked_raw="$(ioreg -n Root -d1 -a 2>/dev/null | plutil -extract IOConsoleLocked raw -o - - 2>/dev/null)"; then
  case "$screen_locked_raw" in
    true|1) screen_locked_state="true" ;;
    false|0) screen_locked_state="false" ;;
  esac
fi

prepare_app_profile
if ! run_warmup "fresh-profile-warmup"; then
  failure_count=$((failure_count + 1))
fi
remove_created_profile

trial_index=1
while ((trial_index <= trial_count)); do
  printf -v run_id 'fresh-profile-%02d' "$trial_index"
  prepare_app_profile
  if ! collect_measured_run "$run_id" "fresh-profile"; then
    failure_count=$((failure_count + 1))
  fi
  remove_created_profile
  trial_index=$((trial_index + 1))
done

prepare_app_profile
if ! run_warmup "warm-warmup"; then
  failure_count=$((failure_count + 1))
fi

trial_index=1
while ((trial_index <= trial_count)); do
  printf -v run_id 'warm-%02d' "$trial_index"
  if ! collect_measured_run "$run_id" "warm"; then
    failure_count=$((failure_count + 1))
  fi
  trial_index=$((trial_index + 1))
done
remove_created_profile

captured_at_utc="$(python3 - <<'PY'
import datetime
print(datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"))
PY
)"
os_version="$(sw_vers -productVersion 2>/dev/null || printf 'unknown')"
os_build="$(sw_vers -buildVersion 2>/dev/null || printf 'unknown')"
hardware_model="$(sysctl -n hw.model 2>/dev/null || printf 'unknown')"
logical_cpu_count="$(sysctl -n hw.logicalcpu 2>/dev/null || printf 'unknown')"
memory_bytes="$(sysctl -n hw.memsize 2>/dev/null || printf 'unknown')"

output_temp="$(mktemp "$output_path.tmp.XXXXXX")"

python3 - \
  "$scratch_dir/runs" \
  "$output_temp" \
  "$source_commit" \
  "$bundle_identifier" \
  "$bundle_version" \
  "$short_version" \
  "$app_executable_digest" \
  "$captured_at_utc" \
  "$os_version" \
  "$os_build" \
  "$host_arch" \
  "$hardware_model" \
  "$logical_cpu_count" \
  "$memory_bytes" \
  "$screen_locked_state" \
  "$manifest_version" \
  "$generator_version" \
  "$manifest_digest" \
  "$manifest_file_count" \
  "$file_tree_files" \
  "$file_tree_directories" \
  "$file_tree_levels" \
  "$operation_script" \
  "$operation_schema_version" \
  "$workload_id" \
  "$operation_script_digest" \
  "$metric_contract" \
  "$metric_schema_version" \
  "$contract_id" \
  "$metric_contract_digest" \
  "$trial_count" \
  "$idle_sample_count" \
  "$idle_sample_interval_seconds" \
  "$startup_timeout_seconds" <<'PY'
import hashlib
import json
import math
import pathlib
import re
import statistics
import sys

(
    runs_root,
    output_path,
    source_commit,
    bundle_identifier,
    bundle_version,
    short_version,
    executable_sha256,
    captured_at_utc,
    os_version,
    os_build,
    architecture,
    hardware_model,
    logical_cpu_count,
    memory_bytes,
    screen_locked_state,
    manifest_version,
    generator_version,
    manifest_sha256,
    manifest_file_count,
    file_tree_files,
    file_tree_directories,
    file_tree_levels,
    operation_script_path,
    operation_schema_version,
    workload_id,
    operation_script_sha256,
    metric_contract_path,
    metric_schema_version,
    contract_id,
    metric_contract_sha256,
    trial_count,
    idle_sample_count,
    idle_sample_interval_seconds,
    startup_timeout_seconds,
) = sys.argv[1:]

runs_root = pathlib.Path(runs_root)
output_path = pathlib.Path(output_path)

canonical_metrics = [
    "launch.cold_to_first_interactive",
    "launch.warm_to_first_interactive",
    "launch.backend_setup",
    "launch.frontend_first_paint_after_load",
    "idle.rss",
    "idle.cpu",
    "idle.process_count",
    "idle.energy_impact",
    "terminal.flood_cpu",
    "terminal.frame_time",
    "terminal.dropped_frame_ratio",
    "terminal.input_to_glyph",
    "file.open",
    "file.scroll",
    "file.edit",
    "file.find",
    "file.save",
    "tree.enumerate",
    "tree.find",
    "git.status",
    "pty.reattach",
]

try:
    operation_script_bytes = pathlib.Path(operation_script_path).read_bytes()
    operation_script_document = json.loads(operation_script_bytes)
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"cannot re-read operation script during result generation: {error}")
if hashlib.sha256(operation_script_bytes).hexdigest() != operation_script_sha256:
    raise SystemExit("operation script changed during collection")
if (
    operation_script_document.get("schema_version") != int(operation_schema_version)
    or operation_script_document.get("workload_id") != workload_id
):
    raise SystemExit("operation script identity changed during collection")

try:
    metric_contract_bytes = pathlib.Path(metric_contract_path).read_bytes()
    metric_contract_document = json.loads(metric_contract_bytes)
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"cannot re-read metric contract during result generation: {error}")
if hashlib.sha256(metric_contract_bytes).hexdigest() != metric_contract_sha256:
    raise SystemExit("metric contract changed during collection")
if (
    metric_contract_document.get("schema_version") != int(metric_schema_version)
    or metric_contract_document.get("contract_id") != contract_id
):
    raise SystemExit("metric contract identity changed during collection")
contract_metric_names = set(metric_contract_document.get("metrics", {}))
canonical_metric_names = set(canonical_metrics)
if contract_metric_names != canonical_metric_names:
    missing = sorted(contract_metric_names - canonical_metric_names)
    extra = sorted(canonical_metric_names - contract_metric_names)
    raise SystemExit(
        "collector canonical metrics do not match metric contract; "
        f"missing={missing}, extra={extra}"
    )

manual_metric_reasons = {
    "idle.energy_impact": (
        "Power Profiler was not run by the process/log collector",
        "Instruments Power Profiler",
    ),
    "terminal.flood_cpu": (
        "the fixed terminal flood workload requires a controlled UI/PTY run",
        "manual UI or automation driver",
    ),
    "terminal.frame_time": (
        "rendered frame timing requires an Animation Hitches trace",
        "Instruments Animation Hitches",
    ),
    "terminal.dropped_frame_ratio": (
        "dropped frames require an Animation Hitches trace",
        "Instruments Animation Hitches",
    ),
    "terminal.input_to_glyph": (
        "keyboard-to-visible-glyph timing requires UI event and frame capture",
        "Accessibility/UI timing capture",
    ),
    "file.open": (
        "visible document readiness requires controlled UI interaction",
        "manual UI or automation driver",
    ),
    "file.scroll": (
        "scroll frame timing requires controlled UI interaction and an Animation Hitches trace",
        "Instruments Animation Hitches",
    ),
    "file.edit": (
        "visible edit completion requires controlled UI interaction",
        "manual UI or automation driver",
    ),
    "file.find": (
        "visible find completion requires controlled UI interaction",
        "manual UI or automation driver",
    ),
    "file.save": (
        "the collector does not mutate the read-only-equivalent corpus",
        "manual isolated fixture run",
    ),
    "tree.enumerate": (
        "stable visible tree timing requires controlled UI interaction",
        "manual UI or automation driver",
    ),
    "tree.find": (
        "visible file-tree find completion requires controlled UI interaction",
        "manual UI or automation driver",
    ),
    "git.status": (
        "stable visible Git status timing requires controlled UI interaction",
        "manual UI or automation driver",
    ),
    "pty.reattach": (
        "PTY reattach requires a controlled long-running terminal session",
        "manual PTY lifecycle capture",
    ),
}

field_pattern = re.compile(
    r'\b(phase|kind|ms|since_load_ms)=(?:"([^"\\]*(?:\\.[^"\\]*)*)"|([^\s]+))'
)
safe_phase_pattern = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")


def not_measured(reason, capability=None):
    record = {"status": "not-measured", "reason": reason}
    if capability:
        record["capability"] = capability
    return record


def measured(value, unit, **metadata):
    record = {"status": "measured", "value": round(float(value), 3), "unit": unit}
    record.update(metadata)
    return record


def parse_number(value):
    try:
        number = float(value.rstrip(","))
    except (AttributeError, ValueError):
        return None
    if not math.isfinite(number) or number < 0:
        return None
    return number


def parse_perf_phases(path):
    events = []
    total_events = 0
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        return events, False

    for line in lines:
        if "ccedit::perf" not in line:
            continue
        fields = {}
        for match in field_pattern.finditer(line):
            value = match.group(2) if match.group(2) is not None else match.group(3)
            fields[match.group(1)] = value
        phase = fields.get("phase")
        duration_ms = parse_number(fields.get("ms"))
        if not phase or not safe_phase_pattern.fullmatch(phase) or duration_ms is None:
            continue
        total_events += 1
        if len(events) >= 256:
            continue
        event = {
            "phase": phase,
            "value": round(duration_ms, 3),
            "unit": "ms",
            "origin": "frontend" if phase.startswith("fe.") else "backend",
        }
        kind = fields.get("kind")
        if kind in {"mark", "measure"}:
            event["kind"] = kind
        since_load_ms = parse_number(fields.get("since_load_ms"))
        if since_load_ms is not None:
            event["since_load_ms"] = round(since_load_ms, 3)
        events.append(event)
    return events, total_events > len(events)


def read_process_samples(path):
    samples = []
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return samples
    for line in lines:
        fields = line.split("\t")
        if len(fields) != 5:
            continue
        try:
            sample_index = int(fields[0])
            offset_seconds = int(fields[1])
            rss_mib = float(fields[2]) / 1024.0
            cpu_percent = float(fields[3])
            process_count = int(fields[4])
        except ValueError:
            continue
        if (
            sample_index < 1
            or offset_seconds < 0
            or not math.isfinite(rss_mib)
            or not math.isfinite(cpu_percent)
            or rss_mib < 0
            or cpu_percent < 0
            or process_count < 1
        ):
            continue
        samples.append(
            {
                "sample": sample_index,
                "offset_seconds": offset_seconds,
                "rss_mib": round(rss_mib, 3),
                "cpu_percent": round(cpu_percent, 3),
                "process_count": process_count,
            }
        )
    return samples


def sample_metric(samples, key, unit):
    values = [sample[key] for sample in samples]
    if not values:
        return not_measured("the app process family could not be sampled")
    return measured(
        statistics.median(values),
        unit,
        aggregation=["median", "max"],
        max=round(max(values), 3),
        sample_count=len(values),
    )


def find_phase(events, phase):
    for event in events:
        if event["phase"] == phase:
            return event
    return None


runs = []
for run_dir in sorted(path for path in runs_root.iterdir() if path.is_dir()):
    run_id = run_dir.name
    launch_kind = (run_dir / "kind").read_text().strip()
    shell_status = (run_dir / "status").read_text().strip()
    shell_reason = (run_dir / "reason").read_text().strip()
    phases, phases_truncated = parse_perf_phases(run_dir / "app.log")
    samples = read_process_samples(run_dir / "process-samples.tsv")

    backend_setup = find_phase(phases, "boot.setup_total")
    first_paint = find_phase(phases, "fe.first_paint_after_raf")
    metrics = {
        "launch.cold_to_first_interactive": not_measured(
            "first usable UI was not probed; a first-paint log marker is not equivalent to interactivity",
            "controlled UI interaction",
        ),
        "launch.warm_to_first_interactive": not_measured(
            "first usable UI was not probed; a first-paint log marker is not equivalent to interactivity",
            "controlled UI interaction",
        ),
        "launch.backend_setup": (
            measured(
                backend_setup["value"],
                "ms",
                phase="boot.setup_total",
                aggregation="single-observation",
            )
            if backend_setup
            else not_measured("ccedit did not emit the boot.setup_total perf phase")
        ),
        "launch.frontend_first_paint_after_load": (
            measured(
                first_paint.get("since_load_ms", first_paint["value"]),
                "ms",
                phase="fe.first_paint_after_raf",
                aggregation="single-observation",
            )
            if first_paint
            else not_measured("ccedit did not emit the fe.first_paint_after_raf perf phase")
        ),
        "idle.rss": sample_metric(samples, "rss_mib", "MiB"),
        "idle.cpu": sample_metric(samples, "cpu_percent", "%"),
        "idle.process_count": sample_metric(samples, "process_count", "count"),
    }
    for metric_name, (reason, capability) in manual_metric_reasons.items():
        metrics[metric_name] = not_measured(reason, capability)

    run_status = shell_status
    reasons = [reason for reason in shell_reason.split(";") if reason]
    if run_status == "measured" and (
        metrics["launch.backend_setup"]["status"] != "measured"
        or metrics["launch.frontend_first_paint_after_load"]["status"] != "measured"
        or len(samples) < int(idle_sample_count)
    ):
        run_status = "partial"
        reasons.append("required automated evidence is incomplete")

    run = {
        "id": run_id,
        "launch_kind": launch_kind,
        "status": run_status,
        "metrics": metrics,
        "process_samples": samples,
        "perf_phases": phases,
    }
    if reasons:
        run["reason"] = "; ".join(dict.fromkeys(reasons))
    if phases_truncated:
        run["perf_phases_truncated"] = True
    runs.append(run)

if not runs:
    raise SystemExit("collector produced no measured run records")


def nearest_rank_p95(values):
    ordered = sorted(values)
    rank = max(1, math.ceil(0.95 * len(ordered)))
    return ordered[rank - 1]


def trial_distribution(values):
    distribution = {
        "median": round(statistics.median(values), 3),
        "sample_count": len(values),
    }
    if len(values) >= 20:
        distribution["aggregation"] = ["median", "p95"]
        distribution["p95"] = round(nearest_rank_p95(values), 3)
    else:
        distribution["aggregation"] = ["median", "max"]
        distribution["max"] = round(max(values), 3)
    return distribution


def operation_summary(metric_name, unit):
    values = [
        run["metrics"][metric_name]["value"]
        for run in runs
        if run["metrics"][metric_name]["status"] == "measured"
    ]
    if not values:
        return not_measured(f"no run measured {metric_name}")
    by_kind = {}
    for launch_kind in ("fresh-profile", "warm"):
        kind_values = [
            run["metrics"][metric_name]["value"]
            for run in runs
            if run["launch_kind"] == launch_kind
            and run["metrics"][metric_name]["status"] == "measured"
        ]
        if kind_values:
            by_kind[launch_kind] = trial_distribution(kind_values)
    distribution = trial_distribution(values)
    return measured(
        distribution.pop("median"),
        unit,
        by_launch_kind=by_kind,
        **distribution,
    )


def resource_summary(key, unit):
    values = [sample[key] for run in runs for sample in run["process_samples"]]
    if not values:
        return not_measured(f"no process samples measured {key}")
    return measured(
        statistics.median(values),
        unit,
        aggregation=["median", "max"],
        max=round(max(values), 3),
        sample_count=len(values),
    )


summary = {
    "launch.cold_to_first_interactive": not_measured(
        "first usable UI requires controlled interaction and was not inferred from first paint",
        "controlled UI interaction",
    ),
    "launch.warm_to_first_interactive": not_measured(
        "first usable UI requires controlled interaction and was not inferred from first paint",
        "controlled UI interaction",
    ),
    "launch.backend_setup": operation_summary("launch.backend_setup", "ms"),
    "launch.frontend_first_paint_after_load": operation_summary(
        "launch.frontend_first_paint_after_load", "ms"
    ),
    "idle.rss": resource_summary("rss_mib", "MiB"),
    "idle.cpu": resource_summary("cpu_percent", "%"),
    "idle.process_count": resource_summary("process_count", "count"),
}
for metric_name, (reason, capability) in manual_metric_reasons.items():
    summary[metric_name] = not_measured(reason, capability)

coverage = []
for metric_name in canonical_metrics:
    metric = summary[metric_name]
    entry = {"metric": metric_name, "status": metric["status"]}
    if metric["status"] == "measured":
        entry["measured_runs"] = sum(
            1 for run in runs if run["metrics"][metric_name]["status"] == "measured"
        )
        entry["total_runs"] = len(runs)
    else:
        entry["reason"] = metric["reason"]
        if "capability" in metric:
            entry["capability"] = metric["capability"]
    coverage.append(entry)


def integer_or_unknown(value):
    try:
        return int(value)
    except ValueError:
        return "unknown"


result = {
    "schema_version": 1,
    "source": {
        "repository": "Diwamoto/ccedit",
        "commit": source_commit,
        "build": {
            "mode": "release",
            "bundle_identifier": bundle_identifier,
            "bundle_version": bundle_version or "unknown",
            "short_version": short_version or "unknown",
            "executable_sha256": executable_sha256,
            "identity_override": {
                "from": "dev.daiki.ccedit",
                "to": bundle_identifier,
            },
        },
    },
    "environment": {
        "captured_at_utc": captured_at_utc,
        "os": {"name": "macOS", "version": os_version, "build": os_build},
        "hardware": {
            "architecture": architecture,
            "model": hardware_model,
            "logical_cpu_count": integer_or_unknown(logical_cpu_count),
            "memory_bytes": integer_or_unknown(memory_bytes),
        },
        "session": {
            "screen_locked": (
                True
                if screen_locked_state == "true"
                else False
                if screen_locked_state == "false"
                else not_measured("IOConsoleLocked could not be read from the I/O Registry")
            ),
            "user_name_recorded": False,
            "session_uuid_recorded": False,
        },
        "display": not_measured(
            "display identity, scale, and window geometry require a UI-capable capture",
            "CoreGraphics/UI capture",
        ),
        "privacy": {
            "account_directory_policy": "sandbox denied except benchmark bundle storage",
            "benchmark_storage_preexisting": False,
            "benchmark_storage_cleaned_after_capture": True,
            "host_name_recorded": False,
            "user_name_recorded": False,
            "process_ids_recorded": False,
            "absolute_paths_recorded": False,
        },
    },
    "workload": {
        "corpus": {
            "label": "clair benchmark corpus",
            "manifest_version": int(manifest_version),
            "generator_version": generator_version,
            "manifest_sha256": manifest_sha256,
            "manifest_file_count": int(manifest_file_count),
            "file_tree_profile": {
                "files": int(file_tree_files),
                "directories": integer_or_unknown(file_tree_directories),
                "levels_below_root": integer_or_unknown(file_tree_levels),
            },
        },
        "operation_script": {
            "schema_version": int(operation_schema_version),
            "workload_id": workload_id,
            "sha256": operation_script_sha256,
        },
        "metric_contract": {
            "schema_version": int(metric_schema_version),
            "contract_id": contract_id,
            "sha256": metric_contract_sha256,
        },
        "trial_policy": {
            "warmups_excluded": {"fresh-profile": 1, "warm": 1},
            "measured_trials": {
                "fresh-profile": int(trial_count),
                "warm": int(trial_count),
            },
            "fresh_profile_policy": (
                "new benchmark-only app profile for every launch; OS and filesystem "
                "caches are not flushed, so this is not an OS-cold launch"
            ),
            "warm_profile_policy": (
                "one benchmark-only app profile reused after one excluded warm-up"
            ),
            "first_paint_timeout_seconds": int(startup_timeout_seconds),
            "idle_sample_count_per_run": int(idle_sample_count),
            "idle_sample_interval_seconds": int(idle_sample_interval_seconds),
        },
        "process_family_definition": "root app process plus recursive descendants in each ps snapshot",
        "app_launch": "unmodified bundle executable launched by sandbox-exec in a private process group",
        "sandbox": {
            "baseline": "allow default, then deny account directory",
            "read_only_exceptions": ["benchmark app bundle", "synthetic corpus"],
            "read_write_exceptions": [
                "benchmark bundle application support",
                "benchmark bundle caches",
                "benchmark bundle WebKit data",
                "benchmark bundle preferences",
                "collector scratch",
            ],
        },
        "rust_log": "info,ccedit_lib=debug,ccedit::perf=info,ccedit::perf::fe=info",
    },
    "runs": runs,
    "summary": summary,
    "coverage": coverage,
}

output_path.write_text(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False) + "\n")
PY

chmod 0644 "$output_temp"
if ! ln "$output_temp" "$output_path" 2>/dev/null; then
  die "output appeared during collection; refusing to overwrite it"
fi
rm -f -- "$output_temp"
output_temp=""

if ((failure_count > 0)); then
  warn "wrote a partial result with $failure_count failed or incomplete run(s): $output_path"
  exit 1
fi

echo "collected ccedit V1 baseline: $output_path"
