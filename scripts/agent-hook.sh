#!/bin/sh

# Clair's optional official-agent-hook sink. Configure an agent's documented
# hook command as: sh "$CLAIR_AGENT_HOOK_RECEIVER"
#
# The launch profile supplies a private per-session JSONL path. Keep the
# receiver deliberately boring: it does not interpret agent payloads or print
# them to the terminal, and it removes physical newlines so one hook invocation
# is one record for Clair's bounded decoder.

set -eu

# Status-line mode preserves the original command's stdin and stdout. Only the
# small rate_limits object is persisted, atomically, in Clair's private cache.
if [ "${1:-}" = "--status-line" ]; then
  cache=$2
  original=${3:-}
  umask 077
  payload=$(mktemp)
  limits=""
  trap 'rm -f "$payload"; [ -z "$limits" ] || rm -f "$limits"' EXIT
  cat >"$payload"
  if mkdir -p "$(dirname "$cache")"; then
    limits=$(mktemp "${cache}.XXXXXX")
    if /usr/bin/plutil -extract rate_limits json -o "$limits" "$payload" 2>/dev/null &&
      { /usr/bin/plutil -extract five_hour.used_percentage raw -o /dev/null "$limits" 2>/dev/null ||
        /usr/bin/plutil -extract seven_day.used_percentage raw -o /dev/null "$limits" 2>/dev/null; }; then
      mv -f "$limits" "$cache"
    fi
  fi
  if [ -n "$original" ]; then
    /bin/sh -c "$original" <"$payload"
  fi
  exit 0
fi

hook_file=${CLAIR_AGENT_HOOK_FILE:-}
if [ -z "$hook_file" ]; then
  cat >/dev/null
  exit 0
fi

hook_directory=$(dirname "$hook_file")
umask 077
mkdir -p "$hook_directory"
LC_ALL=C tr -d '\r\n' >>"$hook_file"
printf '\n' >>"$hook_file"
