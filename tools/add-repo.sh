#!/usr/bin/env bash
# add-repo.sh — bring additional repos into an existing collection.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/add-repo.sh [-b <branch>] [--tip] <collection> <repo> [<repo> ...]

Adds worktrees for the named repos (names as in .harness-repos.yml) to an
existing collection, cloning missing bare owners from GitHub first, then runs
each new repo's init hook. The collection env (.env.collection) already
covers all registry repos' ports, so no re-wiring is needed.

New worktrees are DETACHED AT THE DEVELOPMENT TIP — no branch is created;
`git switch -c <issue-id>-<slug>` at the first commit. A repo added purely for
context (reading a sibling's code) then never grows a branch at all.

  -b <branch>   create/check out this branch instead of detaching at the tip.
                An existing branch of that name is checked out, otherwise it
                is created from the repo's default_ref
  --tip         accepted and ignored — detached at the tip is now the default
EOF
  exit 1
}

branch=""
while [ $# -gt 0 ]; do
  case "$1" in
    -b) branch="${2:?-b needs a value}"; shift 2 ;;
    --tip) echo "note: --tip is the default now (detached at the tip); ignoring" >&2; shift ;;
    -h|--help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
done
[ $# -ge 2 ] || usage
collection="$1"; shift

script_dir="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(dirname "$script_dir")"
. "$script_dir/lib.sh"
harness_lib_init

dest_root="$ROOT/$collection"
[ -d "$dest_root/harness" ] || { echo "error: $dest_root is not a collection (no harness/)" >&2; exit 1; }

for repo in "$@"; do
  case "$repo" in "$(harness_repo)"|harness) echo "skip: harness is already in every collection"; continue ;; esac
  [ ! -e "$dest_root/$repo" ] || { echo "error: $dest_root/$repo already exists" >&2; exit 1; }
  add_worktree "$repo" "$repo" "$dest_root" "$branch"
done

[ -f "$dest_root/.env.collection" ] || write_collection_env "$dest_root" "$collection"

# Idempotent, and cheap: also picks up skills added since this collection was
# created, for a wtc that predates them (instructions/skills.md).
"$script_dir/link-skills.sh" --collection "$dest_root"

for repo in "$@"; do
  case "$repo" in "$(harness_repo)"|harness) continue ;; esac
  run_hook "$dest_root/$repo" init
done

echo "done: added $* to $dest_root"
