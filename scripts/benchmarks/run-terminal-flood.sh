#!/usr/bin/env bash

set -euo pipefail

corpus_dir=""
repeats=100

usage() {
  cat <<'USAGE'
Usage: run-terminal-flood.sh --corpus DIRECTORY [--repeats COUNT]

Write the deterministic 1 MiB benchmark payload COUNT times to stdout.
USAGE
}

while (($# > 0)); do
  case "$1" in
    --corpus)
      (($# >= 2)) || { echo "--corpus requires a directory" >&2; exit 2; }
      corpus_dir="$2"
      shift 2
      ;;
    --repeats)
      (($# >= 2)) || { echo "--repeats requires a count" >&2; exit 2; }
      repeats="$2"
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

[[ -n "$corpus_dir" ]] || { echo "--corpus is required" >&2; exit 2; }
[[ "$repeats" =~ ^[1-9][0-9]*$ ]] || { echo "--repeats must be a positive integer" >&2; exit 2; }

payload="$corpus_dir/terminal/flood-1MiB.txt"
[[ -f "$payload" ]] || { echo "missing terminal payload: $payload" >&2; exit 1; }

payload_bytes="$(wc -c < "$payload" | tr -d ' ')"
[[ "$payload_bytes" == "1048576" ]] || { echo "terminal payload must be exactly 1048576 bytes" >&2; exit 1; }

total_bytes=$((payload_bytes * repeats))
printf 'CLAIR_BENCHMARK_START terminal-flood-v1 bytes=%d repeats=%d\n' "$total_bytes" "$repeats" >&2

repeat_index=0
while ((repeat_index < repeats)); do
  command cat "$payload"
  repeat_index=$((repeat_index + 1))
done

printf '\nCLAIR_BENCHMARK_END terminal-flood-v1 bytes=%d repeats=%d\n' "$total_bytes" "$repeats" >&2
