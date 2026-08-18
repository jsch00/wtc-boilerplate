---
name: wtc-pr
description: Open or advance a review-ready pull request for work in a worktree collection — catch up against the remote, branch correctly if needed, push, open or un-draft the PR, request review, then follow its checks and review comments and address them with fixes and replies. Use when the user asks to open a PR, mark one ready, ship or land a change, chase a red build, or answer review feedback. For work in progress that should not summon reviewers yet, use wtc-draft-pr instead.
---

# Open or advance a review-ready PR

This skill is **resumable, not one-shot.** Run it whenever; it looks at where
the work actually stands and does the outstanding part. Nothing outstanding is
a valid outcome — say so and stop.

Work per repo. In a cross-repo wtc, run it once per sibling that has changes,
newest dependency first; each repo gets its own branch and its own PR under
its own conventions.

## 1. Read the ground

```bash
cd <collection>/<repo>
git branch --show-current
git status --short
gh pr view --json number,state,isDraft,url,baseRefName,headRefName,\
reviewDecision,mergeStateStatus,statusCheckRollup 2>/dev/null
```

The **base** is that repo's `default_ref` in `harness/.harness-repos.yml`,
minus the `origin/` prefix (`main` or `develop`). Never target a `release_ref`
— merging one deploys to production; that is a deliberate release action, not
a PR flow, and it needs the repo's `AGENTS.md` consulted and a human's say-so.

Check the repo's own `AGENTS.md` before pushing anything: some repos restrict
what may be committed from where.

## 2. Route on the PR state

| State | Do |
|---|---|
| No PR, on an issue branch with commits | §3 → §4 → §5 (create) |
| **Detached at the tip** (the resting state) | §2.1 — create the branch, that is what this moment is for |
| **Merged or closed** PR | The branch is finished. §2.1 for a fresh one; `wtc-catch-up` returns this worktree to the tip and prunes the local ref. Never reopen, never commit onto it. |
| Open **draft** | §3 → §4, then §5.2 (mark ready) → §6 |
| Open, ready for review | §3 → §4 (push anything outstanding) → §6 |

### 2.1 Create the branch — here, not earlier

Worktrees rest **detached at the development tip**; the branch is created at
the first commit, which is this moment, because now the work has a name:

```bash
git switch -c <issue-id>-<short-slug>
```

Uncommitted changes follow you onto the new branch. If the worktree is instead
sitting on an old branch whose PR merged, detach to the tip first
(`git checkout --detach <default_ref>`) so the new branch starts from current
code rather than from finished work.

The name encodes the issue — that mapping is the whole point, so keep it exact
(`api-foh7-paging-clamp`). Housekeeping with no issue still gets a short
descriptive branch (`setup/branch-policy-docs`). Then commit; multiple commits
are encouraged, they are the per-issue story.

## 3. Catch up before you open it

A PR raised against a stale base wastes a review round. Bring the base
forward first — run the `wtc-catch-up` skill, or at minimum:

```bash
git fetch --prune origin
git log --oneline HEAD..origin/<working-branch>   # what you are behind by
```

If the branch is behind and the tree is clean, **merge** the working branch
in — do not rebase. This policy keeps branch history intact; rebasing rewrites the
per-issue record:

```bash
git merge origin/<working-branch>
```

Conflicts are yours to resolve on the branch, then commit. If the tree is
dirty, commit or stash first — never merge into a dirty tree. If the merge is
large or the conflicts are semantic rather than textual, stop and tell the
user before proceeding.

## 4. Push

```bash
git push -u origin HEAD
```

Already-pushed and nothing new is fine — say "nothing to push" and move on.
Never force-push a branch that has an open PR unless the user asks: it
detaches existing review comments.

## 5. Open the PR

```bash
gh pr create --base <working-branch> --fill --title "<issue-id>: <what changed>"
```

- **Title** carries the issue ID, and the tracker key too when one exists
  (`api-foh7 / PROJ-123: clamp paging at 500`) — that is what makes the chain
  visible from GitHub.
