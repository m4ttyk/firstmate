#!/usr/bin/env bash
# Tests for bin/fm-claude-disabled-plugins.sh, the Claude Code plugins a home
# keeps off in the Claude sessions Firstmate launches
# (docs/claude-worker-plugins.md):
#   - an absent or id-less file prints nothing
#   - listed ids become enabledPlugins entries set to false
#   - a malformed id is refused with its file and line
#   - a claude worker spawn carries the entries in its --settings JSON, and a
#     spawn without the file keeps today's settings
#   - a malformed file stops the spawn
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_git_identity fmtest fmtest@example.invalid

PLUGINS="$ROOT/bin/fm-claude-disabled-plugins.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-disabled-plugins-tests)

# run_tool <mode> <config-dir>: sets OUT, ERR, RC.
run_tool() {
  RC=0
  OUT=$(bash "$PLUGINS" "$1" "$2" 2>"$TMP_ROOT/err") || RC=$?
  ERR=$(cat "$TMP_ROOT/err")
}

test_absent_and_empty_files_print_nothing() {
  local cfg="$TMP_ROOT/absent"
  mkdir -p "$cfg"
  run_tool fragment "$cfg"
  expect_code 0 "$RC" "absent: an absent file must succeed"
  assert_equals '' "$OUT" "absent: an absent file printed settings"
  printf '\n# only a comment\n   \n' > "$cfg/claude-worker-disabled-plugins"
  run_tool fragment "$cfg"
  expect_code 0 "$RC" "empty: a file with no ids must succeed"
  assert_equals '' "$OUT" "empty: a file with no ids printed settings"
  pass "an absent or id-less file prints nothing"
}

test_listed_ids_become_disabled_entries() {
  local cfg="$TMP_ROOT/listed"
  mkdir -p "$cfg"
  printf '# personal plugins\ndemo-tools@demo-market\n\n  other.plugin_2@demo-market  \n' \
    > "$cfg/claude-worker-disabled-plugins"
  run_tool fragment "$cfg"
  expect_code 0 "$RC" "listed: fragment must succeed"$'\n'"$ERR"
  assert_equals ',"enabledPlugins":{"demo-tools@demo-market":false,"other.plugin_2@demo-market":false}' "$OUT" \
    "listed: fragment is not the expected JSON member"
  pass "listed ids become enabledPlugins entries set to false"
}

test_malformed_id_is_refused() {
  local cfg="$TMP_ROOT/malformed"
  mkdir -p "$cfg"
  printf 'demo-tools@demo-market\nno-marketplace\n' > "$cfg/claude-worker-disabled-plugins"
  run_tool fragment "$cfg"
  expect_code 1 "$RC" "malformed: a malformed id must be refused"
  assert_equals '' "$OUT" "malformed: a refused file printed settings"
  assert_contains "$ERR" 'line 2' "malformed: the error does not name the line"
  assert_contains "$ERR" 'no-marketplace' "malformed: the error does not name the id"
  pass "a malformed id is refused with its line"
}

# spawn_claude <case> <id>: a claude scout spawn whose launch is logged.
# Sets HOME_DIR, SPAWN_RC, SPAWN_OUT, and SETTINGS (the --settings value).
spawn_claude() {
  local case_dir="$TMP_ROOT/$1" id=$2 project wt origin fakebin log
  HOME_DIR="$case_dir/home"
  project="$case_dir/demo-project"
  wt="$case_dir/pool"
  origin="$case_dir/origin.git"
  log="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  [ -z "${PLUGIN_LIST:-}" ] || printf '%s\n' "$PLUGIN_LIST" > "$HOME_DIR/config/claude-worker-disabled-plugins"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  touch "$HOME_DIR/state/.last-watcher-beat"
  fm_git_init_commit "$project"
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" worktree add --quiet --detach "$wt" HEAD
  SPAWN_RC=0
  SPAWN_OUT=$(FM_FAKE_LAUNCH_LOG="$log" fm_test_run_spawn "$HOME_DIR" "$wt" "$fakebin" "$id" "$project" --scout) || SPAWN_RC=$?
  SETTINGS=$(fm_test_launch_unframe "$(cat "$log" 2>/dev/null)" | grep -o -- "--settings '[^']*'" | head -n 1 | sed "s/^--settings '//; s/'\$//")
}

test_spawn_carries_disabled_plugins() {
  PLUGIN_LIST='demo-tools@demo-market'
  spawn_claude spawn-listed demo-task-a1
  PLUGIN_LIST=
  expect_code 0 "$SPAWN_RC" "spawn-listed: a claude spawn must launch"$'\n'"$SPAWN_OUT"
  printf '%s' "$SETTINGS" | jq -e '.feedbackDrafts == "off" and .enabledPlugins == {"demo-tools@demo-market":false}' >/dev/null \
    || fail "spawn-listed: launch settings do not disable the plugin: $SETTINGS"
  pass "a claude worker spawn disables the listed plugins in its --settings"
}

test_spawn_without_file_is_unchanged() {
  PLUGIN_LIST=
  spawn_claude spawn-plain demo-task-b2
  expect_code 0 "$SPAWN_RC" "spawn-plain: a claude spawn must launch"$'\n'"$SPAWN_OUT"
  assert_equals '{"feedbackDrafts":"off","attribution":{"commit":"","pr":"","sessionUrl":false}}' "$SETTINGS" \
    "spawn-plain: launch settings changed without the file"
  pass "a claude worker spawn without the file keeps today's settings"
}

test_spawn_stops_on_malformed_file() {
  PLUGIN_LIST='not a plugin id'
  spawn_claude spawn-bad demo-task-c3
  PLUGIN_LIST=
  [ "$SPAWN_RC" -ne 0 ] || fail "spawn-bad: a malformed file must stop the spawn"$'\n'"$SPAWN_OUT"
  assert_contains "$SPAWN_OUT" 'claude-worker-disabled-plugins line 1' "spawn-bad: the spawn did not name the bad line"
  assert_not_contains "$SPAWN_OUT" 'spawned demo-task-c3' "spawn-bad: the spawn launched anyway"
  pass "a malformed file stops the spawn"
}

fm_test_run \
  test_absent_and_empty_files_print_nothing \
  test_listed_ids_become_disabled_entries \
  test_malformed_id_is_refused \
  test_spawn_carries_disabled_plugins \
  test_spawn_without_file_is_unchanged \
  test_spawn_stops_on_malformed_file
