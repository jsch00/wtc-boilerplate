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
  --no-remote-control
                    start claude without Remote Control. On by default for
                    claude started with the default args — passing
                    --agent-args replaces those wholesale and leaves it off.
                    With it, the session appears in the Claude mobile app and
                    on claude.ai, named for the collection. Start-time only —
                    a session started without it cannot be attached later
  --no-agent        create the panes but start no agent
  --no-browse       leave the browse pane at a shell prompt. By default it
                    opens LazyVim on the collection (tools/wtc-browse.sh)
                    when nvim is on PATH, which is what that pane is for — a
                    workspace whose human pane is an empty prompt asks you to
                    type the one command it already knows. Without nvim the
                    pane is left alone either way
  --focus           focus the last opened workspace (default: no focus)
EOF
  exit 1
}

all=no list=no session="" agent_kind=claude start_agent=yes focus=no
agent_args="" agent_args_set=no remote_control=yes start_browse=yes
while [ $# -gt 0 ]; do
  case "$1" in
    --all) all=yes; shift ;;
    --list) list=yes; shift ;;
    --session) session="${2:?--session needs a name}"; shift 2 ;;
    --agent) agent_kind="${2:?--agent needs a kind}"; shift 2 ;;
    --agent-args) agent_args="${2-}"; agent_args_set=yes; shift 2 ;;
    --no-remote-control) remote_control=no; shift ;;
    --no-agent) start_agent=no; shift ;;
    --no-browse) start_browse=no; shift ;;
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

  # Open the browse pane on the collection. Re-query by label rather than
  # trusting the id above: on a crowded tab that helper falls back to the
  # shell pane, and a shell is not something to replace with a TUI.
  if [ "$start_browse" = yes ]; then
    browse_id="$(herdr_pane_id_by_label "$session" "$ws_id" browse)"
    if [ -n "$browse_id" ] && command -v nvim >/dev/null 2>&1; then
      case "$(herdr_pane_fg_name "$session" "$browse_id")" in
        nvim)
          : ;;   # already browsing this collection
        ''|zsh|bash|fish|sh|nu)
          sleep 2   # a fresh pane needs its prompt before it is typed at
          # `pane run` takes a shell command string, so both halves are quoted:
          # a collection directory may contain spaces, and anything unquoted
          # here would be evaluated by that pane's shell.
          printf -v browse_cmd '%q --here %q' "$script_dir/wtc-browse.sh" "$name"
          herdr --session "$session" pane run "$browse_id" \
            "$browse_cmd" >/dev/null || true
          ;;
        *)
          : ;;   # someone's TUI is in there; leave it alone
      esac
    fi
  fi


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
      printf -v status_cmd '%q --repos --watch 120 %q' \
        "$script_dir/wtc-status.sh" "$name"
      herdr --session "$session" pane run "$status_pane" \
        "$status_cmd" >/dev/null
    fi
  fi

  if [ "$start_agent" = yes ] && [ -n "$agent_pane" ] \
     && ! herdr_pane_has_agent "$session" "$agent_pane"; then
    # Agent names: [a-z][a-z0-9_-]{0,31}, unique among live agents.
    agent_name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' | cut -c1-32)"
    echo "==> $name: starting $agent_kind as '$agent_name' in $agent_pane"
    # Remote Control puts this session in the Claude mobile app and claude.ai.
    # The whole point of a wtc agent is that it keeps working while you are not
    # at this machine, and a collection you cannot check on from a phone misses
    # half of that. Claude only accepts it at START time — there is no
    # in-session toggle — so it is decided here or not at all, and the remote
    # session is named for the collection so the mobile list reads like the
    # workspace does. Only applies to the default claude args: --agent-args or
    # --no-remote-control leave it off.
    this_agent_args="$agent_args"
    if [ "$remote_control" = yes ] && [ "$agent_args_set" = no ] && [ "$agent_kind" = claude ]; then
      this_agent_args="$this_agent_args --remote-control $agent_name"
    fi

    # A freshly created pane needs a moment before its shell is "available".
    # Intentional word-splitting: $agent_args is a flag string, not a path.
    # shellcheck disable=SC2086
    set -- start "$agent_name" --kind "$agent_kind" --pane "$agent_pane"
    if [ -n "$this_agent_args" ]; then
      set -- "$@" -- $this_agent_args
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
