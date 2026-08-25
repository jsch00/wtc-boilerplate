# lib.sh — shared helpers for harness tools. Source this, don't execute it.
# Bash 3.2-safe (macOS default): no mapfile, no associative arrays.
#
# Callers must set HARNESS_DIR (the harness worktree, i.e. dirname of tools/)
# and then call harness_lib_init. Provides: ROOT, REGISTRY, LOCAL_REPOS and
# the functions below.

harness_lib_init() {
  ROOT="$HARNESS_DIR"
  while [ "$ROOT" != "/" ] && [ ! -d "$ROOT/.bare" ]; do
    ROOT="$(dirname "$ROOT")"
  done
  [ -d "$ROOT/.bare" ] || { echo "error: no .bare/ found above $HARNESS_DIR" >&2; exit 1; }
  REGISTRY="$HARNESS_DIR/.harness-repos.yml"
  LOCAL_REPOS="$HARNESS_DIR/.harness-repos"
  [ -f "$REGISTRY" ] || { echo "error: $REGISTRY missing" >&2; exit 1; }
}

# The collection folder is always `harness/`; the repo behind it is whatever
# you named your fork of this one. Set WTC_HARNESS_REPO to that name — it has
# to match the bare in `.bare/` and the `name:` in the registry.
harness_repo() {
  printf '%s\n' "${WTC_HARNESS_REPO:-agent-harness}"
}

registry_field() { # <repo-name> <field> — one scalar field from the repo's block
  # Soft-fail when the file is gone (a status --watch still running after its
  # harness worktree was retired) rather than dumping awk noise into the table.
  [ -f "$REGISTRY" ] || return 0
  awk -v repo="$1" -v field="$2:" '
    $1 == "-" && $2 == "name:"   { cur = $3 }
    cur == repo && $1 == field   { print $2; exit }
  ' "$REGISTRY"
}

registry_all_names() {
  [ -f "$REGISTRY" ] || return 0
  awk '$1 == "-" && $2 == "name:" { print $3 }' "$REGISTRY"
}

bare_for() { # <repo-name> -> bare path (local file first, then convention)
  bare=""
  if [ -f "$LOCAL_REPOS" ]; then
    bare="$(sed -n "s|^$1=||p" "$LOCAL_REPOS" | head -n1)"
  fi
  [ -n "$bare" ] || bare="$ROOT/.bare/$1.git"
  printf '%s\n' "$bare"
}

# Where a worktree's refs actually live. bare_for maps a NAME onto the
# `.bare/` convention and so only knows registry repos; this asks the worktree
# itself and therefore also resolves unmanaged `ext.` siblings, whose owner is
# an ordinary clone outside the workspace
# (instructions/worktree-workspace.md). Prefer it wherever a worktree is
# already in hand — fetching and teardown both need the real owner, not the
# path a registry name would have implied.
owner_of() { # <worktree> -> absolute git common dir, or empty
  git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true
}

default_ref_for() { # <repo-name> -> default_ref from registry (fallback origin/main)
  ref="$(registry_field "$1" default_ref)"
  [ -n "$ref" ] || ref="origin/main"
  printf '%s\n' "$ref"
}

ensure_bare() { # <repo-name> — clone the bare owner from the registry remote if missing
  repo="$1"
  bare="$(bare_for "$repo")"
  [ -d "$bare" ] && return 0
  remote="$(registry_field "$repo" remote)"
  [ -n "$remote" ] || { echo "error: '$repo' not in $REGISTRY (no remote)" >&2; exit 1; }
  echo "==> $repo: bare owner missing — cloning $remote"
  git clone --bare "$remote" "$bare"
  git --git-dir="$bare" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git --git-dir="$bare" fetch --all --prune
}

file_age_secs() { # <file> -> age in seconds, or a huge number if absent
  [ -f "$1" ] || { echo 999999999; return 0; }
  # GNU first: `stat -f %m` is valid on GNU coreutils but means "filesystem
  # mount point", a non-numeric string that would crash the $(( )) below.
  m="$(stat -c %Y "$1" 2>/dev/null || true)"
  case "$m" in ''|*[!0-9]*) m="$(stat -f %m "$1" 2>/dev/null || true)" ;; esac
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  echo $(($(date +%s) - m))
}

