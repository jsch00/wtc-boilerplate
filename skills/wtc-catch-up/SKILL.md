---
name: wtc-catch-up
description: Bring a worktree collection up to date with its remotes — fetch and prune every worktree owner (bare, or an unmanaged sibling's external clone), move detached worktrees onto the new development tip, return worktrees whose PR has merged to the tip and prune the local branch, merge the tip into live branches so they stop drifting and push that merge to any open PR, re-link secrets and harness skills, and refresh the collection env. Use when a collection looks stale or shows ↓ in the status table, after a PR merges, before opening a PR, after being away from a wtc, or when the user asks to sync, update, pull, or refresh the workspace.
---

# Catch a wtc up

Worktrees share bare owners, so "pull" is the wrong mental model: you fetch
the **bares**, then move each worktree individually under rules that differ by
what it is checked out on. Catch-up is also not git-only — files and skills
that reached the harness or the control root after this collection was created
never arrive on their own.

Safe by construction: nothing here rewrites history, force-pushes, or
touches a dirty tree. The only writes are fast-forwards, re-detaching, and
merging a base forward — none of which can lose or reorder a commit.

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
| On a **live** branch (no PR, or PR open) and clean | §2.3 — merge the base in, so the branch does not drift; §2.3.1 pushes it when a PR is open. |
| On a **live** branch and dirty | Nothing. Report ahead/behind — never merge into a dirty tree. |
| Mid-merge / mid-rebase / mid-cherry-pick | Nothing. Report it — someone is in the middle of something. |
| On a repo's default **branch** (legacy shape) | `git -C <wt> merge --ff-only @{u}` if clean, and suggest detaching so the branch stops being pinned to this collection. |

**Never rebase, never force-push, never touch a dirty tree.** Merging a base
forward either fast-forwards or creates a merge commit; rebasing a live branch
would rewrite the per-issue record, which is the one thing catch-up must not do.

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

### 2.3 A live branch: merge the base forward

A branch that is still being worked on drifts from its base every time
something lands. Left alone it drifts until the next PR is a conflict
resolution rather than a review, so catch-up brings the base to it:

```bash
git -C <wt> status --porcelain            # must be empty
git -C <wt> merge --no-edit <default_ref>
```

Merge, never rebase — the branch may already be pushed and under review, and
rebasing detaches review comments as well as rewriting history.

**Conflicts are where this stops.** Abort and hand it back rather than
resolving them mid-catch-up; the branch owner knows which side wins, and a
catch-up is not the moment to be making that call:

```bash
git -C <wt> merge --abort
```

Then report the conflicting paths and let the user decide.

### 2.3.1 If the branch has an open PR, push the merge

A branch with an open PR is already public, and a merge that sits unpushed
leaves reviewers reading the change against a base nobody is on any more. That
is the stale-base review round this whole section exists to prevent, so do not
be hesitant here — push it:

```bash
gh pr view --json state -q .state          # OPEN?
git -C <wt> push
```

Yes, this reruns the PR's checks. That is the point: a green build against a
base two weeks old is not information. Re-running against current code is what
makes the check mean something.

Two things this is not licence for. **Never force-push** — it detaches existing
review comments, and a base merge never needs one anyway. And if `push` refuses
because the upstream is wrong or the remote has commits you don't, stop and
report rather than reaching for `--force`; someone else may be pushing to the
same branch.

A branch with **no PR yet** is a different case: leave the merge local. Its
first push is `wtc-pr`'s, together with opening the PR.

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

## 4.1 Re-render the MCP servers

```bash
harness/tools/link-mcp.sh
```

Same lifecycle and the same ordering rule as the skills above: it renders
**this collection's** `harness/.mcp-servers.yml` into `.mcp.json`,
`.cursor/mcp.json` and `.codex/config.toml` at the collection root, so a
server added to the registry since reaches this collection, and one removed
or disabled since stops being offered. `--all` rolls a registry change across
every (already caught-up) collection.

It prints `note: unset in this shell: …` when a rendered server names a
credential the environment does not supply. That is information, not a
failure — the config is correct and the credential is missing. Fix it where
the variable belongs (`instructions/secrets.md`), not by editing the rendered
file, which is overwritten on the next run.

## 4.5 Refresh the collection env

```bash
harness/tools/refresh-env.sh
```

`.env.collection` is written by `write_collection_env`, and only `branch-off`
(new collection) and `add-repo` (only when the file is missing) ever call it.
So a variable added to the generator since — a port for a newly registered
repo, `GH_CONFIG_DIR` — reaches new collections only, and every older
collection stays stale indefinitely. This is the missing half.

Same ordering rule as the skills above: it runs **this collection's**
`harness/` generator, so it must come *after* step 2 moved that worktree.

It preserves the collection's port base, so ports do not move, and leaves
`.env.collection.local` alone. It regenerates `.env.collection` wholesale,
which is that file's documented contract — hand-authored values belong in
`.env.collection.local`, which wins on a conflicting key. `--dry-run` shows
the diff and writes nothing; `--all` sweeps every collection.

**Already-open herdr panes do not pick this up.** `wtc-open.sh` injects the
env at workspace *creation* and skips that block when reusing an open
workspace, so a pane keeps whatever it started with. Close and reopen the
workspace, or export by hand in the pane.

## 4.6 Ambient CLI credentials — ask, once, and only when it is new

`gh`, `twg` and `jira` each resolve one credential store per machine, so by
default every project on the machine shares whichever account is logged in.
The harness can give this workspace its own store instead, opt-in by presence
(`harness/instructions/secrets.md` → Tool identity).

Catch-up is when a workspace usually *discovers* this option, because the
generator learned to emit those variables in a version newer than the
collection. So check whether the choice has been made:

```bash
ls -d "${WTC_CONFIG_ROOT:-$HOME/.config/wtc}"/gh 2>/dev/null   # opted in?
grep -c GH_CONFIG_DIR .env.collection 2>/dev/null              # in effect here?
```

- **Store exists** → nothing to ask. §4.5 already emitted the variables.
- **Store absent, and the collection is otherwise up to date** → nothing to
  ask either. Do not raise it on every catch-up; a workspace that has said no
  once should not be asked again.
- **Store absent, and §4.5 just moved this collection onto a generator that
  understands tool identity** → this is the one moment worth a question. Ask
  the user how they want ambient CLI creds handled, and offer the two answers
  plainly:

  | Answer | What you do |
  |---|---|
  | *Machine-global is fine — this is the only thing I use `gh` for* | Nothing. Say so in the report and move on. |
  | *Scope it to this workspace* | `mkdir -p "$WTC_CONFIG_ROOT"/gh`, re-run `refresh-env.sh`, then tell them to `gh auth login` from inside a collection |

**Do not run `gh auth login` for them, and do not create the store without
being asked.** Creating it *is* the opt-in, and turning it on logs them out
inside every collection until they re-auth — a surprise no catch-up should
spring on someone. Report the choice offered and the answer taken.

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

Then, in one line: anything that needs a human — dirty trees, a merge that
aborted on conflicts, a refused secret link, a `branch -d` that refused, a
repo mid-rebase.

For every live branch you merged into (§2.3), say so, and name the PR you
pushed the merge to — its checks are now rerunning because of you. For a
branch with no PR, give the unpushed count instead. A merge that aborted on
conflicts is the first thing a human needs to see.

If §4.5 changed `.env.collection`, say which variables moved — a port that
shifted or a tool-identity variable that appeared changes what an already-open
herdr pane is running with, and only a reopened workspace picks it up. If §4.6
asked about ambient credentials, report the question and the answer; if it did
not ask, say nothing about it.

---
Canon: `harness/AGENTS.md` → Catch-up rules,
`harness/instructions/secrets.md`, `harness/instructions/skills.md`.
