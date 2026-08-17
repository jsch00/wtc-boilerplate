---
name: wtc-status
description: Report where every worktree collection stands — branches, open PRs and their check rollups, working-tree state, and what is running under the herdr session. Use when the user asks what is in flight, which wtcs exist, what is red or blocked, whether a PR is green, or what they should pick up next.
---

# Where does everything stand

Answers "what is in flight" across the workspace, without touching anything.
Read-only.

## One collection

```bash
harness/tools/wtc-status.sh
```

Prints, per repo in the collection: branch, open PR with its check rollup
(`✓ ✗ ● —`), and working-tree state.

## Everything at once

```bash
harness/tools/wtc-status.sh --repos             # all collections
harness/tools/wtc-status.sh --procs             # processes under the herdr session
harness/tools/wtc-status.sh --repos --watch 120 # for a human to leave open
```

`--watch` is for a pane a human is looking at. **Don't run a watch loop to
answer a question** — take the snapshot, answer, stop.

The collection table is clickable where both ends have a terminal: the `PR`
cell opens the pull request in a browser, the `TREE` cell opens a diff view.
That's for the human reading the pane, not for you.

## Reading it

The table fetches stale remote refs before measuring (age-gated, ~5 min), so
the numbers are current without you doing anything. `--no-fetch` when offline.

**BRANCH column**

- **`⌂ develop`** — detached at the development tip. This is the resting
  state, not a problem: no work is in flight in that worktree.
- **a branch name** — work in flight, or a branch whose PR has landed and
  hasn't been caught up yet.

**TREE column**

- **`clean`** — nothing to say.
- **`±N`** — N changed files.
- **`↑N`** — N commits not pushed.
- **`↓N`** — **N commits behind the development tip.** This is the catch-up
  signal, and it means the same thing for a detached worktree and for a
  branch: work started here would be built on stale ground. The footer counts
  them.

**PR column**

- **`✗`** — a check is failing. Fixing it is the `wtc-pr` skill's §6.1.
- **`●`** — checks still running; nothing to conclude yet.
- **`—`** — a PR exists but has no checks, or none have reported.
- **blank** — no PR. Expected for `⌂` rows: nothing is in flight to have one.

A dirty tree in a collection nobody is working in is usually an interrupted
session. Worth surfacing; not yours to clean up.

## Then answer the actual question

Don't paste the table back. Say what is in flight, what is blocked and on
whom, what is green and merely waiting, and — if the user asked what to pick
up — which one, and why that one.

If a collection looks stale rather than blocked, the follow-up is
`wtc-catch-up`. If a wtc is finished, it is `wtc-retire`.

---
Canon: `harness/instructions/herdr.md`.