# Working on stale refs is how you write a PR against a base that moved a week
# ago. Fetching is cheap; fetching on every redraw of a --watch pane is not,
# hence the age gate rather than a flag nobody remembers to pass.
fetch_if_stale() { # <bare> [max-age-secs, default 300] -> 0 if refs are fresh
  bare="$1" max="${2:-300}"
  [ -d "$bare" ] || return 1
  [ "$(file_age_secs "$bare/FETCH_HEAD")" -lt "$max" ] && return 0
  git --git-dir="$bare" fetch --prune origin >/dev/null 2>&1 || return 1
  return 0
}

# The resting state of a worktree is DETACHED AT THE TIP, not a branch:
#   * a branch can only be checked out in one worktree, so branch-per-collection
#     made the development tip a resource collections had to queue for;
#     detached HEADs let every collection sit on it at once
#   * a branch created before the work has an identity gets the wrong name, and
#     the name is the issue mapping — so branches are created at the first
#     commit, when the name is actually known
# Pass an empty <branch> for that. A non-empty <branch> is an explicit request
# (a PR's head branch, or -b), and still checks out / creates a real branch.
add_worktree() { # <repo-name> <dir-name> <dest-root> <branch-or-empty>
  repo="$1" dir="$2" dest_root="$3" branch="$4"
  ensure_bare "$repo"
  bare="$(bare_for "$repo")"
  ref="$(default_ref_for "$repo")"
  echo "==> $repo: fetch --prune"
  git --git-dir="$bare" fetch --prune origin
  if [ -z "$branch" ]; then
    echo "==> $repo: worktree $dest_root/$dir detached at $ref"
    git --git-dir="$bare" worktree add --detach "$dest_root/$dir" "$ref"
  elif git --git-dir="$bare" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    echo "==> $repo: worktree $dest_root/$dir on existing branch $branch"
    git --git-dir="$bare" worktree add "$dest_root/$dir" "$branch"
  elif git --git-dir="$bare" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null; then
    echo "==> $repo: worktree $dest_root/$dir tracking origin/$branch"
    git --git-dir="$bare" worktree add -b "$branch" "$dest_root/$dir" "origin/$branch"
  else
    echo "==> $repo: worktree $dest_root/$dir on new branch $branch (from $ref)"
    git --git-dir="$bare" worktree add -b "$branch" "$dest_root/$dir" "$ref"
  fi
  trust_mise "$dest_root/$dir"
}

# One reading of "where is this worktree", so the status table and the
# catch-up procedure cannot disagree about what "up to date" means.
#
# The two numbers answer different questions and so use different references:
#   ahead  — work not yet pushed, measured against the branch's own upstream
#            (against the tip when it has no upstream, i.e. never pushed)
#   behind — how stale this worktree is, ALWAYS measured against the
#            development tip. Measuring it against the branch's upstream would
#            report a branch as current while the tip moved a week past it,
#            which is precisely the state catch-up exists to surface.
wt_head_state() { # <worktree> <repo-name> -> "<kind> <label> <ahead> <behind>"
  wt="$1" repo="$2"
  ref="$(default_ref_for "$repo")"
  if git -C "$wt" symbolic-ref -q HEAD >/dev/null 2>&1; then
    kind=branch
    label="$(git -C "$wt" branch --show-current)"
    up="$(git -C "$wt" rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo "$ref")"
  else
    kind=detached
    label="${ref#origin/}"
    up="$ref"
  fi
  ahead="$(git -C "$wt" rev-list --count "$up..HEAD" 2>/dev/null || echo 0)"
  behind="$(git -C "$wt" rev-list --count "HEAD..$ref" 2>/dev/null || echo 0)"
  printf '%s %s %s %s\n' "$kind" "$label" "$ahead" "$behind"
}

trust_mise() { # <dir> — trust dir/mise.toml if mise is installed (no-op otherwise)
  if [ -f "$1/mise.toml" ] && command -v mise >/dev/null 2>&1; then
    mise trust "$1/mise.toml" >/dev/null 2>&1 || true
  fi
}

