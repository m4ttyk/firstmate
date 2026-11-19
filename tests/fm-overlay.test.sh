#!/usr/bin/env bash
# Tests for bin/fm-overlay.sh, the private repository overlay a home places
# into each worker copy (docs/overlays.md).
#
# Every case drives the real executable, the real spawn, or the real cleanup
# against throwaway git repositories:
#   - apply mirrors the overlay into the copy with file modes intact
#   - no overlay directory is a silent no-op that writes nothing
#   - a symbolic link is placed as a link
#   - placed files are invisible to git status and to `git add -A`
#   - a path the repository tracks is skipped and named, never overwritten
#   - a second apply refreshes content and removes a withdrawn path
#   - a withdrawn overlay directory removes what it placed
#   - an untracked file the overlay did not place is never overwritten
#   - a path the repository re-includes is never left visible to git
#   - an overlay that cannot be applied as written exits non-zero
#   - cleanup's landed-work check ignores overlay files but still refuses a
#     genuinely unlanded file beside them
#   - a pooled copy holding an overlay returns clean and is refreshed for its
#     next holder
#   - the spawn places the overlay into the worker copy, and stops when the
#     overlay cannot be applied
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_git_identity fmtest fmtest@example.invalid

OVERLAY="$ROOT/bin/fm-overlay.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-overlay-tests)

# make_case <name>: a home data directory, a project named demo-project with
# one tracked file, and a linked worktree standing in for the worker copy.
# Sets CASE_DIR, DATA_DIR, PROJECT_DIR, WT_DIR, and OVERLAY_DIR (not created).
make_case() {
  CASE_DIR="$TMP_ROOT/$1"
  DATA_DIR="$CASE_DIR/home/data"
  PROJECT_DIR="$CASE_DIR/demo-project"
  WT_DIR="$CASE_DIR/wt"
  OVERLAY_DIR="$DATA_DIR/overlays/demo-project"
  mkdir -p "$DATA_DIR"
  fm_git_init_commit "$PROJECT_DIR"
  git -C "$PROJECT_DIR" worktree add --quiet -b fm/task-x1 "$WT_DIR"
}

# apply: run the executable for the current case. Sets APPLY_OUT (stdout),
# APPLY_ERR (stderr), and APPLY_RC.
apply() {
  APPLY_RC=0
  APPLY_OUT=$(bash "$OVERLAY" apply "$DATA_DIR" "$PROJECT_DIR" "$WT_DIR" 2>"$CASE_DIR/apply.err") || APPLY_RC=$?
  APPLY_ERR=$(cat "$CASE_DIR/apply.err")
}

wt_status() {
  git -C "$WT_DIR" status --porcelain --untracked-files=all
}

exclude_file() {
  local path
  path=$(git -C "$WT_DIR" rev-parse --git-path info/exclude)
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *) printf '%s\n' "$WT_DIR/$path" ;;
  esac
}

test_apply_mirrors_the_overlay_with_modes() {
  make_case apply
  mkdir -p "$OVERLAY_DIR/.agents/skills/demo-skill" "$OVERLAY_DIR/tools"
  printf 'private instructions\n' > "$OVERLAY_DIR/AGENTS.md"
  printf 'skill body\n' > "$OVERLAY_DIR/.agents/skills/demo-skill/SKILL.md"
  printf '#!/bin/sh\necho ok\n' > "$OVERLAY_DIR/tools/helper.sh"
  chmod 755 "$OVERLAY_DIR/tools/helper.sh"

  apply
  expect_code 0 "$APPLY_RC" "apply: a plain overlay must apply"$'\n'"$APPLY_ERR"
  assert_equals 'private instructions' "$(cat "$WT_DIR/AGENTS.md")" \
    "apply: the root file did not land at the same relative path"
  assert_equals 'skill body' "$(cat "$WT_DIR/.agents/skills/demo-skill/SKILL.md")" \
    "apply: the nested file did not land at the same relative path"
  [ -x "$WT_DIR/tools/helper.sh" ] || fail "apply: the executable bit was not preserved"
  [ ! -x "$WT_DIR/AGENTS.md" ] || fail "apply: a plain file gained an executable bit"
  assert_equals '' "$APPLY_OUT" "apply: stdout must stay empty"
  assert_contains "$APPLY_ERR" 'overlay: placed 3 path(s)' "apply: the placement was not reported"
  pass "apply mirrors the overlay into the worker copy with file modes intact"
}

