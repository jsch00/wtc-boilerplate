#!/usr/bin/env bash
# wtc-open.sh — open collections as herdr workspaces (terminal ergonomics).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  tools/wtc-open.sh [options] [<collection> ...]
  tools/wtc-open.sh --all [options]
  tools/wtc-open.sh --list

Opens each collection as one workspace in the workspace root's herdr session:
a single tab at the collection root, default panes agent / browse / shell /
status, all carrying the collection env (.env.collection) — so no mise or
shell activation is needed for ports to resolve.

With no <collection>, opens the collection containing this harness worktree.
Re-running is safe: an existing workspace with that label is reused, never
duplicated. The herdr session is started headless if it is not running; you
attach to it yourself with `herdr --session <name>`.

A workspace holds no state — it is a view onto worktrees that already exist
(AGENTS.md → "State lives in git"). Closing it loses nothing; retire.sh
removes it along with the collection.

  --all             every collection in the workspace root
  --list            list the session's workspaces + agent states, then exit
  --session <name>  herdr session (default: workspace-root name minus
                    "-harness"; override with $HARNESS_HERDR_SESSION)
  --agent <kind>    agent kind to start (default: claude; see `herdr agent`)
  --agent-args "…"  args passed to the agent, replacing the default
                    (claude: --dangerously-skip-permissions; a wtc is an
                    isolated worktree on its own branch, so the prompts buy
                    nothing that branch review doesn't already give)
  --no-agent        create the panes but start no agent
  --focus           focus the last opened workspace (default: no focus)
EOF
  exit 1
}

all=no list=no session="" agent_kind=claude start_agent=yes focus=no
agent_args="" agent_args_set=no
while [ $# -gt 0 ]; do
  case "$1" in
    --all) all=yes; shift ;;
    --list) list=yes; shift ;;
    --session) session="${2:?--session needs a name}"; shift 2 ;;
    --agent) agent_kind="${2:?--agent needs a kind}"; shift 2 ;;
    --agent-args) agent_args="${2-}"; agent_args_set=yes; shift 2 ;;
    --no-agent) start_agent=no; shift ;;
    --focus) focus=yes; shift ;;
    -h|--help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
done

script_dir="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(dirname "$script_dir")"
. "$script_dir/lib.sh"
harness_lib_init

herdr_present || { echo "error: herdr is not installed (see instructions/herdr.md)" >&2; exit 1; }
[ -n "$session" ] || session="$(herdr_session_name)"

if [ "$agent_args_set" = no ] && [ "$agent_kind" = claude ]; then
  agent_args="--dangerously-skip-permissions"
fi

if [ "$list" = yes ]; then
  if ! herdr_session_running "$session"; then
    echo "herdr session '$session': not running"
    exit 0
  fi
  echo "herdr session '$session':"
  herdr_ws_pairs "$session" \
    | awk -F'\t' '{ printf "  %-28s %s\n", $1, $3 }' \
    | sort
  echo "attach: herdr --session $session"
  exit 0
fi