# Lifecycle hook contract (instructions/hooks-and-env.md). Resolution order:
#   1. repo mise.toml defines task "harness:<hook>" and mise is installed
#   2. executable .harness/<hook>.sh in the repo
#   3. no-op
# A failing hook never fails its caller. Hooks are third-party code living in
# each product repo, and callers run under `set -e`: propagating the failure
# would abort collection creation partway, leaving a half-built collection —
# strictly worse than one repo whose setup did not complete. Report loudly and
# carry on; the operator fixes the repo and re-runs the hook's own tool.
run_hook() { # <worktree-path> <init|teardown>
  wt="$1" hook="$2" status=0
  if [ -f "$wt/mise.toml" ] && command -v mise >/dev/null 2>&1; then
    if (cd "$wt" && mise tasks ls 2>/dev/null | awk '{print $1}' | grep -qx "harness:$hook"); then
      echo "==> hook (mise): harness:$hook in $wt"
      (cd "$wt" && mise run "harness:$hook") || status=$?
      hook_warn "$wt" "$hook" "$status"
      return 0
    fi
  fi
  if [ -x "$wt/.harness/$hook.sh" ]; then
    echo "==> hook (script): .harness/$hook.sh in $wt"
    (cd "$wt" && "./.harness/$hook.sh") || status=$?
    hook_warn "$wt" "$hook" "$status"
    return 0
  fi
  return 0
}

hook_warn() { # <worktree-path> <hook> <status> — no-op on success
  [ "$3" -eq 0 ] && return 0
  echo "WARNING: $2 hook for $(basename "$1") exited $3 — continuing." >&2
  echo "         That worktree may be incompletely set up; see the hook's output above." >&2
  return 0
}

repo_slug_for() { # <repo-name> -> GitHub owner/repo derived from the registry remote
  remote="$(registry_field "$1" remote)"
  printf '%s\n' "${remote#*:}" | sed 's/\.git$//'
}

slug_for_worktree() { # <worktree> [repo-name] -> owner/repo
  # Registry first, because it is a file read and answers for every repo the
  # workspace owns. Falling back to the worktree's own remote is what makes
  # `ext.` siblings work: they are deliberately outside the registry
  # (instructions/worktree-workspace.md), so a registry-only lookup returns
  # nothing and they silently lose every PR column in the table.
  if [ -n "${2:-}" ]; then
    slug="$(repo_slug_for "$2")"
    if [ -n "$slug" ]; then printf '%s\n' "$slug"; return 0; fi
  fi
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 0
  case "$url" in *github.com[:/]*) ;; *) return 0 ;; esac
  slug="${url#*github.com}"; slug="${slug#:}"; slug="${slug#/}"
  printf '%s\n' "${slug%.git}"
}

repo_for_issue_prefix() { # <prefix incl. trailing dash> -> repo name owning it
  awk -v pfx="$1" '
    $1 == "-" && $2 == "name:"          { cur = $3 }
    $1 == "issues_prefix:" && $2 == pfx  { print cur; exit }
  ' "$REGISTRY"
}

alloc_port_base() { # lowest free 42000+100n across existing collections' .env.collection
  base=42000
  while :; do
    used=no
    for f in "$ROOT"/*/.env.collection; do
      [ -f "$f" ] || continue
      b="$(sed -n 's/^COLLECTION_PORT_BASE=//p' "$f" | head -n1)"
      [ "$b" = "$base" ] && used=yes
    done
    if [ "$used" = no ]; then printf '%s\n' "$base"; return; fi
    base=$((base + 100))
  done
}

port_var_for() { # <repo-name> -> env var name, e.g. console -> CONSOLE_PORT
  printf '%s_PORT\n' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
}

# ---------------------------------------------------------------------------
# herdr helpers — terminal ergonomics only. A herdr session is a disposable
# view onto collections that already exist on disk; nothing durable may live
# in it (AGENTS.md → "State lives in git"). Every helper degrades to a no-op
# when herdr is not installed.
# ---------------------------------------------------------------------------

herdr_present() { command -v herdr >/dev/null 2>&1; }

herdr_session_name() { # workspace-root basename minus a trailing "-harness"
  if [ -n "${HARNESS_HERDR_SESSION:-}" ]; then
    printf '%s\n' "$HARNESS_HERDR_SESSION"
    return
  fi
  name="$(basename "$ROOT")"
  printf '%s\n' "${name%-harness}"
}

herdr_session_running() { # <session> — read-only probe; nonzero if no server
  herdr --session "$1" workspace list >/dev/null 2>&1
}

# Every pane the server spawns inherits the server's environment. When the
# server is started from inside an agent's own shell, that environment marks
# the new panes as child sessions of that agent (transcript saving off,
# inherited permission mode). Strip agent-injected vars so panes start clean;
# login shells re-read the user's profile for anything legitimately theirs.
# -E, not BRE: BSD sed (macOS) has no \| alternation.
herdr_agent_env_vars() {
  env | sed -nE 's/^(CLAUDE[A-Z0-9_]*|ANTHROPIC[A-Z0-9_]*|AI_AGENT|CODEX[A-Z0-9_]*|CURSOR[A-Z0-9_]*|GEMINI[A-Z0-9_]*)=.*/\1/p'
}

