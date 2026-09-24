#!/usr/bin/env bash
set -euo pipefail

# BUDGET-OP-100 (docs/benchmarks/clair-v2-performance-budget.md §1).
#
# Runs the operation budget suite in Release and files the report under
# docs/benchmarks/results/. Release is not optional: a Debug number is 2-4x
# slower here and would condemn operations that actually ship inside budget.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
core_package="$repo_root/packages/ClairCore"

regenerate=0
out_file=""

usage() {
  cat <<'USAGE'
Usage: run-budget.sh [--regenerate] [--out FILE]

  --regenerate  discard the cached adversarial corpus and rebuild it
  --out FILE    JSON report path (default docs/benchmarks/results/<date>-<hw.model>/budget.json)
USAGE
}

while (($# > 0)); do
  case "$1" in
    --regenerate) regenerate=1; shift ;;
    --out) out_file="$2"; shift 2 ;;
    --help | -h) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ((regenerate)); then
  printf 'budget: discarding cached corpora...\n'
  rm -rf /tmp/clair-perf-corpus-v*
fi

if [[ -z "$out_file" ]]; then
  out_file="$repo_root/docs/benchmarks/results/$(date -u +%Y-%m-%d)-$(sysctl -n hw.model)/budget.json"
fi

printf 'budget: running the operation budget suite (release)...\n'
# -enable-testing: the suite reaches internal API (`WorkbenchFiles.gitStatus`,
# `WorkbenchState.refreshStatus`) that the product does not expose publicly.
CLAIR_PERF=1 \
CLAIR_PERF_OUT="$out_file" \
  swift test -c release -Xswiftc -enable-testing \
    --package-path "$core_package" --parallel --num-workers 1 \
    --filter PerformanceBudgetTests
status=$?

printf 'budget: wrote %s\n' "$out_file"
exit "$status"
