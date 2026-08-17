#!/usr/bin/env bash
# wtc-status.sh — status of every collection, plus the processes running in them.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/wtc-status.sh [--repos|--procs] [--watch [seconds]] [--no-click] [<collection>]

Prints per-collection branch / open PR + check rollup / working-tree state,
then the processes running under the herdr session (CPU, memory). Meant to
be left running in a pane — wtc-open.sh puts one in every wtc:

  tools/wtc-status.sh --repos --watch 120 <collection>
  tools/wtc-status.sh --procs --watch 5

  <collection>  limit the table to one collection (default: all)
  --repos       only the collection table (default: both)
  --procs       only the process table
  --watch       redraw every N seconds (default 60)
  --click       clickable rows even when stdin/stdout is not a terminal
  --no-click    plain table, no mouse capture
  --no-fetch    do not refresh remote refs first (offline, or a hot loop)
  --fetch-age   seconds a bare's last fetch may be before it is refreshed
                (default 300)

BRANCH shows `⌂ <branch>` for a worktree detached at the development tip —
the resting state, and up to date unless TREE says otherwise. TREE carries
±changed files, ↑commits ahead, ↓commits behind; any ↓ means a catch-up will
bring in remote changes.

On a terminal the collection table is clickable: REPO focuses that sibling
in the browse nvim, TREE opens its git status there (lazygit if nvim is
not up), PR opens the pull request in Octo or the browser. r redraws, q quits.
EOF
  exit 1
}

want=both watch=no interval=60 click=auto fetch=yes fetch_max_age=300
while [ $# -gt 0 ]; do
  case "$1" in
    --repos) want=repos; shift ;;
    --procs) want=procs; shift ;;
    --watch) watch=yes; shift; case "${1:-}" in [0-9]*) interval="$1"; shift ;; esac ;;
    --click) click=yes; shift ;;
    --no-click) click=no; shift ;;
    --no-fetch) fetch=no; shift ;;
    --fetch-age) fetch_max_age="${2:?--fetch-age needs seconds}"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) only="$1"; shift ;;
  esac
done
only="${only:-}"

script_dir="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(dirname "$script_dir")"
. "$script_dir/lib.sh"
harness_lib_init

# Clicking needs the collection table (that is what carries the cells) and a
# terminal on both ends: mouse reports come back in on stdin.
if [ "$click" = auto ]; then
  click=no
  if [ "$want" != procs ] && [ -t 0 ] && [ -t 1 ]; then click=yes; fi
fi
[ "$click" = yes ] && watch=yes   # a clickable table is a live one

# Column widths are character counts, and the rollup glyphs (✓ ✗ ● — ↑ ±) are
# one column but several bytes — so the table needs a UTF-8 ctype to measure.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf8*) ;;
  *) export LC_CTYPE=en_US.UTF-8 ;;
esac

# One source of truth for the columns: the widths and the click map must not
# drift apart — and no row may wrap, or a click lands on the wrong worktree.
# BRANCH absorbs the terminal width; the status pane is a narrow one.
c_coll=22 c_repo=16 c_pr=10 c_tree=10 c_branch=34
col_repo=0 col_pr=0 col_tree=0
# Scoped to one collection, the COLLECTION column is a constant — spend those
# columns on branch names instead and name the collection above the table.
show_coll=yes; [ -n "$only" ] && show_coll=no

layout() { # recompute the columns for the terminal as it is now
  # stty asks the terminal itself; tput would believe an inherited $COLUMNS.
  cols="$(stty size 2>/dev/null | awk '{print $2}' || true)"
  [ -n "$cols" ] || cols="$(tput cols 2>/dev/null || true)"
  case "$cols" in ''|*[!0-9]*) cols=100 ;; esac
  [ "$cols" -ge 46 ] || cols=46
  c_repo=16
  # seps = the gaps left of PR; one more sits between PR and TREE.
  if [ "$show_coll" = yes ]; then c_coll=22; seps=3; else c_coll=0; seps=2; fi
  c_branch=$((cols - c_coll - c_repo - c_pr - c_tree - seps - 2))   # 1 spare, so no wrap
  while [ "$c_branch" -lt 14 ] && [ "$c_coll" -gt 8 ]; do
    c_coll=$((c_coll - 1)); c_branch=$((c_branch + 1))
  done
  while [ "$c_branch" -lt 14 ] && [ "$c_repo" -gt 6 ]; do
    c_repo=$((c_repo - 1)); c_branch=$((c_branch + 1))
  done
  [ "$c_branch" -ge 6 ] || c_branch=6
  [ "$c_branch" -le 40 ] || c_branch=40   # a wide terminal is not a reason for a wide gap
  # 1-based screen columns of the clickable cells.
  if [ "$show_coll" = yes ]; then col_repo=$((c_coll + 2)); else col_repo=1; fi
  col_pr=$((c_coll + c_repo + c_branch + seps + 1))
  col_tree=$((col_pr + c_pr + 1))
}