test_no_overlay_is_a_silent_noop() {
  local before_files before_exclude
  make_case no-overlay
  mkdir -p "$DATA_DIR/overlays/another-project"
  printf 'not for this project\n' > "$DATA_DIR/overlays/another-project/AGENTS.md"
  before_files=$(find "$WT_DIR" "$PROJECT_DIR/.git" | LC_ALL=C sort)
  before_exclude=$(cat "$(exclude_file)" 2>/dev/null || true)

  apply
  expect_code 0 "$APPLY_RC" "no-overlay: a project without an overlay must not fail"
  assert_equals '' "$APPLY_OUT$APPLY_ERR" "no-overlay: the no-op printed output"
  assert_equals "$before_files" "$(find "$WT_DIR" "$PROJECT_DIR/.git" | LC_ALL=C sort)" \
    "no-overlay: the no-op created or removed a file"
  assert_equals "$before_exclude" "$(cat "$(exclude_file)" 2>/dev/null || true)" \
    "no-overlay: the no-op changed the git exclude file"
  assert_absent "$WT_DIR/AGENTS.md" "no-overlay: another project's overlay leaked into this copy"
  pass "a project with no overlay directory is a silent no-op"
}

test_symlink_is_placed_as_a_symlink() {
  make_case symlink
  mkdir -p "$OVERLAY_DIR"
  printf 'private instructions\n' > "$OVERLAY_DIR/AGENTS.md"
  ln -s AGENTS.md "$OVERLAY_DIR/CLAUDE.md"

  apply
  expect_code 0 "$APPLY_RC" "symlink: the overlay must apply"$'\n'"$APPLY_ERR"
  [ -L "$WT_DIR/CLAUDE.md" ] || fail "symlink: CLAUDE.md was copied as a file, not a link"
  assert_equals 'AGENTS.md' "$(readlink "$WT_DIR/CLAUDE.md")" "symlink: the link target changed"
  assert_equals 'private instructions' "$(cat "$WT_DIR/CLAUDE.md")" \
    "symlink: the link does not resolve inside the copy"
  [ ! -L "$WT_DIR/AGENTS.md" ] || fail "symlink: the regular file became a link"
  pass "a symbolic link in the overlay is placed as a symbolic link"
}

test_placed_files_are_invisible_to_git() {
  make_case invisible
  mkdir -p "$OVERLAY_DIR/docs/rules"
  printf 'private instructions\n' > "$OVERLAY_DIR/AGENTS.md"
  ln -s AGENTS.md "$OVERLAY_DIR/CLAUDE.md"
  printf 'rule\n' > "$OVERLAY_DIR/docs/rules/demo [draft]*.md"

  apply
  expect_code 0 "$APPLY_RC" "invisible: the overlay must apply"$'\n'"$APPLY_ERR"
  assert_present "$WT_DIR/docs/rules/demo [draft]*.md" "invisible: the glob-named file was not placed"
  assert_equals '' "$(wt_status)" "invisible: overlay files appear in git status"
  git -C "$WT_DIR" add -A
  assert_equals '' "$(git -C "$WT_DIR" diff --cached --name-only)" \
    "invisible: git add -A staged an overlay file"
  assert_equals '' "$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=all)" \
    "invisible: the primary checkout became dirty"
  assert_equals "$(git -C "$PROJECT_DIR" rev-parse HEAD)" "$(git -C "$WT_DIR" rev-parse HEAD)" \
    "invisible: applying moved the copy's HEAD"
  # An unrelated untracked file must stay visible: the exclusions are per path.
  printf 'work\n' > "$WT_DIR/docs/rules/real-work.md"
  assert_contains "$(wt_status)" '?? docs/rules/real-work.md' \
    "invisible: the exclusions hid a file the overlay does not carry"
  pass "placed overlay files never appear in git status and are not staged by git add -A"
}

