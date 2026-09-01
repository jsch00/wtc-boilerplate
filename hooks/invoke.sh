#!/usr/bin/env bash
# Find this collection's agent-env.sh and exec it. Used as the command in
# agent-env.json so the hook JSON does not have to hard-code a worktree path.
# Fail-open: not in a collection, or the script is missing → exit 0.
set -u
mode="${1:---write}"

try_exec() {
  [ -x "$1" ] || return 1
  exec "$1" "$mode"
}

d="${GROK_WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-${PWD:-/}}}"
while [ -n "$d" ] && [ "$d" != "/" ]; do
  try_exec "$d/harness/tools/agent-env.sh"
  d="$(dirname "$d")"
done

here="$(cd "$(dirname "$0")" && pwd)"
try_exec "$here/../tools/agent-env.sh"
try_exec "$here/../harness/tools/agent-env.sh"
try_exec "$here/../../harness/tools/agent-env.sh"

exit 0