ROWS=("")   # ROWS[<screen line>] = "<worktree>|<slug>|<branch>|<pr number>"
line=0      # lines printed so far, i.e. the screen line of the last one

out() { printf '%s\n' "$1"; line=$((line + 1)); }

pr_for() { # <repo> <branch> -> "<number>\t<#n + rollup glyph>", or empty
  command -v gh >/dev/null 2>&1 || return 0
  slug="$(repo_slug_for "$1")"
  [ -n "$slug" ] || return 0
  gh pr view "$2" --repo "$slug" --json number,isDraft,statusCheckRollup --jq '
    (.number|tostring) + "\t#" + (.number|tostring)
    + (if .isDraft then "d" else "" end) + " "
    + ([.statusCheckRollup[]? | (.conclusion // .state // "")] | map(select(. != "")) |
       if length == 0 then "—"
       elif any(. == "FAILURE" or . == "ERROR" or . == "TIMED_OUT" or . == "CANCELLED") then "✗"
       elif any(. == "PENDING" or . == "IN_PROGRESS" or . == "QUEUED") then "●"
       else "✓" end)' 2>/dev/null || true
}

# Both write to a variable rather than stdout: cells end in padding, and
# command substitution would eat it.

fit() { # <text> <width> -> $_fit, exactly <width> columns (%-*s counts bytes)
  _fit="${1:0:$2}"
  if [ "${#_fit}" -lt "$2" ]; then
    printf -v _fit '%s%*s' "$_fit" $(( $2 - ${#_fit} )) ''
  fi
}

cell() { # <text> <width> -> $_cell: <width> columns, the text itself underlined
  s="${1:0:$2}"
  pad=$(( $2 - ${#s} ))
  if [ "$click" = yes ] && [ -n "${s// /}" ]; then
    s=$'\033[4m'"$s"$'\033[24m'   # the underline marks the text, not the padding
  fi
  if [ "$pad" -gt 0 ]; then
    printf -v s '%s%*s' "$s" "$pad" ''
  fi
  _cell="$s"
}

repos_table() {
  ROWS=("")
  layout
  # Refresh the refs the table is about to measure against — "behind" computed
  # from a week-old fetch is worse than no number at all. Age-gated, so a
  # --watch pane redrawing every 5s still only fetches every few minutes.
  if [ "$fetch" = yes ]; then
    for c in "$ROOT"/*/; do
      c="${c%/}"
      [ -d "$c/harness" ] || continue
      if [ -n "$only" ] && [ "$(basename "$c")" != "$only" ]; then continue; fi
      for wt in "$c"/*/; do
        wt="${wt%/}"
        [ -e "$wt/.git" ] || continue
        fetch_if_stale "$(owner_of "$wt")" "$fetch_max_age" || true
      done
    done
  fi

  stale=0
  hdr=""
  if [ "$show_coll" = yes ]; then
    fit COLLECTION $c_coll; hdr="$_fit "
  else
    out $'\033[1m'"$only"$'\033[0m'
  fi
  fit REPO $c_repo;       hdr="$hdr$_fit "
  fit BRANCH $c_branch;   hdr="$hdr$_fit "
  fit PR $c_pr;           hdr="$hdr$_fit TREE"
  out $'\033[1m'"$hdr"$'\033[0m'
  for c in "$ROOT"/*/; do
    c="${c%/}"
    [ -d "$c/harness" ] || continue
    name="$(basename "$c")"
    if [ -n "$only" ] && [ "$name" != "$only" ]; then continue; fi
    for wt in "$c"/*/; do
      wt="${wt%/}"
      [ -e "$wt/.git" ] || continue
      dir="$(basename "$wt")"
      repo="$dir"; [ "$dir" = harness ] && repo="$(harness_repo)"
      # Detached at the tip is the resting state, not an anomaly: show it as
      # the tip it is (⌂ develop), and let ↓ be the only "you are behind"
      # signal — for a detached HEAD and a stale branch alike.
      state="$(wt_head_state "$wt" "$repo")"
      kind="$(printf '%s' "$state" | awk '{print $1}')"
      label="$(printf '%s' "$state" | awk '{print $2}')"
      ahead="$(printf '%s' "$state" | awk '{print $3}')"
      behind="$(printf '%s' "$state" | awk '{print $4}')"
      changed="$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"

      branch="$label"
      [ "$kind" = detached ] && branch="⌂ $label"

      tree=""
      [ "$changed" != 0 ] && tree="±$changed"
      [ "$ahead" != 0 ] && tree="$tree${tree:+ }↑$ahead"
      if [ "$behind" != 0 ]; then
        tree="$tree${tree:+ }↓$behind"
        stale=$((stale + 1))
      fi
      [ -n "$tree" ] || tree=clean
      # A detached HEAD has no branch to look a PR up by; ⌂ rows show no PR
      # because there is no work in flight to have one.
      pr=""
      [ "$kind" = branch ] && pr="$(pr_for "$repo" "$branch")"
      pr_num="${pr%%$'\t'*}"; pr_disp="${pr#*$'\t'}"
      [ -n "$pr" ] || { pr_num=""; pr_disp=""; }

      row=""
      if [ "$show_coll" = yes ]; then fit "$name" $c_coll; row="$_fit "; fi
      # Projects whose repos all share a prefix (`acme-api`, `acme-web`, …)
      # waste a third of this column repeating it. Set WTC_REPO_PREFIX to trim
      # it from the display only; unset, nothing is stripped.
      cell "${dir#${WTC_REPO_PREFIX:-}}" $c_repo; row="$row$_cell "
      fit "$branch" $c_branch;     row="$row$_fit "
      cell "$pr_disp" $c_pr;       row="$row$_cell "
      cell "$tree" $c_tree;        row="$row$_cell"
      out "$row"
      # $label, not $branch: the click map wants a real ref for `gh browse`,
      # not the ⌂-prefixed display string.
      ROWS[$line]="$wt|$(repo_slug_for "$repo")|$label|$pr_num"
      name=""
    done
  done
  if [ "$stale" -gt 0 ]; then
    out $'\033[2m'"↓ = behind remote — $stale worktree(s) need a catch-up"$'\033[0m'
  fi
  return 0
}

legend() {
  out $'\033[2m'"click: REPO → nvim · TREE → git · PR → octo/github   r redraw · q quit"$'\033[0m'
}

procs_table() {
  root_pid="$(pgrep -f "herdr --session $(herdr_session_name) server" 2>/dev/null | head -n1 || true)"
  if [ -z "$root_pid" ]; then
    out "(no herdr session server running)"
    return 0
  fi
  printf -v hdr '\033[1m%7s %6s %6s %9s  %s\033[0m' PID %CPU %MEM RSS COMMAND
  out "$hdr"
  ps -axo pid=,ppid=,pcpu=,pmem=,rss=,args= | awk -v root="$root_pid" '
    { pid[NR]=$1; ppid[NR]=$2; cpu[NR]=$3; mem[NR]=$4; rss[NR]=$5
      a=""; for (i=6; i<=NF; i++) a=a (i>6?" ":"") $i; args[NR]=substr(a,1,58); n=NR }
    END {
      keep[root]=1
      do { more=0
           for (i=1; i<=n; i++) if (!keep[pid[i]] && keep[ppid[i]]) { keep[pid[i]]=1; more=1 }
      } while (more)
      for (i=1; i<=n; i++)
        if (keep[pid[i]] && pid[i] != root)
          printf "%7s %6s %6s %8.0fM  %s\n", pid[i], cpu[i], mem[i], rss[i]/1024, args[i]
    }' | sort -k2 -nr
}

render() {
  line=0
  [ "$watch" = yes ] && printf '\033[H\033[2J'
  case "$want" in
    repos) repos_table ;;
    procs) procs_table ;;
    both)  repos_table; out ""; procs_table ;;
  esac
  [ "$click" = yes ] && legend
  return 0
}

# --- clicking ---------------------------------------------------------------
# Mouse reports only; output processing stays on (-icanon, not raw) so the
# table still prints with normal line endings.

tty_setup() {
  tty_saved="$(stty -g)"
  trap tty_restore EXIT
  trap 'exit 0' INT TERM
  stty -icanon -echo min 1 time 0
  printf '\033[?1000h\033[?1006h\033[?25l'   # button events, SGR encoding, no cursor
}

tty_restore() {
  printf '\033[?1006l\033[?1000l\033[?25h'
  [ -n "${tty_saved:-}" ] && stty "$tty_saved" 2>/dev/null || true
}

differ_cmd() { # <worktree> -> the diff view to run there
  if command -v lazygit >/dev/null 2>&1; then
    printf 'lazygit --path %s' "$1"
  else
    printf 'git -C %s diff' "$1"
  fi
}

collection_of() { # <worktree> -> collection folder name
  basename "$(dirname "$1")"
}

# Ask the collection's browse nvim to switch to this sibling.
# Returns 0 if nvim handled it.
open_nvim() { # <worktree> <want: files|git> [pr-number]
  wt="$1" want="${2:-files}" pr="${3:-}"
  coll="$(collection_of "$wt")"
  repo="$(basename "$wt")"
  wtc_browse_alive "$coll" || return 1
  if [ -n "$pr" ]; then
    got="$(wtc_browse_eval "$coll" "luaeval(\"WtcBrowsePr('$repo', '$pr')\")")"
    case "$got" in octo|octo-list) return 0 ;; esac
    return 1
  fi
  got="$(wtc_browse_eval "$coll" "luaeval(\"WtcBrowseFocus('$repo', '$want')\")")"
  [ "$got" = ok ]
}

open_pr() { # <worktree> <slug> <branch> <pr number>
  # Only hand off to nvim when there is a PR to open. An empty $4 would
  # still return success if browse is up (WtcBrowseFocus), skipping the
  # gh browse --branch fallback.
  if [ -n "$4" ] && open_nvim "$1" files "$4"; then
    return 0
  fi
  command -v gh >/dev/null 2>&1 || return 0
  [ -n "$2" ] || return 0
  if [ -n "$4" ]; then
    (gh pr view "$4" --repo "$2" --web >/dev/null 2>&1 &)
  else
    (gh browse --repo "$2" --branch "$3" >/dev/null 2>&1 &)
  fi
}

open_diff() { # <worktree> — nvim git-status tab, else lazygit in a herdr tab
  if open_nvim "$1" git; then
    return 0
  fi
  label="diff:$(basename "$1")"
  if herdr_present && [ -n "${HERDR_SESSION:-}" ] && [ -n "${HERDR_WORKSPACE_ID:-}" ]; then
    tab="$(herdr --session "$HERDR_SESSION" tab list 2>/dev/null \
      | tr '{}' '\n\n' \
      | grep -F "\"label\":\"$label\"" \
      | grep -F "\"workspace_id\":\"$HERDR_WORKSPACE_ID\"" \
      | sed -n 's/.*"tab_id":"\([^"]*\)".*/\1/p' | head -n1 || true)"
    if [ -n "$tab" ]; then
      herdr --session "$HERDR_SESSION" tab focus "$tab" >/dev/null 2>&1 || true
      return 0
    fi
    pane="$(herdr --session "$HERDR_SESSION" tab create --workspace "$HERDR_WORKSPACE_ID" \
      --cwd "$1" --label "$label" --focus 2>/dev/null | herdr_first_pane_id || true)"
    if [ -n "$pane" ]; then
      sleep 1
      herdr --session "$HERDR_SESSION" pane run "$pane" "$(differ_cmd "$1")" >/dev/null 2>&1 || true
      return 0
    fi
  fi
  tty_restore
  eval "$(differ_cmd "$1")" || true
  tty_setup
}

on_click() { # <button>;<column>;<line> from an SGR mouse report
  btn="${1%%;*}"; rest="${1#*;}"; x="${rest%%;*}"; y="${rest##*;}"
  [ "$btn" = 0 ] || return 0                       # left button only, no wheel/drag
  case "$x$y" in *[!0-9]*) return 0 ;; esac
  entry="${ROWS[$y]:-}"
  [ -n "$entry" ] || return 0
  wt="${entry%%|*}"; rest="${entry#*|}"
  slug="${rest%%|*}"; rest="${rest#*|}"
  branch="${rest%%|*}"; pr_num="${rest##*|}"
  # Only the cells themselves act — empty space right of the table does not.
  if [ "$x" -ge "$col_tree" ] && [ "$x" -lt $((col_tree + c_tree)) ]; then
    open_diff "$wt"
  elif [ "$x" -ge "$col_pr" ] && [ "$x" -lt $((col_pr + c_pr)) ]; then
    open_pr "$wt" "$slug" "$branch" "$pr_num"
  elif [ "$x" -ge "$col_repo" ] && [ "$x" -lt $((col_repo + c_repo)) ]; then
    open_nvim "$wt" files || open_diff "$wt"
  fi
}

read_mouse() { # after ESC: consume "[<b;x;yM" and act on the press
  IFS= read -r -s -n1 -t 1 ch || return 0
  [ "$ch" = '[' ] || return 0
  IFS= read -r -s -n1 -t 1 ch || return 0
  [ "$ch" = '<' ] || return 0
  seq=""
  while IFS= read -r -s -n1 -t 1 ch; do
    case "$ch" in
      M) on_click "$seq"; return 0 ;;
      m) return 0 ;;                 # release — the press already acted
      *) seq="$seq$ch" ;;
    esac
  done
}

wait_events() { # until the next redraw is due, or a key asks for one
  waited=0
  while [ "$waited" -lt "$interval" ]; do
    if IFS= read -r -s -n1 -t 1 ch; then
      case "$ch" in
        q|Q) exit 0 ;;
        r|R|' ') return 0 ;;
        $'\033') read_mouse ;;
      esac
    else
      waited=$((waited + 1))
    fi
  done
}

if [ "$click" = yes ]; then
  tty_setup
  while :; do render; wait_events; done
elif [ "$watch" = yes ]; then
  while :; do render; sleep "$interval"; done
else
  render
fi