test_tracked_path_is_skipped_not_overwritten() {
  make_case tracked
  mkdir -p "$OVERLAY_DIR"
  printf 'overlay readme\n' > "$OVERLAY_DIR/README.md"
  printf 'private instructions\n' > "$OVERLAY_DIR/AGENTS.md"

  apply
  expect_code 0 "$APPLY_RC" "tracked: a tracked path must be skipped, not fail the apply"$'\n'"$APPLY_ERR"
  assert_contains "$APPLY_ERR" 'overlay: skipped README.md: the repository tracks this path' \
    "tracked: the skipped path was not named"
  assert_equals 1 "$(printf '%s\n' "$APPLY_ERR" | grep -c 'README.md')" \
    "tracked: the skip was not reported on exactly one line"
  assert_equals '# demo-project' "$(cat "$WT_DIR/README.md")" "tracked: the tracked file was overwritten"
  assert_equals 'private instructions' "$(cat "$WT_DIR/AGENTS.md")" \
    "tracked: the untracked overlay path beside it was not placed"
  assert_equals '' "$(wt_status)" "tracked: the copy is dirty after a skip"
  pass "a path the repository tracks is skipped with one line naming it"
}

test_reapply_refreshes_and_removes_withdrawn_paths() {
  local exclude_lines
  make_case reapply
  mkdir -p "$OVERLAY_DIR/docs/rules"
  printf 'first\n' > "$OVERLAY_DIR/AGENTS.md"
  printf 'rule\n' > "$OVERLAY_DIR/docs/rules/demo.md"
  apply
  expect_code 0 "$APPLY_RC" "reapply: the first apply must succeed"$'\n'"$APPLY_ERR"
  exclude_lines=$(wc -l < "$(exclude_file)")

  apply
  expect_code 0 "$APPLY_RC" "reapply: an unchanged second apply must succeed"$'\n'"$APPLY_ERR"
  assert_equals "$exclude_lines" "$(wc -l < "$(exclude_file)")" \
    "reapply: an unchanged second apply grew the git exclude file"
  assert_equals 'first' "$(cat "$WT_DIR/AGENTS.md")" "reapply: an unchanged second apply changed content"

  printf 'second\n' > "$OVERLAY_DIR/AGENTS.md"
  rm -f "$OVERLAY_DIR/docs/rules/demo.md"
  printf 'edited in the copy\n' > "$WT_DIR/AGENTS.md"
  apply
  expect_code 0 "$APPLY_RC" "reapply: the refreshing apply must succeed"$'\n'"$APPLY_ERR"
  assert_equals 'second' "$(cat "$WT_DIR/AGENTS.md")" \
    "reapply: the placed file was not refreshed to the current overlay content"
  assert_absent "$WT_DIR/docs/rules/demo.md" "reapply: a path withdrawn from the overlay stayed in the copy"
  assert_absent "$WT_DIR/docs" "reapply: the withdrawn path's empty directories stayed in the copy"
  assert_equals '' "$(wt_status)" "reapply: the copy is dirty after a refresh"
  pass "a second apply refreshes placed files and removes paths the overlay no longer carries"
}

test_withdrawn_overlay_removes_what_it_placed() {
  make_case withdrawn
  mkdir -p "$OVERLAY_DIR"
  printf 'private instructions\n' > "$OVERLAY_DIR/AGENTS.md"
  apply
  expect_code 0 "$APPLY_RC" "withdrawn: the first apply must succeed"$'\n'"$APPLY_ERR"
  printf 'work\n' > "$WT_DIR/kept.txt"

  rm -rf "$OVERLAY_DIR"
  apply
  expect_code 0 "$APPLY_RC" "withdrawn: applying with the overlay gone must succeed"$'\n'"$APPLY_ERR"
  assert_equals '' "$APPLY_OUT$APPLY_ERR" "withdrawn: removing a withdrawn overlay printed output"
  assert_absent "$WT_DIR/AGENTS.md" "withdrawn: a reused copy kept the withdrawn overlay's file"
  assert_present "$WT_DIR/kept.txt" "withdrawn: a file the overlay never placed was removed"
  pass "a withdrawn overlay directory removes the files it placed from a reused copy"
}