# Which collections? Explicit args, --all, or the one holding this harness.
collections=""
if [ "$all" = yes ]; then
  for d in "$ROOT"/*/; do
    d="${d%/}"
    [ -d "$d/harness" ] || continue
    collections="$collections $(basename "$d")"
  done
elif [ $# -gt 0 ]; then
  collections="$*"
else
  here="$(cd "$HARNESS_DIR/.." && pwd)"
  [ -d "$here/harness" ] || { echo "error: $here is not a collection; name one explicitly" >&2; exit 1; }
  collections="$(basename "$here")"
fi
[ -n "${collections// /}" ] || { echo "error: no collections found under $ROOT" >&2; exit 1; }

herdr_ensure_session "$session"

open_collection() { # <collection>
  name="$1"
  dir="$ROOT/$name"
  [ -d "$dir/harness" ] || { echo "skip: $name is not a collection (no harness/)" >&2; return 0; }

  ws_id="$(herdr_ws_id "$session" "$name")"
  if [ -n "$ws_id" ]; then
    echo "==> $name: workspace $ws_id already open — reusing"
    agent_pane="$(herdr_pane_id_by_label "$session" "$ws_id" agent)"
  else
    # Collection env into both panes, so ports resolve without mise.
    set -- create --cwd "$dir" --label "$name" --no-focus
    if [ -f "$dir/.env.collection" ]; then
      while IFS= read -r kv; do
        case "$kv" in ''|\#*) continue ;; esac
        set -- "$@" --env "$kv"
      done < "$dir/.env.collection"
    fi

    ws_out="$(herdr --session "$session" workspace "$@")"
    ws_id="$(printf '%s' "$ws_out" | tr '{}' '\n\n' | sed -n 's/.*"workspace_id":"\([^"]*\)".*/\1/p' | head -n1)"
    agent_pane="$(printf '%s' "$ws_out" | herdr_first_pane_id)"
    [ -n "$agent_pane" ] || { echo "error: $name: could not read the new pane id" >&2; return 1; }

    # Default layout: agent is the full-height left column; browse (nvim)
    # is the human pane on the right; terminal and status split under it.
    #   [ agent | browse        ]
    #   [       | shell | status]
    browse_pane="$(herdr --session "$session" pane split "$agent_pane" \
      --direction right --ratio 0.40 --cwd "$dir" --no-focus | herdr_first_pane_id)"
    herdr --session "$session" pane rename "$agent_pane" agent >/dev/null
    if [ -n "$browse_pane" ]; then
      herdr --session "$session" pane rename "$browse_pane" browse >/dev/null
      shell_pane="$(herdr --session "$session" pane split "$browse_pane" \
        --direction down --ratio 0.70 --cwd "$dir" --no-focus | herdr_first_pane_id)"
    else
      shell_pane="$(herdr --session "$session" pane split "$agent_pane" \
        --direction right --cwd "$dir" --no-focus | herdr_first_pane_id)"
    fi
    if [ -n "$shell_pane" ]; then
      herdr --session "$session" pane rename "$shell_pane" shell >/dev/null
    fi
  fi

  # browse / status — added to workspaces opened before they existed.
  herdr_ensure_browse_pane "$session" "$ws_id" "$dir" >/dev/null || true

  if [ -z "$(herdr_pane_id_by_label "$session" "$ws_id" status)" ]; then
    # Prefer beside the shell (under browse). Fall back to under the shell
    # on a pre-browse workspace where the right column is already stacked.
    base="$(herdr_pane_id_by_label "$session" "$ws_id" shell)"
    split_dir=right
    if [ -z "$base" ]; then
      base="$(herdr_pane_id_by_label "$session" "$ws_id" browse)"
      split_dir=down
    fi
    if [ -n "$base" ]; then
      status_pane="$(herdr --session "$session" pane split "$base" \
        --direction "$split_dir" --cwd "$dir" --no-focus | herdr_first_pane_id)"
      herdr --session "$session" pane rename "$status_pane" status >/dev/null
      sleep 2   # let the shell reach its prompt before it is typed at
      herdr --session "$session" pane run "$status_pane" \
        "$script_dir/wtc-status.sh --repos --watch 120 $name" >/dev/null
    fi
  fi

  if [ "$start_agent" = yes ] && [ -n "$agent_pane" ] \
     && ! herdr_pane_has_agent "$session" "$agent_pane"; then
    # Agent names: [a-z][a-z0-9_-]{0,31}, unique among live agents.
    agent_name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' | cut -c1-32)"
    echo "==> $name: starting $agent_kind as '$agent_name' in $agent_pane"
    # A freshly created pane needs a moment before its shell is "available".
    # Intentional word-splitting: $agent_args is a flag string, not a path.
    # shellcheck disable=SC2086
    set -- start "$agent_name" --kind "$agent_kind" --pane "$agent_pane"
    if [ -n "$agent_args" ]; then
      set -- "$@" -- $agent_args
    fi
    n=0
    until err="$(herdr --session "$session" agent "$@" 2>&1 >/dev/null)"; do
      n=$((n + 1))
      if [ "$n" -ge 15 ]; then
        echo "error: $name: could not start $agent_kind in $agent_pane: $err" >&2
        return 1
      fi
      sleep 1
    done
  fi

  if [ "$focus" = yes ] && [ -n "$ws_id" ]; then
    herdr --session "$session" workspace focus "$ws_id" >/dev/null
  fi
  echo "==> $name: workspace $ws_id ready"
  return 0
}

for c in $collections; do
  open_collection "$c"
done

echo "attach: herdr --session $session"
