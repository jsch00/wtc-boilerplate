#!/usr/bin/env bash
# retire.sh — tear down a collection: teardown hooks, remove worktrees.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/retire.sh [--force] <collection>

Pre-flight checks every sibling worktree (dirty tree, or commits not on any
remote ref) and refuses unless --force. Then runs each repo's teardown hook,
removes the worktrees, prunes worktree metadata, and deletes the collection
folder.

Remote branches are NEVER touched — they are the per-issue record
(instructions/development-workflows.md). Local branch refs are disposable and
go with the worktrees; anything they held that was not pushed is what the
pre-flight refuses on.
EOF
  exit 1
}

force=no
while [ $# -gt 0 ]; do
  case "$1" in
    --force) force=yes; shift ;;
    -h|--help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
done
[ $# -eq 1 ] || usage
collection="$1"

script_dir="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(dirname "$script_dir")"
. "$script_dir/lib.sh"
harness_lib_init

dest_root="$ROOT/$collection"
[ -d "$dest_root/harness" ] || { echo "error: $dest_root is not a collection (no harness/)" >&2; exit 1; }
case "$(cd "$HARNESS_DIR" && pwd)" in
  "$dest_root"/*) echo "error: run retire.sh from a different collection's harness (this one is being removed)" >&2; exit 1 ;;
esac

# Pre-flight: refuse to destroy unsaved work unless --force.
blocked=no
for wt in "$dest_root"/*/; do
  wt="${wt%/}"
  [ -e "$wt/.git" ] || continue
  if [ -n "$(git -C "$wt" status --porcelain)" ]; then
    echo "blocked: $wt has uncommitted changes" >&2
    blocked=yes
  fi
  unpushed="$(git -C "$wt" log --oneline HEAD --not --remotes 2>/dev/null | head -n3)"
  if [ -n "$unpushed" ]; then
    echo "blocked: $wt has commits not on any remote:" >&2
    printf '%s\n' "$unpushed" | sed 's/^/    /' >&2
    blocked=yes
  fi
done
if [ "$blocked" = yes ] && [ "$force" != yes ]; then
  echo "aborting (use --force to retire anyway)" >&2
  exit 1
fi

for wt in "$dest_root"/*/; do
  wt="${wt%/}"
  [ -e "$wt/.git" ] || continue
  run_hook "$wt" teardown
  bare="$(owner_of "$wt")"
  echo "==> removing worktree $wt"
  if [ "$force" = yes ]; then
    git --git-dir="$bare" worktree remove --force "$wt"
  else
    git --git-dir="$bare" worktree remove "$wt"
  fi
  git --git-dir="$bare" worktree prune
done

# Close the collection's herdr workspace, if one is open (view only, no state).
# Also kill any wtc-status --watch still bound to *this* harness's tools path —
# another collection may have been opened via this one, and its status pane
# would otherwise keep awk'ing the registry we are about to delete.
if herdr_present; then
  herdr_session="$(herdr_session_name)"
  if herdr_session_running "$herdr_session"; then
    ws_id="$(herdr_ws_id "$herdr_session" "$collection")"
    if [ -n "$ws_id" ]; then
      echo "==> herdr: closing workspace $ws_id ($collection) in session $herdr_session"
      herdr --session "$herdr_session" workspace close "$ws_id" >/dev/null || true
    fi
  fi
fi
# Kill any wtc-status --watch still bound to *this* harness's tools path.
# Match by fixed substring, not pkill's regex — paths can contain `.`, `+`, etc.
status_needle="$dest_root/harness/tools/wtc-status.sh"
while read -r pid args; do
  case "$args" in *"$status_needle"*) kill "$pid" 2>/dev/null || true ;; esac
done <<EOF
$(ps ax -o pid=,args= 2>/dev/null || true)
EOF

# .env.collection.local is the collection-scoped secrets tier — it dies with
# the collection (credentials scoped to this wtc's work have nowhere to go).
rm -f "$dest_root/HANDOFF.md" "$dest_root/.env.collection" \
  "$dest_root/.env.collection.local" "$dest_root/mise.toml" "$dest_root/.DS_Store"
# Generated skill-link dirs (link-skills.sh) — symlinks into harness/skills,
# nothing of their own. Without this the rmdir below always finds them and
# reports the collection as "left in place".
rm -rf "$dest_root/.claude" "$dest_root/.agents"
if rmdir "$dest_root" 2>/dev/null; then
  echo "done: retired $dest_root"
else
  echo "done, but $dest_root left in place — it still contains files:"
  ls -A "$dest_root"
fi
