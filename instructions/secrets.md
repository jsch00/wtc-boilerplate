# Secrets and local config — control root

Machine-local secrets and per-repo local config live in a single **control
root** outside every repo and collection:

```text
~/.config/wtc/                 # $WTC_CONFIG_ROOT (this is the default)
  wtc.env                            # machine-wide tool defaults (not secrets)
  <repo-name>/<repo-relative-path>   # e.g. api/.env,
                                     #      console/.env.local
  certificates/                      # signing material not owned by any repo
```

`wtc.env` is the one place a **changed default** belongs, so that a bare
`tools/wtc-xyz.sh` keeps doing what this machine wants without flags repeated
in every command line. It is read by `wtc-open.sh` and `wtc-status.sh` on
every run; CLI flags still win.

| Variable | Default | Effect |
|---|---|---|
| `WTC_AGENT_KIND` | `claude` | agent kind `wtc-open.sh` starts |
| `WTC_AGENT_ARGS` | — | args passed to the agent, replacing the built-in defaults |
| `WTC_STATUS_REPOS` | `no` | `yes` → status shows only the collection table |
| `WTC_STATUS_WATCH` | `60` | redraw interval in seconds; `0` prints once |
| `WTC_STATUS_NO_CLICK` | `no` | `yes` → no mouse capture, no constant redraw |

It holds defaults, not credentials — but it lives in the control root because
that is the machine-scoped, never-committed place that already exists.

A **shared control root**, not per-collection copies. Collections multiply
checkouts, and copies-per-collection means a rotated credential is stale in
every collection you did not think to update. One canonical copy per file,
**symlinked** into worktrees, is immediately current everywhere.

That holds for anything that rotates, and it leaves nowhere to put a
credential scoped to **one collection's work** — a throwaway sandbox key made
for a single investigation, say. Putting that in the control root hands it to
every collection on the machine. So there is a second, narrower tier
alongside it (see "Collection-scoped secrets"). The rule of thumb: **rotates
for the machine → control root; belongs to this piece of work →
collection-scoped.**

`WTC_CONFIG_ROOT` is exported in every collection's `.env.collection`
(default `~/.config/wtc`). Files are stored at their repo-relative
path, so linking is mechanical.

## Wiring a worktree

`tools/link-secrets.sh` does it, for every checked-out repo in a collection:

```sh
tools/link-secrets.sh                 # this harness worktree's collection
tools/link-secrets.sh --collection ../billing --dry-run
tools/link-secrets.sh --repo api     # what init hooks pass
```

Because files are stored at their repo-relative path, the tool needs no
manifest — it walks `<control-root>/<repo>/` and mirrors each file into the
matching worktree. It is idempotent, and re-running is the point: it is what
init hooks call at creation time (`hooks-and-env.md`) and what catch-up calls
to pick up files added since (`AGENTS.md` → Catch-up rules).

What it will not do:

- **Link a target that is not gitignored.** It refuses and exits nonzero. Add
  the ignore rule in the repo first — never after the fact, when the secret
  has already been one `git add -A` away from a commit.
- **Link prod-capable paths** (rule 3 below) without `--include-prod`.
- **Destroy a hand-made copy.** An existing regular file is moved to the
  collection's `.harness-backups/` first — outside every worktree, since a
  backup beside the original would not match the ignore rule covering it.

Doing it by hand is `ln -sfn <control-root>/<repo>/<path> <worktree>/<path>`
(`-sfn`, not `-sf`: if the target is ever a directory, `-sf` drops the link
*inside* it). Verify with `git status` afterwards either way — a linked
secret that shows up as untracked means the ignore rule is missing.

## Collection-scoped secrets

```text
<collection>/.env.collection.local     # 600, seeded empty once, then hand-authored
```

Created empty by `write_collection_env` and **never rewritten**, unlike its
neighbour `.env.collection`, which is regenerated wholesale on every
`branch-off` — anything hand-added *there* is lost (and that file is not
chmod'd; its mode follows the caller's umask). The collection root is not a
git repo, so `.env.collection.local` cannot be committed by accident.
`retire.sh` deletes it with the collection — secrets scoped to this wtc die
with it.

`mise.toml` lists it second, so it composes with (and wins over) the generated
env:

```toml
[env]
_.file = [".env.collection", ".env.collection.local"]
```

Without mise (including `tools/wtc-open.sh`, which injects both into herdr):
`set -a; . ./.env.collection; . ./.env.collection.local; set +a`.

Two limits worth knowing before reaching for it:

- **It is collection-scoped, not repo-scoped.** Every repo in the collection
  inherits the variables, unlike the control root, which is stored per repo.
- **It holds variables, not files.** A per-collection secret *file* — a
  certificate, or a config the app reads directly — has no tier yet; the shape
  would be a `collections/<name>/<repo>/<path>` overlay that
  `link-secrets.sh` walks after the shared tier. Deliberately unbuilt until
  something needs it, because a whole-file override forces the collection copy
  to duplicate everything else in that file — the rotation problem the shared
  tier exists to avoid.

Rotating a collection-scoped secret is by hand, in that one file. That is the
trade: no shared copy to keep current, and no shared blast radius either.

## Rules

1. **Nothing from the control root is ever committed** — to any repo,
   including this one. The control root itself is not a git repo.
2. Secrets originate in a password manager (or the issuing service); the control
   root is the machine-local materialization. When rotating: update
   the password manager, then the control-root file.
3. Prod-capable material (e.g. deploy env files, signing certificates)
   stays out of worktrees entirely unless the task explicitly needs it —
   link it manually for that task and remove the link afterwards.
4. Per-user credentials that tools resolve globally belong in the tool's
   own global config, not per worktree — a package-registry token in the
   build tool's user-level config, a tracker token in that CLI's own config.
   Linking those per worktree multiplies the copies without making any of
   them easier to rotate.

## Inventory

Keep a table here of what actually exists in your control root, so the set is
reviewable without listing a directory full of credentials. The shape:

| Path under control root | Used by |
|---|---|
| `api/.env` | Local-dev auth + database connection |
| `console/.env.local` | Identity provider client + API URL selection |
| `web/.env` | App auth token + API base |
| `worker/.env.prod` | Deploy env — **prod-capable, rule 3 applies** |
| `certificates/<year>/` | Signing certs + provisioning profiles |

Two things earn their place in that table beyond the path: who consumes the
file, and whether it is prod-capable. The second is what rule 3 keys off, and
what `tools/link-secrets.sh` refuses to link without an explicit flag.
