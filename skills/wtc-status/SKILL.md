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
(`✓ ✗ ● —`), and working-tree state. Bare is the command to reach for: scope
is this collection, and `--repos` / `--watch` / `--no-click` default from
`$WTC_CONFIG_ROOT/wtc.env`. Captured output prints one pass, so reading the
table from an agent shell never hangs on a watch loop.

## Everything at once

```bash
harness/tools/wtc-status.sh --all               # every collection
harness/tools/wtc-status.sh --procs             # processes under the herdr session
harness/tools/wtc-status.sh --repos --watch 120 # for a human to leave open
```

`--watch` is for a pane a human is looking at. **Don't run a watch loop to
answer a question** — take the snapshot, answer, stop.

The collection table is clickable where both ends have a terminal — that's for
the human reading the pane, not for you. Each target does one thing: `REPO`
focuses that sibling in the browse nvim, `TREE` opens its diff view, the PR
**number** opens the pull request on github.com, and `❯` opens it in Octo in
the browse pane. `s` hands the mouse back so text can be selected (which also
freezes the table, since a redraw mid-drag would clear the selection), `a`
toggles merged PRs past 48 weekday-hours, and `?` shows the key and icon
reference.

## Reading it

The table fetches stale remote refs before measuring (age-gated, ~5 min), so
the numbers are current without you doing anything. `--no-fetch` when offline.

**BRANCH column**

- **`⌂ develop`** — detached at the development tip. This is the resting
  state, not a problem: no work is in flight in that worktree.
- **a branch name** — work in flight, or a branch whose PR has landed and
  hasn't been caught up yet.

**↑ and ↓ columns**

Commits ahead of and behind the remote, blank when zero.

- **`↑N`** — N commits not pushed.
- **`↓N`** — **N commits behind the development tip.** This is the catch-up
  signal, and it means the same thing for a detached worktree and for a
  branch: work started here would be built on stale ground. The footer counts
  them.

**TREE column**

- **`clean`** — nothing to say.
- **`±N`** — N changed files.

**PR column**

`#N` followed by up to three status slots, each silent unless it has something
to say — so a healthy PR is just `#225 ✓`.

- **checks** — `✓` passing · `✗` failing (that's `wtc-pr` §6.1) · `●` running,
  nothing to conclude yet · `D` draft · `·` no checks reported
- **merge** — `↓` behind its base · `⚠` conflicts · `⊘` blocked · `·` merged
  (fading) · blank clean
- **review** — `✓` approved · `!` changes requested · `…` waiting on assigned
  reviewers · `✎` commented, not yet approved · `⚠` ready with no reviewers
  assigned · `N` unresolved review threads · blank nothing outstanding

Blank overall means no open PR. Expected for `⌂` rows: nothing is in flight to
have one.

**PRS section** (scoped to one collection)

Lists the PRs enlisted for this collection in `<collection>/.wtc-prs`
(`tools/wtc-pr.sh enlist` — see the `wtc-pr` skill), not a forge label search —
so it costs no round trips beyond enriching what is already listed, and it is
still listed after the worktree has gone back to the tip. An open draft shows
a `DRAFT` badge. A **MERGED** PR fades rather than disappearing, and after 48
weekday-hours since merge it collapses behind the `a` (archived) toggle — `a`
shows a count when there is anything hidden.

A worktree still sitting on a branch whose PR has already merged or closed is
called out in **amber** (`⚠ #N`) — the one thing an open-PRs-only view would
otherwise hide, and exactly what a catch-up clears.

Unscoped runs skip the section: it is one API call per repo per collection, and
a `--watch` pane doing that across every collection is a rate limit waiting to
happen.

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