test_foreign_untracked_file_is_never_overwritten() {
  make_case foreign
  mkdir -p "$OVERLAY_DIR"
  printf 'overlay notes\n' > "$OVERLAY_DIR/notes.md"
  printf 'private instructions\n' > "$OVERLAY_DIR/AGENTS.md"
  printf 'unlanded work\n' > "$WT_DIR/notes.md"

  apply
  expect_code 0 "$APPLY_RC" "foreign: an occupied path must be skipped, not fail the apply"$'\n'"$APPLY_ERR"
  assert_contains "$APPLY_ERR" 'overlay: skipped notes.md: an untracked file the overlay did not place' \
    "foreign: the skipped path was not named"
  assert_equals 'unlanded work' "$(cat "$WT_DIR/notes.md")" "foreign: unlanded work was overwritten"
  assert_contains "$(wt_status)" '?? notes.md' "foreign: the unlanded file was hidden from git"
  assert_equals 'private instructions' "$(cat "$WT_DIR/AGENTS.md")" \
    "foreign: the free overlay path beside it was not placed"
  pass "an untracked file the overlay did not place is skipped, kept, and left visible to git"
}

test_reincluded_path_is_never_left_visible() {
  make_case reincluded
  printf '!/AGENTS.md\n' > "$WT_DIR/.gitignore"
  git -C "$WT_DIR" add .gitignore
  git -C "$WT_DIR" commit -qm 'keep AGENTS.md visible'
  mkdir -p "$OVERLAY_DIR"
  printf 'private instructions\n' > "$OVERLAY_DIR/AGENTS.md"
  printf 'rule\n' > "$OVERLAY_DIR/rules.md"

  apply
  expect_code 0 "$APPLY_RC" "reincluded: an unhideable path must be skipped, not fail the apply"$'\n'"$APPLY_ERR"
  assert_contains "$APPLY_ERR" 'overlay: skipped AGENTS.md: ' "reincluded: the skipped path was not named"
  assert_absent "$WT_DIR/AGENTS.md" "reincluded: a file git would show as untracked was placed"
  assert_present "$WT_DIR/rules.md" "reincluded: the hideable path beside it was not placed"
  assert_equals '' "$(wt_status)" "reincluded: the copy is dirty"
  pass "a path the repository's own ignore rules re-include is skipped rather than left visible"
}

test_unappliable_overlay_fails() {
  make_case unappliable-git
  mkdir -p "$OVERLAY_DIR/.git/hooks"
  printf '#!/bin/sh\n' > "$OVERLAY_DIR/.git/hooks/pre-commit"
  printf 'private instructions\n' > "$OVERLAY_DIR/AGENTS.md"
  apply
  expect_code 1 "$APPLY_RC" "unappliable: an overlay carrying a .git path must fail"
  assert_contains "$APPLY_ERR" 'error: overlay: ' "unappliable: the .git refusal has no error line"
  assert_absent "$WT_DIR/AGENTS.md" "unappliable: a refused overlay was partly placed"

  make_case unappliable-fifo
  mkdir -p "$OVERLAY_DIR"
  mkfifo "$OVERLAY_DIR/pipe"
  apply
  expect_code 1 "$APPLY_RC" "unappliable: an overlay carrying a named pipe must fail"
  assert_contains "$APPLY_ERR" 'error: overlay: ' "unappliable: the named-pipe refusal has no error line"
  assert_contains "$APPLY_ERR" 'pipe' "unappliable: the named-pipe refusal does not name the entry"

  make_case unappliable-copy
  mkdir -p "$OVERLAY_DIR/sub"
  printf 'private instructions\n' > "$OVERLAY_DIR/sub/AGENTS.md"
  mkdir "$WT_DIR/sub"
  chmod 555 "$WT_DIR/sub"
  apply
  chmod 755 "$WT_DIR/sub"
  if [ "$(id -u)" != 0 ]; then
    expect_code 1 "$APPLY_RC" "unappliable: a copy that cannot be written must fail"
    assert_contains "$APPLY_ERR" 'error: overlay: cannot copy sub/AGENTS.md' \
      "unappliable: the copy failure does not name the path"
  fi
  pass "an overlay that cannot be applied as written exits non-zero with an error line"
}

