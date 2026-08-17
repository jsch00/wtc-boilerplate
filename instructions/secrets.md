# Secrets and local config — control root

Machine-local secrets and per-repo local config live in a single **control
root** outside every repo and collection:

```text
~/.config/wtc/                 # $WTC_CONFIG_ROOT (this is the default)
  <repo-name>/<repo-relative-path>   # e.g. api/.env,
                                     #      console/.env.local
  certificates/                      # signing material not owned by any repo
```

A **shared control root**, not per-collection copies. Collections multiply
checkouts, and copies-per-collection means a rotated credential is stale in
every collection you did not think to update. One canonical copy per file,
**symlinked** into worktrees, is immediately current everywhere.

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