herdr_ensure_session() { # <session> — start a headless server if none is up
  herdr_session_running "$1" && return 0
  echo "==> herdr: starting session '$1' (headless)"
  unset_args=""
  for v in $(herdr_agent_env_vars); do
    unset_args="$unset_args -u $v"
  done
  # Intentional word-splitting: $unset_args holds "-u NAME" pairs.
  # shellcheck disable=SC2086
  (env $unset_args herdr --session "$1" server >/dev/null 2>&1 &)
  n=0
  while [ "$n" -lt 60 ]; do
    herdr_session_running "$1" && return 0
    sleep 0.25
    n=$((n + 1))
  done
  echo "error: herdr session '$1' did not come up" >&2
  return 1
}

# No jq dependency (no tool is load-bearing): split on braces so each record
# becomes one or more lines, then pair fields by their order within a record.
# Records are NOT one line each — a workspace carrying metadata tokens has a
# nested object, which splits it — so accumulate fields until the id appears.
herdr_ws_pairs() { # <session> -> "<label>\t<workspace-id>\t<agent-status>" per workspace
  herdr --session "$1" workspace list 2>/dev/null \
    | tr '{}' '\n\n' \
    | awk '
        match($0, /"agent_status":"[^"]*"/) { st  = substr($0, RSTART + 16, RLENGTH - 17) }
        match($0, /"label":"[^"]*"/)        { lbl = substr($0, RSTART + 9,  RLENGTH - 10) }
        match($0, /"workspace_id":"[^"]*"/) {
          id = substr($0, RSTART + 16, RLENGTH - 17)
          if (lbl != "") { print lbl "\t" id "\t" st; lbl = ""; st = "" }
        }
      '
}

herdr_ws_id() { # <session> <label> -> workspace id, or empty
  herdr_ws_pairs "$1" | awk -F'\t' -v l="$2" '$1 == l { print $2; exit }'
}

herdr_pane_id_by_label() { # <session> <workspace> <pane-label> -> pane id, or empty
  herdr --session "$1" pane list --workspace "$2" 2>/dev/null \
    | tr '{}' '\n\n' \
    | grep -F "\"label\":\"$3\"" \
    | sed -n 's/.*"pane_id":"\([^"]*\)".*/\1/p' \
    | head -n1 || true
}

herdr_pane_has_agent() { # <session> <pane> — true if an agent occupies the pane
  herdr --session "$1" agent list 2>/dev/null \
    | tr '{}' '\n\n' \
    | grep -qF "\"pane_id\":\"$2\""
}

# True when *this process* is inside a herdr pane that a coding agent occupies.
# A human at a shell in the same workspace is not an agent: they typed the
# command, so the TUI belongs in this window.
herdr_caller_is_agent() {
  [ "${HERDR_ENV:-}" = 1 ] || return 1
  [ -n "${HERDR_SESSION:-}" ] && [ -n "${HERDR_PANE_ID:-}" ] || return 1
  herdr_pane_has_agent "$HERDR_SESSION" "$HERDR_PANE_ID"
}

herdr_pane_tab_id() { # <session> <pane> -> tab id
  herdr --session "$1" pane get "$2" 2>/dev/null \
    | tr '{}' '\n\n' \
    | sed -n 's/.*"tab_id":"\([^"]*\)".*/\1/p' \
    | head -n1 || true
}

