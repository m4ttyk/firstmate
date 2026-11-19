# Carried patches

This repository is a fork of upstream Firstmate.
The `carry` branch is the upstream default branch plus the patches listed below, and nothing else.

## How the `carry` branch moves

- `carry` advances only by merging the upstream default branch into it, or by adding a carried patch on top.
- `carry` is never rebased and never force-pushed.
  Self-update only fast-forwards a running home, so rewritten history would strand every home that follows this branch.
- Upstream code is never edited in place for local taste.
  A carried patch keeps its logic in files upstream does not have and touches an upstream file only at a minimal, named call site.
- The fork is public.
  A carried patch holds no private content: no real project names, usernames, home-directory paths, emails, or company names.

## Taking a new upstream

1. Merge the upstream default branch into `carry`.
2. Resolve conflicts only in the upstream files listed under "Upstream files touched" below; a conflict anywhere else means a carried patch has leaked into upstream code and should be moved back out.
3. Run each patch's verification entry point.

## Carried patches

### Repository overlays

A home's private, per-repository agent instructions are placed into every worker copy of that project and kept out of that project's git history.
[`docs/overlays.md`](docs/overlays.md) owns the operator contract.

New files:

- `bin/fm-overlay.sh`
- `tests/fm-overlay.test.sh`
- `docs/overlays.md`
- `CARRY.md`

Upstream files touched:

- `bin/fm-spawn.sh`: one call to `bin/fm-overlay.sh apply`, with its one-line comment, directly after `spawn_assert_agent_worktree`.
- `docs/documentation-audiences.json`: the inventory entries for `CARRY.md` and `docs/overlays.md`, which `bin/fm-doc-audience-check.sh` requires for every tracked Markdown file.

Verification entry point: `bash tests/fm-overlay.test.sh`.

`bin/fm-test-run.sh --check-coverage` reports `tests/fm-overlay.test.sh` as an unmeasured serial member and can tip the unhinted share over its bound.
That is deliberate: the hint table in `bin/fm-test-run.sh` changes often upstream, so a carried hint line would add a recurring merge conflict, and CI runs only on `main`, never on `carry`.