- **Body** says what changed and why, what was verified, and anything a
  reviewer should look at hardest. Link the issue and the tracker ticket. If this
  is one of several PRs for one wtc, link the siblings.

### 5.1 Label it with the collection

```bash
gh pr create ... --label "wtc:$WTC_COLLECTION"
```

The label is how `wtc-status` finds this PR later — it is what lets a
collection list the work it has in flight after the worktree has already gone
back to the tip, and it needs no local file to go stale. Create it first if the
repo does not have it yet:

```bash
gh label create "wtc:$WTC_COLLECTION" --color ededed \
  --description "Opened from the $WTC_COLLECTION worktree collection" 2>/dev/null || true
```

`$WTC_COLLECTION` comes from `.env.collection`. If labelling fails — no
permission, a repo that refuses new labels — **open the PR anyway** and say so.
A PR that is missing from one status table is a smaller problem than a PR that
was never opened.

### 5.2 Ready for review

```bash
gh pr ready <n>                       # if it exists as a draft
gh pr edit <n> --add-reviewer <who>   # only if the repo doesn't auto-assign
```

Marking ready is what summons reviewers and the review bots. Do it only when
the change is genuinely reviewable — otherwise this is a `wtc-draft-pr` job.

## 6. Follow it

This is the part that makes the skill worth invoking twice.

### 6.1 Checks

```bash
gh pr checks <n>            # snapshot
gh pr checks <n> --watch    # only when the user is waiting on it
```

Red check → read the failing job's log (`gh run view <id> --log-failed`),
fix on the branch, commit, push. A failure in code the branch didn't touch is
worth saying out loud rather than silently retrying — flaky infrastructure and
a real regression need different responses. Never merge on red.

### 6.2 Review comments

```bash
gh pr view <n> --comments                          # conversation
gh api repos/{owner}/{repo}/pulls/<n>/comments      # inline review comments
```

For each unresolved comment, do **both** halves — a change without an answer
leaves the reviewer re-reading the diff to guess whether you agreed:

- **Agreed** → make the change in a normal commit on the branch, then reply
  pointing at the commit.
- **Disagreed** → reply with the reasoning, and leave the code alone. Do not
  quietly comply with a review you think is wrong.
- **Needs a decision that isn't yours** (scope, product behaviour, a breaking
  change) → surface it to the user rather than answering for them.

```bash
gh api repos/{owner}/{repo}/pulls/comments/<comment-id>/replies -f body='…'
gh pr comment <n> --body '…'      # for top-level conversation
```

Push once the round is addressed, then re-request review:

```bash
gh pr edit <n> --add-reviewer <who>
```

### 6.3 Merging is a separate decision

When checks are green and the PR is approved, **report that and stop.** Merge
only when the user asks, and then:

```bash
gh pr merge <n> --merge     # merge commit — never --squash, never --rebase
```

Merge commits are policy: individual commits stay queryable via
`git log <working-branch>`, merges-only via `git log --first-parent`.

**After merge, the branch is done**: no new commits on it, ever. The **remote**
branch is never deleted — it is the permanent per-issue record, so leave
GitHub's "Delete branch on merge" off. The **local** ref is disposable;
`wtc-catch-up` returns the worktree to the tip and prunes it.

## 7. Close the loop outside git

- **Issue**: record the PR link and the outcome. If it has a `tracker:` key and
  the work shipped, note that too.
- **Tracker**: comment only at meaningful transitions — started, blocked,
  shipped — referencing the issue ID and the PR. Never a running log; the
  detail lives in the issue and the PR. Transition the issue if the state
  actually changed.

## 8. Report

Say what you did, the PR URL, check status, how many review comments were
addressed vs. left open and why, and the one next thing that must happen —
including who has to do it if it isn't you.

---
Canon: `harness/instructions/development-workflows.md`,
`harness/.harness-repos.yml`.