# Panes on one tab, not the whole workspace — leftover browse/diff tabs
# must not make a 3-pane home tab look "off-template".
herdr_tab_pane_count() { # <session> <workspace> <tab>
  herdr --session "$1" pane list --workspace "$2" 2>/dev/null \
    | tr '{}' '\n\n' \
    | grep -cF "\"tab_id\":\"$3\"" || true
}

herdr_pane_fg_name() { # <session> <pane> -> foreground process name, or empty
  herdr --session "$1" pane process-info --pane "$2" 2>/dev/null \
    | tr '{}' '\n\n' \
    | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' \
    | head -n1 || true
}

herdr_pane_fg_cmdline() { # <session> <pane> -> foreground command line, or empty
  herdr --session "$1" pane process-info --pane "$2" 2>/dev/null \
    | tr '{}' '\n\n' \
    | sed -n 's/.*"cmdline":"\([^"]*\)".*/\1/p' \
    | head -n1 || true
}

# Is this command line a shell waiting at its prompt? The process NAME is not
# enough: a shell script's foreground process is also "bash", so a live
# `bash tools/wtc-status.sh` would read as idle and get a second one typed on
# top of it. A bare shell is a one-word command line ("-zsh", "bash"); a shell
# running something has arguments.
herdr_cmdline_is_shell() { # <cmdline>
  [ -n "$1" ] || return 0
  case "$1" in *[[:space:]]*) return 1 ;; esac
  case "${1#-}" in
    zsh|bash|fish|sh|nu|dash|ksh) return 0 ;;
    */zsh|*/bash|*/fish|*/sh|*/nu|*/dash|*/ksh) return 0 ;;
    *) return 1 ;;
  esac
}

herdr_pane_idle() { # <session> <pane>
  herdr_cmdline_is_shell "$(herdr_pane_fg_cmdline "$1" "$2")"
}

# Start <cmd> in a pane that is idle; leave a pane that is already working
# alone. This is what makes wtc-open re-runnable: a herdr session restored
# after a reboot comes back with the layout but not the processes, so every
# pane is a bare prompt and each one's own command has to be put back.
# <settle> seconds waits for a pane created moments ago to reach its prompt; a
# pane that has been sitting there since the reboot needs no wait at all.
herdr_pane_run_idle() { # <session> <pane> <cmd> [settle-seconds]
  [ -n "$2" ] || return 1
  herdr_pane_idle "$1" "$2" || return 1
  [ -z "${4:-}" ] || [ "${4:-0}" = 0 ] || sleep "$4"
  herdr --session "$1" pane run "$2" "$3" >/dev/null 2>&1 || return 1
}

# One `pane list` per workspace, as "<label>\t<pane-id>\t<agent>\t<agent-status>".
# herdr reports the agent on the pane itself, so this answers both halves of
# "what is already open here" — which labels exist, and which one is an agent —
# in a single call. Flattening the JSON with tr would not do: a pane carrying
# an agent has a nested agent_session object, and the fields land in different
# fragments.
herdr_pane_rows() { # <session> <workspace>
  herdr --session "$1" pane list --workspace "$2" 2>/dev/null | python3 -c '
import json, sys
try:
    panes = json.load(sys.stdin)["result"]["panes"]
except Exception:
    sys.exit(0)
for p in panes:
    print("\t".join([p.get("label") or "", p.get("pane_id") or "",
                     p.get("agent") or "", p.get("agent_status") or ""]))
' 2>/dev/null || true
}

# Column 1 label, 2 pane id, 3 agent kind, 4 agent status.
herdr_row_col() { # <rows> <label> <column>
  printf '%s\n' "$1" | awk -F'\t' -v l="$2" -v c="$3" '$1 == l { print $c; exit }'
}

