---
name: wtc-catch-up
description: Bring a worktree collection up to date with its remotes — fetch and prune every bare owner, move detached worktrees onto the new development tip, return worktrees whose PR has merged to the tip and prune the local branch, report how far live branches have drifted, and re-link secrets and harness skills. Use when a collection looks stale or shows ↓ in the status table, after a PR merges, before opening a PR, after being away from a wtc, or when the user asks to sync, update, pull, or refresh the workspace.
---

# Catch a wtc up

Worktrees share bare owners, so "pull" is the wrong mental model: you fetch
the **bares**, then move each worktree individually under rules that differ by
what it is checked out on. Catch-up is also not git-only — files and skills
that reached the harness or the control root after this collection was created
never arrive on their own.

Read-mostly and safe: nothing here rewrites history or touches a dirty tree.

## 1. Fetch every owner

```bash
harness/tools/refresh-configs.sh          # prints the bare list; regenerates .harness-repos
```

Then, for each bare (or loop over `.harness-repos`, which is `name=path`):

```bash
git --git-dir=<bare> fetch --prune origin
```

Fetching the bare updates every worktree's view of `origin/*` at once,
including collections other than this one.

`.bare/` is not the whole list. Unmanaged `ext.` siblings are owned by an
ordinary clone elsewhere on disk (`instructions/worktree-workspace.md`), so
fetch them from the worktree side — this form works for every sibling,
registry or not, and needs no lookup:

```bash
for wt in <collection>/*/; do
  git --git-dir="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)" \
    fetch --prune origin
done
```

## 2. Move each worktree, by what it is

The resting state of a worktree is **detached at the development tip**, not a
branch (`harness/instructions/development-workflows.md`). Catch-up's job is to
move the tip forward under it, and to return worktrees to that state once
their work has landed.

For every worktree:

```bash
git -C <worktree> status --short                       # clean?
git -C <worktree> symbolic-ref -q HEAD || echo detached
git -C <worktree> rev-list --count HEAD..<default_ref>  # how stale
gh pr view --json state,url 2>/dev/null                # only if on a branch
```

`<default_ref>` per repo is in `harness/.harness-repos.yml` (`origin/main` or
`origin/develop`).

| The worktree is | Do |
|---|---|
| **Detached** and clean | `git -C <wt> checkout --detach <default_ref>` — move it to the new tip. Always safe: no branch to move, nothing to conflict. |
| **Detached** and dirty | Nothing. Report it — someone is mid-edit with no branch yet. |
| On a branch, **PR merged**, clean, nothing outside the base | §2.1 — return to tip, prune the local ref. |
| On a branch, **PR merged**, but dirty or with post-merge commits | §2.2 — that is follow-up work; give it a branch of its own first. |
| On a **live** branch (no PR, or PR open) | Nothing. Report ahead/behind; merging the tip in is the branch owner's call. |
| Mid-merge / mid-rebase / mid-cherry-pick | Nothing. Report it — someone is in the middle of something. |
| On a repo's default **branch** (legacy shape) | `git -C <wt> merge --ff-only @{u}` if clean, and suggest detaching so the branch stops being pinned to this collection. |

**Never rebase, never merge automatically, never touch a dirty tree.**
Fast-forwards and re-detaching are the only automatic moves, because they are
the only ones that cannot lose or reorder anything.

### 2.1 A merged branch: back to the tip, prune the local ref

```bash
gh pr view --json state -q .state          # MERGED?
git -C <wt> rev-list --count <default_ref>..HEAD   # must be 0
git -C <wt> checkout --detach <default_ref>
git -C <wt> branch -d <branch>
```

`git branch -d` (never `-D`) is the safety net: it refuses to delete anything
not genuinely merged, and since this policy merges with merge commits rather than
squashing, it can tell. If it refuses, **stop and report** — the branch has
something the base does not.

The **remote** branch stays. It is the per-issue record, and
`git branch -r | grep <issue-id>` is how anyone finds what was done for an issue
later. Never delete it, and leave GitHub's "Delete branch on merge" off.

### 2.2 Carrying work off a merged branch

Uncommitted changes, or commits made after the merge, are follow-up work that
never belonged on a finished branch:

```bash
# post-merge commits: keep them, rename the line of work
git -C <wt> switch -c <issue-id>-<slug>-followup
git -C <wt> branch -d <old-branch>      # the old ref, now redundant

# uncommitted changes only: they follow you across
git -C <wt> checkout --detach <default_ref>
```

Uncommitted changes survive a `checkout --detach` as long as they don't
conflict; if git refuses, leave the worktree alone and report it. Pick a
follow-up name that says what the work is — and say in your report that you
renamed it, since nobody asked you to name anything.

## 3. Re-link machine-local secrets

```bash
harness/tools/link-secrets.sh
```

Idempotent, and re-running is the point: init hooks ran at worktree creation
only, so a control-root file added since then has never reached this
collection.

A **nonzero exit means it refused a target that is not gitignored** — that is
not a catch-up failure to shrug at. Add the ignore rule in the offending repo
first, then re-run. Never link a secret into a path git would offer to commit.

## 4. Re-link the harness skills

```bash
harness/tools/link-skills.sh
```

Picks up `wtc-*` skills added to the harness since the collection was created
and prunes ones removed since. Also idempotent.

Order matters here: this links whatever **this collection's** `harness/`
worktree has in git, so it must run *after* step 2 moved that worktree. If it
reports `(none)`, the harness worktree is behind rather than the tool being
broken. To roll a newly landed skill out across every collection at once —
each of which must be caught up first — `harness/tools/link-skills.sh --all`.

## 5. Local refs left over from earlier work

§2.1 prunes the branch of the worktree it moved. Other local branches in the
same repo may also be finished — merged, with no worktree on them:

```bash
git -C <wt> branch --merged <default_ref>
```

Those are prunable with `git branch -d`, which will refuse anything not
genuinely merged. **The remote is never touched.** A local ref costs nothing
to keep, so when in doubt leave it; the point of pruning is that a worktree
stops sitting on dead work, not tidiness for its own sake.

## 6. Report

Per repo: where the HEAD is now (tip or branch), whether it moved and why,
ahead/behind counts, and tree state. Call out explicitly anything you
**deleted or renamed** — a pruned local ref or a follow-up branch — even
though both are recoverable, because neither was asked for.

Then, in one line: anything that needs a human — dirty trees, live branches
far behind their base, a refused secret link, a `branch -d` that refused, a
repo mid-rebase.

If a live branch is far enough behind that its next PR would conflict, say so
and recommend merging the tip into it (via the `wtc-pr` skill's §3) rather
than doing it unasked.

---
Canon: `harness/AGENTS.md` → Catch-up rules,
`harness/instructions/secrets.md`, `harness/instructions/skills.md`.
