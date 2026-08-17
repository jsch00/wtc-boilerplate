#!/usr/bin/env bash
# link-skills.sh — expose the harness skills (skills/wtc-*) at a collection
# root, under the directory names the agent CLIs actually read.
#
# The skills are authored once, in this repo (git-durable). Collections are
# generated and disposable, so they get symlinks — one per skill, which is the
# form Claude Code and Codex both document as supported:
#
#   <collection>/.claude/skills/<name> -> ../../harness/skills/<name>   (Claude Code)
#   <collection>/.agents/skills/<name> -> ../../harness/skills/<name>   (Codex, Cursor)
#
# Two directories cover all three CLIs; Cursor reads .agents/skills natively
# and .claude/skills for back-compat, so it needs no third copy. Why the
# collection root and not each worktree: the root is not a git repo, so the
# links are invisible to git and no repo needs an ignore rule for them.
# See instructions/skills.md for the discovery rules this encodes.
#
# Idempotent, and re-running is the point — same lifecycle as link-secrets.sh:
#   * creation time  — branch-off.sh / add-repo.sh call it
#   * catch-up       — picks up skills added to the harness since the
#                      collection was created, and prunes ones removed since
#
# Bash 3.2-safe (macOS default): no mapfile, no associative arrays.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(dirname "$script_dir")"
# shellcheck source=lib.sh
. "$script_dir/lib.sh"
harness_lib_init

# Directory names read by the agent CLIs. Each gets the same set of links.
SKILL_ROOTS=".claude/skills .agents/skills"

collection="$(dirname "$HARNESS_DIR")"
harness_dirname="$(basename "$HARNESS_DIR")"
dry_run=no
all=no

usage() {
  cat <<'EOF'
Usage: link-skills.sh [options]

Links a collection's own harness/skills/* into its .claude/skills and
.agents/skills so Claude Code, Codex, and Cursor all discover them.
Idempotent.

  --collection <dir>  Collection to wire (default: the one holding this
                      harness worktree).
  --all               Every collection under the workspace root. Use after
                      landing a new skill, to roll it out in one pass.
  --dry-run           Report what would change; touch nothing.
  -h, --help          Show this help.

Each collection is linked against ITS OWN harness worktree, not the one
running this script — the links are relative, so that is what they resolve
against, and a collection developing the harness keeps its own in-progress
skills. Consequence: a skill only reaches another collection once that
collection's harness worktree has it in git. Order is catch-up, then this.

Agents started inside a sibling worktree rather than at the collection root
see these only in Codex (it also scans $CWD/..). For Claude Code, start it at
the collection root or pass `--add-dir ..`.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --collection) collection="${2:?--collection needs a directory}"; shift 2;;
    --all)        all=yes; shift;;
    --dry-run)    dry_run=yes; shift;;
    -h|--help)    usage; exit 0;;
    *) echo "error: unknown option: $1 (use --help)" >&2; exit 1;;
  esac
done

# --all re-execs per collection rather than looping inline: one code path for
# one collection, and a collection whose harness is mid-rebase can't take the
# sweep down with it.
if [ "$all" = yes ]; then
  swept=0 failed=0
  for dir in "$ROOT"/*/; do
    dir="${dir%/}"
    [ -d "$dir/$harness_dirname" ] || continue
    swept=$((swept + 1))
    echo "=== $(basename "$dir")"
    if [ "$dry_run" = yes ]; then
      "$0" --collection "$dir" --dry-run || failed=$((failed + 1))
    else
      "$0" --collection "$dir" || failed=$((failed + 1))
    fi
    echo
  done
  echo "swept $swept collection(s), $failed failed"
  [ "$failed" -eq 0 ] || exit 1
  exit 0
fi

[ -d "$collection" ] || { echo "error: collection not found: $collection" >&2; exit 1; }
collection="$(cd "$collection" && pwd)"
[ -d "$collection/$harness_dirname" ] || {
  echo "error: $collection has no $harness_dirname/ — not a collection" >&2; exit 1; }

# Source is the TARGET collection's own harness worktree, not necessarily the
# one running this script: the links are relative, so they resolve against the
# harness sitting next to them. Reading the list from anywhere else would
# happily write links that dangle (another collection's harness may be on a
# branch where a skill does not exist yet).
src_root="$collection/$harness_dirname/skills"

# Skill names: a directory under skills/ holding a SKILL.md. Anything else
# there (README, shared references) is deliberately not a skill.
skill_names() {
  [ -d "$src_root" ] || return 0
  for d in "$src_root"/*/; do
    [ -f "${d}SKILL.md" ] || continue
    basename "${d%/}"
  done
}

# An empty list is not an early exit: the prune pass below still has to clear
# links left over from skills that have since been removed or renamed.
names="$(skill_names)"

echo "collection: $collection"
if [ -n "$names" ]; then
  echo "skills:     $(printf '%s' "$names" | tr '\n' ' ')"
else
  # Not an error: an older harness worktree simply predates skills/. Say which
  # worktree is short, so the fix (update it, then re-run) is obvious rather
  # than looking like this tool failing silently.
  echo "skills:     (none — $harness_dirname/ has no skills/ on its current"
  echo "            branch; catch that worktree up first, then re-run)"
fi

linked=0; current=0; pruned=0; skipped=0

for root in $SKILL_ROOTS; do
  dest_root="$collection/$root"
  # Both roots sit two levels below the collection, so one relative prefix
  # serves both. Relative, not absolute: the links stay correct if the whole
  # workspace moves, and they read as obviously collection-internal.
  rel_prefix="../../$harness_dirname/skills"

  # Don't conjure an empty skills dir in a collection that has no skills —
  # Claude Code only watches skill roots that existed at startup, so an empty
  # one is worse than absent.
  if [ -n "$names" ] && [ "$dry_run" = no ]; then
    mkdir -p "$dest_root"
  fi

  for name in $names; do
    dest="$dest_root/$name"
    want="$rel_prefix/$name"

    if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$want" ]; then
      current=$((current + 1))
      continue
    fi

    # Never replace a hand-authored skill: a real directory here is somebody's
    # deliberate local override, and there is no safe place to back it up.
    if [ -e "$dest" ] && [ ! -L "$dest" ]; then
      echo "    skip (not a symlink — local override?): $root/$name" >&2
      skipped=$((skipped + 1))
      continue
    fi

    if [ "$dry_run" = yes ]; then
      echo "    would link: $root/$name"
      linked=$((linked + 1))
      continue
    fi

    ln -sfn "$want" "$dest"
    echo "    linked: $root/$name"
    linked=$((linked + 1))
  done

  # Prune links this tool owns whose skill is gone (renamed or deleted
  # upstream). Ownership test is the target prefix, so unrelated skills
  # symlinked in by hand are left alone.
  [ -d "$dest_root" ] || continue
  for entry in "$dest_root"/*; do
    [ -L "$entry" ] || continue
    target="$(readlink "$entry")"
    case "$target" in "$rel_prefix"/*) ;; *) continue ;; esac
    [ -f "$entry/SKILL.md" ] && continue
    if [ "$dry_run" = yes ]; then
      echo "    would prune: $root/$(basename "$entry")"
    else
      rm -f "$entry"
      echo "    pruned: $root/$(basename "$entry")"
    fi
    pruned=$((pruned + 1))
  done
done

echo
echo "linked=$linked already-current=$current pruned=$pruned skipped=$skipped"
exit 0