# Default layout (new workspaces), see instructions/herdr.md:
#
#   [ agent | browse        ]
#   [       | shell | status]
#
# Agent is the full-height conversation. Browse is the human TUI slot
# (LazyVim / lazygit); empty, it is just a shell. Terminal and status
# sit under browse, not under the agent.
#
# Heal is non-destructive. A leftover `tui` label is renamed to `browse`.
# A standard 3-pane workspace (agent / shell / status) gets `browse` by
# splitting agent to the right. A workspace that already grew extra panes
# is left alone — callers fall back to `shell`.
herdr_ensure_browse_pane() { # <session> <workspace> <cwd> -> pane id
  session="$1" ws="$2" cwd="$3"
  id="$(herdr_pane_id_by_label "$session" "$ws" browse)"
  if [ -z "$id" ]; then
    id="$(herdr_pane_id_by_label "$session" "$ws" tui)"
    if [ -n "$id" ]; then
      herdr --session "$session" pane rename "$id" browse >/dev/null || true
    fi
  fi
  if [ -n "$id" ]; then
    printf '%s\n' "$id"
    return 0
  fi

  home="$(herdr_pane_id_by_label "$session" "$ws" agent)"
  [ -n "$home" ] || home="$(herdr_pane_id_by_label "$session" "$ws" shell)"
  tab="$(herdr_pane_tab_id "$session" "$home")"
  count=99
  if [ -n "$tab" ]; then
    count="$(herdr_tab_pane_count "$session" "$ws" "$tab")"
  fi
  case "$count" in
    ''|*[!0-9]*) count=99 ;;
  esac
  if [ "$count" -gt 3 ]; then
    herdr_pane_id_by_label "$session" "$ws" shell
    return 0
  fi

  base="$(herdr_pane_id_by_label "$session" "$ws" agent)"
  [ -n "$base" ] || base="$(herdr_pane_id_by_label "$session" "$ws" shell)"
  [ -n "$base" ] || return 1

  # ratio is the original pane's share: agent keeps 40%, browse gets the rest.
  pane="$(herdr --session "$session" pane split "$base" \
    --direction right --ratio 0.40 --cwd "$cwd" --no-focus | herdr_first_pane_id)"
  [ -n "$pane" ] || return 1
  herdr --session "$session" pane rename "$pane" browse >/dev/null || true
  sleep 1
  printf '%s\n' "$pane"
}

herdr_ensure_tui_pane() { herdr_ensure_browse_pane "$@"; } # leftover name

# Socket for the collection's browse nvim (--listen). Short path: macOS
# unix-socket names are capped around 104 bytes.
wtc_browse_socket() { # <collection-name>
  printf '/tmp/wtc-browse-%s.nvim' "$1"
}

wtc_browse_alive() { # <collection-name> — 0 if a browse nvim is answering
  command -v nvim >/dev/null 2>&1 || return 1
  nvim --server "$(wtc_browse_socket "$1")" --remote-expr "1" >/dev/null 2>&1
}

wtc_browse_eval() { # <collection-name> <vim-expr> -> stdout (trim)
  nvim --server "$(wtc_browse_socket "$1")" --remote-expr "$2" 2>/dev/null || true
}

herdr_tab_id_by_label() { # <session> <workspace> <label> -> tab id
  herdr --session "$1" tab list --workspace "$2" 2>/dev/null \
    | tr '{}' '\n\n' \
    | grep -F "\"label\":\"$3\"" \
    | sed -n 's/.*"tab_id":"\([^"]*\)".*/\1/p' \
    | head -n1 || true
}

# Inbox TUI (gh-dash) as a sibling herdr tab labelled `pr`. Non-destructive:
# an existing tab is reused; a busy pane is left alone.
herdr_ensure_pr_tab() { # <session> <workspace> <cwd>
  session="$1" ws="$2" cwd="$3"
  command -v gh >/dev/null 2>&1 || return 0
  if ! gh dash -h >/dev/null 2>&1; then
    return 0
  fi
  tab="$(herdr_tab_id_by_label "$session" "$ws" pr)"
  if [ -z "$tab" ]; then
    created="$(herdr --session "$session" tab create --workspace "$ws" \
      --cwd "$cwd" --label pr --no-focus 2>/dev/null || true)"
    tab="$(printf '%s' "$created" | tr '{}' '\n\n' \
      | sed -n 's/.*"tab_id":"\([^"]*\)".*/\1/p' | head -n1 || true)"
    pane="$(printf '%s' "$created" | herdr_first_pane_id || true)"
    [ -n "$pane" ] || return 0
    herdr --session "$session" pane rename "$pane" pr >/dev/null || true
    sleep 1
  else
    pane="$(herdr_pane_id_by_label "$session" "$ws" pr)"
    [ -n "$pane" ] || return 0
  fi
  fg="$(herdr_pane_fg_name "$session" "$pane")"
  case "$fg" in
    gh|gh-dash) return 0 ;;
    ''|zsh|bash|fish|sh|nu) ;;
    *) return 0 ;;
  esac
  herdr --session "$session" pane run "$pane" "gh dash" >/dev/null 2>&1 || true
}