# teardown_case <name> [pool-slot]: a cleanup sandbox around a no-mistakes ship
# task whose commit is on origin, with an applied overlay in its worker copy.
# With a pool slot, the copy sits where cleanup recognizes a pooled slot and the
# stand-in return resets and cleans it the way a pool return does.
teardown_case() {
  local slot=${2:-} fakebin origin
  CASE_DIR="$TMP_ROOT/$1"
  DATA_DIR="$CASE_DIR/data"
  PROJECT_DIR="$CASE_DIR/demo-project"
  WT_DIR="$CASE_DIR/wt"
  if [ -n "$slot" ]; then
    WT_DIR="$CASE_DIR/pool/$slot/repo"
    mkdir -p "$CASE_DIR/pool/$slot"
    printf '{"worktrees":[{"name":"%s","path":"%s"}]}\n' "$slot" "$WT_DIR" \
      > "$CASE_DIR/pool/treehouse-state.json"
  fi
  OVERLAY_DIR="$DATA_DIR/overlays/demo-project"
  fakebin="$CASE_DIR/fakebin"
  origin="$CASE_DIR/origin.git"
  mkdir -p "$CASE_DIR/state" "$CASE_DIR/config" "$DATA_DIR" "$fakebin"
  touch "$CASE_DIR/state/.last-watcher-beat"

  # Hermetic stand-ins for the steps after the landed-work check.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/treehouse"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/no-mistakes"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  if [ -n "$slot" ]; then
    cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=
  for a in "$@"; do
    case "$a" in
      --*) ;;
      *) wt=$a ;;
    esac
  done
  [ -z "$wt" ] || { git -C "$wt" reset -q --hard && git -C "$wt" clean -fdq; } || exit 1
fi
exit 0
SH
  fi
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/no-mistakes" "$fakebin/gh-axi" "$fakebin/gh"

  fm_git_init_commit "$PROJECT_DIR"
  git clone --quiet --bare "$PROJECT_DIR" "$origin"
  git -C "$PROJECT_DIR" remote add origin "$origin"
  git -C "$PROJECT_DIR" fetch --quiet origin
  git -C "$PROJECT_DIR" remote set-head origin main
  git -C "$PROJECT_DIR" worktree add --quiet -b fm/task-x1 "$WT_DIR" main
  fm_write_meta "$CASE_DIR/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$WT_DIR" \
    "project=$PROJECT_DIR" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawn_gen=overlay-test-task-x1"

  mkdir -p "$OVERLAY_DIR/.agents/skills/demo-skill"
  printf 'private instructions\n' > "$OVERLAY_DIR/AGENTS.md"
  ln -s AGENTS.md "$OVERLAY_DIR/CLAUDE.md"
  printf 'skill body\n' > "$OVERLAY_DIR/.agents/skills/demo-skill/SKILL.md"
  apply
  expect_code 0 "$APPLY_RC" "$1: the overlay must apply"$'\n'"$APPLY_ERR"

  printf 'shipped\n' > "$WT_DIR/feature.txt"
  git -C "$WT_DIR" add feature.txt
  git -C "$WT_DIR" commit -qm 'shippable work'
  git -C "$WT_DIR" push --quiet origin fm/task-x1
  git -C "$PROJECT_DIR" fetch --quiet origin
}

run_teardown() {
  TEARDOWN_RC=0
  FM_HOME="$CASE_DIR" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$CASE_DIR/state" \
  FM_DATA_OVERRIDE="$DATA_DIR" \
  FM_CONFIG_OVERRIDE="$CASE_DIR/config" \
  PATH="$CASE_DIR/fakebin:$PATH" \
    "$TEARDOWN" task-x1 > "$CASE_DIR/teardown.out" 2> "$CASE_DIR/teardown.err" || TEARDOWN_RC=$?
}

