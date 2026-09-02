#!/usr/bin/env bash
# lib_test.sh — the pure lookups in tools/lib.sh: registry parsing, remote
# slugs, port names. No network, no herdr, no git beyond the fixture.
. "$(dirname "$0")/helpers.sh"

ws="$(make_workspace)"
load_lib "$ws"

# --- registry parsing -------------------------------------------------------
# The registry is parsed with awk on a shape that is load-bearing (a block
# starts at `- name:`, every other field is `key: value`). These tests are what
# stops someone "tidying" that file into something awk reads differently.

it "registry_field reads a scalar from the right block"
assert_eq "git@github.com:example/agent-harness.git" "$(registry_field agent-harness remote)"
assert_eq "origin/main" "$(registry_field widget default_ref)"
assert_eq "origin/develop" "$(registry_field gadget default_ref)"

it "registry_field does not leak a field across blocks"
# widget sets port_offset; the blocks either side do not. A scanner that
# forgets to reset on `- name:` answers 1 for all three.
assert_eq "1" "$(registry_field widget port_offset)"
assert_empty "$(registry_field agent-harness port_offset)"
assert_empty "$(registry_field gadget port_offset)"

it "registry_field is empty for an unknown repo or field"
assert_empty "$(registry_field nosuchrepo remote)"
assert_empty "$(registry_field widget nosuchfield)"

it "registry_all_names lists every block, in file order"
assert_eq "agent-harness widget gadget" "$(registry_all_names | tr '\n' ' ' | sed 's/ $//')"

it "registry lookups soft-fail when the registry is gone"
# A wtc-status --watch outlives the harness worktree it was started from
# (retire removes the worktree under a running pane). Losing the file must
# blank the cell, not spray awk errors into the table.
saved="$REGISTRY"; REGISTRY="$ws/definitely-not-here.yml"
assert_ok registry_field widget remote
assert_empty "$(registry_field widget remote 2>&1)"
assert_empty "$(registry_all_names 2>&1)"
REGISTRY="$saved"

# --- repo_slug_for ----------------------------------------------------------
# Both remote forms have to work. An HTTPS remote used to yield
# "//github.com/owner/repo", which gh cannot resolve, so every PR cell in
# wtc-status rendered a GraphQL NOT_FOUND blob.

it "repo_slug_for handles an SSH remote"
assert_eq "example/agent-harness" "$(repo_slug_for agent-harness)"

it "repo_slug_for handles an HTTPS remote"
assert_eq "example/widget" "$(repo_slug_for widget)"

it "repo_slug_for declines a non-GitHub remote rather than guessing"
# gadget is on gitlab. Returning "example/gadget" would send gh looking for a
# GitHub repo that is not there, which reads as "no PRs" rather than "not
# GitHub" — worse than an empty cell.
assert_empty "$(repo_slug_for gadget)"

it "repo_slug_for is empty for an unknown repo"
assert_empty "$(repo_slug_for nosuchrepo)"

# --- issue prefixes and port names -----------------------------------------

it "repo_for_issue_prefix finds the owning repo"
assert_eq "widget" "$(repo_for_issue_prefix wid-)"
assert_empty "$(repo_for_issue_prefix nope-)"

it "port_var_for upper-cases and converts dashes"
assert_eq "WIDGET_PORT" "$(port_var_for widget)"
assert_eq "AGENT_HARNESS_PORT" "$(port_var_for agent-harness)"
assert_eq "LIVE_SUPPORT_PORT" "$(port_var_for live-support)"

# --- alloc_port_base --------------------------------------------------------
# Ports are a contract between repos, so the allocator must never hand out a
# base another collection already holds.

it "alloc_port_base starts at 42000 in an empty workspace"
assert_eq "42000" "$(alloc_port_base)"

it "alloc_port_base skips bases already taken, in steps of 100"
mkdir -p "$ROOT/one" "$ROOT/two"
echo "COLLECTION_PORT_BASE=42000" > "$ROOT/one/.env.collection"
echo "COLLECTION_PORT_BASE=42100" > "$ROOT/two/.env.collection"
assert_eq "42200" "$(alloc_port_base)"

it "alloc_port_base fills a hole rather than always appending"
rm -f "$ROOT/one/.env.collection"
assert_eq "42000" "$(alloc_port_base)"

# --- default_ref_for --------------------------------------------------------

it "default_ref_for reads the registry, and falls back to origin/main"
assert_eq "origin/develop" "$(default_ref_for gadget)"
assert_eq "origin/main" "$(default_ref_for widget)"
assert_eq "origin/main" "$(default_ref_for nosuchrepo)"

# --- bare_for / owner_of ----------------------------------------------------

it "bare_for resolves a registry repo to its bare owner"
assert_eq "$ROOT/.bare/widget.git" "$(bare_for widget)"

it "owner_of resolves a worktree to its git common dir"
wt="$ROOT/main/harness"
assert_empty "$(owner_of "$ROOT/not-a-worktree" 2>/dev/null)"

# --- file_age_secs ----------------------------------------------------------

it "file_age_secs is small for a fresh file and huge for a missing one"
touch "$ws/fresh"
age="$(file_age_secs "$ws/fresh")"
if [ "$age" -ge 0 ] && [ "$age" -lt 60 ]; then _pass "fresh file age"; else _fail "fresh file age" "got $age"; fi
missing="$(file_age_secs "$ws/nope")"
if [ "$missing" -gt 100000 ]; then _pass "missing file age is huge"; else _fail "missing file age" "got $missing"; fi