herdr_first_pane_id() { # reads a herdr JSON response on stdin -> first pane id
  tr '{}' '\n\n' \
    | sed -n 's/.*"pane_id":"\([^"]*\)".*/\1/p' \
    | head -n1
}

write_collection_env() { # <collection-dir> <collection-name>
  dir="$1" name="$2"
  # Regeneration keeps the collection's existing port base (idempotent).
  base=""
  if [ -f "$dir/.env.collection" ]; then
    base="$(sed -n 's/^COLLECTION_PORT_BASE=//p' "$dir/.env.collection" | head -n1)"
  fi
  [ -n "$base" ] || base="$(alloc_port_base)"
  {
    echo "# Generated by harness tools — collection-scoped env (not committed)."
    echo "# Ports cover every registry repo with a port_offset, whether or not"
    echo "# it is checked out here, so absent repos still resolve to a port."
    echo "WTC_COLLECTION=$name"
    echo "WTC_CONFIG_ROOT=${WTC_CONFIG_ROOT:-$HOME/.config/wtc}"
    echo "COLLECTION_PORT_BASE=$base"
    for repo in $(registry_all_names); do
      off="$(registry_field "$repo" port_offset)"
      [ -n "$off" ] || continue
      echo "$(port_var_for "$repo")=$((base + off))"
    done
  } > "$dir/.env.collection"

  # Collection-scoped secrets. Seeded empty once and never rewritten afterwards:
  # .env.collection above is regenerated wholesale on every branch-off, so
  # anything hand-added there is lost. This second file is the one place a
  # secret scoped to THIS collection survives, which the shared control root
  # deliberately cannot be (instructions/secrets.md: one canonical copy per
  # file keeps rotation sane). Listed in mise.toml unconditionally, so it must
  # exist even when empty. umask 077 + unconditional chmod so a secrets tier
  # is never briefly (or lastingly) world-readable.
  if [ ! -f "$dir/.env.collection.local" ]; then
    (
      umask 077
      cat > "$dir/.env.collection.local" <<'EOF'
# Collection-scoped secrets and overrides. Seeded empty once, then hand-
# authored. NOT committed (the collection root is not a git repo), and never
# rewritten by harness tools.
#
# Use this for credentials scoped to this collection's work — a throwaway
# sandbox key for one investigation, say. Anything that should rotate once for
# the whole machine belongs in the control root instead
# ($WTC_CONFIG_ROOT/<repo>/<path>, linked by tools/link-secrets.sh).
#
# Inherited by every repo in this collection, not just one.
EOF
    )
  fi
  # Refuse to chmod through a symlink — that would change the mode of
  # whatever it points at (possibly outside the collection).
  if [ -L "$dir/.env.collection.local" ]; then
    echo "error: $dir/.env.collection.local is a symlink; refuse to chmod through it" >&2
    return 1
  fi
  chmod 600 "$dir/.env.collection.local"

  cat > "$dir/mise.toml" <<'EOF'
# Generated by harness tools. Collection-scoped env: mise finds this file as a
# parent config of every sibling repo worktree, so all of them inherit the
# variables from .env.collection.
#
# .env.collection.local is the collection-scoped secrets tier — hand-authored,
# 600, never regenerated. Listed second so it wins on conflict.
# Without mise: `set -a; . ./.env.collection; . ./.env.collection.local; set +a`.
[env]
_.file = [".env.collection", ".env.collection.local"]
EOF
  trust_mise "$dir"
  echo "wrote $dir/.env.collection (port base $base) + $dir/mise.toml + $dir/.env.collection.local"
}

# --- collection PR label ----------------------------------------------------
# Which collection launched a PR is a fact worth keeping, and keeping it on the
# PR rather than in a local file is what makes it survive the worktree going
# back to the tip, the collection being retired, or the work moving machines.
# A label is the cheapest durable place: one server-side filter answers "what
# is this collection carrying" without any local bookkeeping to go stale.