test_cleanup_does_not_treat_overlay_files_as_unlanded_work() {
  teardown_case cleanup-landed
  assert_present "$WT_DIR/.agents/skills/demo-skill/SKILL.md" "cleanup-landed: the overlay is not in the copy"

  run_teardown
  expect_code 0 "$TEARDOWN_RC" \
    "cleanup-landed: landed work with an overlay in the copy must clean up"$'\n'"$(cat "$CASE_DIR/teardown.err")"
  assert_no_grep REFUSED "$CASE_DIR/teardown.err" "cleanup-landed: cleanup refused over overlay files"
  assert_absent "$CASE_DIR/state/task-x1.meta" "cleanup-landed: cleanup did not finish"
  pass "cleanup's landed-work check does not treat overlay files as unlanded work"
}

test_cleanup_still_refuses_unlanded_work_beside_an_overlay() {
  teardown_case cleanup-unlanded
  printf 'unsaved\n' > "$WT_DIR/unsaved.txt"

  run_teardown
  expect_code 1 "$TEARDOWN_RC" "cleanup-unlanded: an unlanded file beside an overlay must still refuse"
  assert_grep REFUSED "$CASE_DIR/teardown.err" "cleanup-unlanded: no REFUSED line"
  assert_grep unsaved.txt "$CASE_DIR/teardown.err" "cleanup-unlanded: the refusal does not name the unlanded file"
  assert_no_grep AGENTS.md "$CASE_DIR/teardown.err" "cleanup-unlanded: the refusal lists an overlay file"
  assert_present "$WT_DIR/unsaved.txt" "cleanup-unlanded: the unlanded file was lost"
  pass "cleanup still refuses a genuinely unlanded file beside an overlay"
}

test_returned_pool_slot_with_an_overlay_is_clean_and_reusable() {
  teardown_case cleanup-pool 7

  run_teardown
  expect_code 0 "$TEARDOWN_RC" \
    "cleanup-pool: returning a pooled copy that holds an overlay must not report a lost slot"$'\n'"$(cat "$CASE_DIR/teardown.err")"
  assert_no_grep 'lost this slot' "$CASE_DIR/teardown.err" "cleanup-pool: the overlay made the returned slot read dirty"
  assert_grep 'teardown task-x1 complete' "$CASE_DIR/teardown.out" "cleanup-pool: cleanup did not report a clean return"
  assert_equals '' "$(wt_status)" "cleanup-pool: the returned slot is not clean"

  # The slot goes to its next holder: the overlay changed in the meantime.
  printf 'updated instructions\n' > "$OVERLAY_DIR/AGENTS.md"
  rm -rf "$OVERLAY_DIR/.agents"
  apply
  expect_code 0 "$APPLY_RC" "cleanup-pool: applying into the reused slot must succeed"$'\n'"$APPLY_ERR"
  assert_equals 'updated instructions' "$(cat "$WT_DIR/AGENTS.md")" \
    "cleanup-pool: the reused slot kept the previous overlay content"
  assert_absent "$WT_DIR/.agents" "cleanup-pool: the reused slot kept a path the overlay no longer carries"
  assert_equals '' "$(wt_status)" "cleanup-pool: the reused slot is not clean after the apply"
  pass "a returned pool slot holding an overlay is clean and is refreshed for its next holder"
}

# spawn_case <name> <id>: a home, a project named demo-project with an origin,
# and one clean pooled worktree the fake terminal reports as the pane's cwd.
spawn_case() {
  local id=$2 origin
  CASE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$CASE_DIR/home"
  DATA_DIR="$HOME_DIR/data"
  PROJECT_DIR="$CASE_DIR/demo-project"
  WT_DIR="$CASE_DIR/pool"
  OVERLAY_DIR="$DATA_DIR/overlays/demo-project"
  origin="$CASE_DIR/origin.git"
  FAKEBIN_DIR=$(make_spawn_fakebin "$CASE_DIR/fake")
  mkdir -p "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  touch "$HOME_DIR/state/.last-watcher-beat"

  fm_git_init_commit "$PROJECT_DIR"
  git clone --quiet --bare "$PROJECT_DIR" "$origin"
  git -C "$PROJECT_DIR" remote add origin "file://$origin"
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$WT_DIR" HEAD
}

run_spawn() {
  local id=$1
  shift
  SPAWN_RC=0
  SPAWN_OUT=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" "$@") || SPAWN_RC=$?
}

