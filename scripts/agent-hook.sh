#!/bin/sh

# Clair's optional official-agent-hook sink. Configure an agent's documented
# hook command as: sh "$CLAIR_AGENT_HOOK_RECEIVER"
#
# The launch profile supplies a private per-session JSONL path. Keep the
# receiver deliberately boring: it does not interpret agent payloads or print
# them to the terminal, and it removes physical newlines so one hook invocation
# is one record for Clair's bounded decoder.

set -eu

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