wtc_pr_label() { # [collection] -> the label this collection's PRs carry
  name="${1:-}"
  [ -n "$name" ] || name="${WTC_COLLECTION:-}"
  [ -n "$name" ] || name="$(basename "$(cd "$HARNESS_DIR/.." && pwd)")"
  printf 'wtc:%s\n' "$name"
}

wtc_pr_ensure_label() { # <slug> <label> — create it if the repo lacks it
  command -v gh >/dev/null 2>&1 || return 0
  if gh label list --repo "$1" --search "$2" --json name --jq '.[].name' 2>/dev/null \
     | grep -Fxq "$2"; then
    return 0
  fi
  # Colour is cosmetic and the description says why a stranger is seeing it.
  gh label create "$2" --repo "$1" --color ededed \
    --description "Opened from the ${2#wtc:} worktree collection" >/dev/null 2>&1 || true
}

wtc_pr_label_add() { # <slug> <pr-number> <label> — tag an existing PR
  command -v gh >/dev/null 2>&1 || return 0
  wtc_pr_ensure_label "$1" "$3"
  gh pr edit "$2" --repo "$1" --add-label "$3" >/dev/null 2>&1 || true
}

wtc_pr_list() { # <collection> -> TSV rows, one per open PR this collection owns
  # repo \t number \t checks \t merge \t review \t title
  #
  # checks: SUCCESS|FAILURE|ERROR|PENDING|draft|NONE
  # merge:  mergeStateStatus (BEHIND / DIRTY / BLOCKED / CLEAN / …)
  # review: approved | changes | <count of unresolved threads> | none
  #
  # One GraphQL round trip per repo returns every fact a row shows, and the
  # repos are queried in parallel — the same shape wtc-status uses per branch.
  #
  # Only open PRs: a merged one is not something you act on, and the row that
  # matters after a merge is the worktree still sitting on that branch, which
  # wtc_pr_orphans reports instead.
  command -v gh >/dev/null 2>&1 || return 0
  label="$(wtc_pr_label "$1")"
  tmp="$(mktemp -d)"
  # Driven by the collection's worktrees rather than the registry: that covers
  # `ext.` siblings, and it stops a two-repo collection querying every repo the
  # workspace has ever owned.
  for wt in "$ROOT/$1"/*/; do
    wt="${wt%/}"
    [ -e "$wt/.git" ] || continue
    repo="$(basename "$wt")"
    [ "$repo" = harness ] && repo="$(harness_repo)"
    slug="$(slug_for_worktree "$wt" "$repo")"
    [ -n "$slug" ] || continue
    (
      gh api graphql -F owner="${slug%%/*}" -F name="${slug#*/}" -F label="$label" -f query='
        query($owner:String!,$name:String!,$label:String!){
          repository(owner:$owner,name:$name){
            pullRequests(labels:[$label],states:OPEN,first:20,
                         orderBy:{field:UPDATED_AT,direction:DESC}){
              nodes{
                number title isDraft mergeStateStatus reviewDecision
                reviewThreads(first:100){nodes{isResolved isOutdated}}
                commits(last:1){nodes{commit{statusCheckRollup{state}}}}
              }}}}' --jq '
        .data.repository.pullRequests.nodes[] | [
          (.number|tostring),
          (if .isDraft then "draft"
           else (.commits.nodes[0].commit.statusCheckRollup.state // "NONE") end),
          (.mergeStateStatus // "UNKNOWN"),
          (([.reviewThreads.nodes[] | select((.isResolved|not) and (.isOutdated|not))] | length) as $open
            | if $open > 0 then ($open|tostring)
              elif .reviewDecision == "APPROVED" then "approved"
              elif .reviewDecision == "CHANGES_REQUESTED" then "changes"
              else "none" end),
          (.title // "")
        ] | @tsv' 2>/dev/null \
        | awk -v r="$repo" 'NF { print r "\t" $0 }' > "$tmp/$(printf '%s' "$repo" | tr -c 'A-Za-z0-9._-' '_')" 2>/dev/null || :
    ) &
  done
  wait 2>/dev/null || true
  cat "$tmp"/* 2>/dev/null || true
  rm -rf "$tmp"
}

# NOTE: wtc-status derives "worktree still on a branch whose PR has gone" from
# the per-branch PR cache it already fills, so there is no separate orphan
# query here. Kept out deliberately rather than left as a second code path
# that would drift from the one the table actually uses.