test_spawn_places_the_overlay_into_the_worker_copy() {
  local id=demo-task-a1
  spawn_case spawn-places "$id"
  mkdir -p "$OVERLAY_DIR"
  printf 'private instructions\n' > "$OVERLAY_DIR/AGENTS.md"
  ln -s AGENTS.md "$OVERLAY_DIR/CLAUDE.md"
  printf 'overlay readme\n' > "$OVERLAY_DIR/README.md"

  run_spawn "$id" --scout
  expect_code 0 "$SPAWN_RC" "spawn-places: a scout spawn with an overlay must launch"$'\n'"$SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "spawned $id" "spawn-places: the spawn did not report success"
  assert_equals 'private instructions' "$(cat "$WT_DIR/AGENTS.md")" \
    "spawn-places: the spawn did not place the overlay into the worker copy"
  [ -L "$WT_DIR/CLAUDE.md" ] || fail "spawn-places: the spawn did not place the overlay's link as a link"
  assert_contains "$SPAWN_OUT" 'overlay: skipped README.md: ' \
    "spawn-places: the spawn output does not name the skipped tracked path"
  assert_equals '# demo-project' "$(cat "$WT_DIR/README.md")" "spawn-places: the spawn overwrote a tracked file"
  assert_no_grep AGENTS.md <(wt_status) "spawn-places: the placed overlay shows in the worker's git status"
  assert_no_grep CLAUDE.md <(wt_status) "spawn-places: the placed link shows in the worker's git status"
  pass "the spawn places the project's overlay into the worker copy and names a skipped tracked path"
}

test_spawn_without_an_overlay_is_unchanged() {
  local id=demo-task-b2
  spawn_case spawn-plain "$id"

  run_spawn "$id" --scout
  expect_code 0 "$SPAWN_RC" "spawn-plain: a scout spawn with no overlay must launch"$'\n'"$SPAWN_OUT"
  assert_not_contains "$SPAWN_OUT" 'overlay:' "spawn-plain: a spawn with no overlay mentions overlays"
  assert_absent "$WT_DIR/AGENTS.md" "spawn-plain: a spawn with no overlay created an instruction file"
  assert_absent "$DATA_DIR/overlays" "spawn-plain: a spawn with no overlay created the overlays directory"
  pass "a spawn for a project with no overlay prints and places nothing new"
}

test_spawn_stops_when_the_overlay_cannot_be_applied() {
  local id=demo-task-c3
  spawn_case spawn-stops "$id"
  mkdir -p "$OVERLAY_DIR"
  mkfifo "$OVERLAY_DIR/pipe"

  run_spawn "$id" --scout
  expect_code 1 "$SPAWN_RC" "spawn-stops: a spawn whose overlay cannot be applied must stop"$'\n'"$SPAWN_OUT"
  assert_contains "$SPAWN_OUT" 'error: overlay: ' "spawn-stops: the spawn did not report the overlay error"
  assert_not_contains "$SPAWN_OUT" "spawned $id" "spawn-stops: the spawn launched a worker without its overlay"
  pass "the spawn stops with the overlay error rather than launching a worker without its instructions"
}

fm_test_run \
  test_apply_mirrors_the_overlay_with_modes \
  test_no_overlay_is_a_silent_noop \
  test_symlink_is_placed_as_a_symlink \
  test_placed_files_are_invisible_to_git \
  test_tracked_path_is_skipped_not_overwritten \
  test_reapply_refreshes_and_removes_withdrawn_paths \
  test_withdrawn_overlay_removes_what_it_placed \
  test_foreign_untracked_file_is_never_overwritten \
  test_reincluded_path_is_never_left_visible \
  test_unappliable_overlay_fails \
  test_cleanup_does_not_treat_overlay_files_as_unlanded_work \
  test_cleanup_still_refuses_unlanded_work_beside_an_overlay \
  test_returned_pool_slot_with_an_overlay_is_clean_and_reusable \
  test_spawn_places_the_overlay_into_the_worker_copy \
  test_spawn_without_an_overlay_is_unchanged \
  test_spawn_stops_when_the_overlay_cannot_be_applied
