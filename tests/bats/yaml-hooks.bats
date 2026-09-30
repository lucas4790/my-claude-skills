#!/usr/bin/env bats
# yaml-hooks: the PostToolUse yamllint hook, through the plugin's own self-contained test script
# (no network; its lint cases are skipped when yamllint is not installed, and so is this test).

setup() {
  load helpers
}

@test "yaml-hooks: yamllint-hook.sh passes its test script" {
  TMPDIR="$BATS_TEST_TMPDIR" run sh "$REPO_ROOT/plugins/yaml-hooks/tests/test-hook.sh"
  assert_status 0
  # without yamllint the script passes with a "skip - lint cases ..." line: skipped here, not a plain ok
  local skipped
  skipped=$(grep -m 1 '^skip - ' <<<"$output" || true)
  [ -z "$skipped" ] || tool_missing "test-hook.sh skipped: ${skipped#skip - }"
}

@test "yaml-hooks: hook and test scripts are shellcheck clean" {
  need_tool shellcheck
  run shellcheck "$REPO_ROOT"/plugins/yaml-hooks/scripts/*.sh "$REPO_ROOT"/plugins/yaml-hooks/tests/*.sh
  assert_status 0
}

@test "yaml-hooks: the hook passes its test script under bash as sh (macOS and Git Bash sh)" {
  # bash started as sh runs in POSIX mode, which changes what command -v returns
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  ln -s "$(command -v bash)" "$BATS_TEST_TMPDIR/bin/sh"
  TMPDIR="$BATS_TEST_TMPDIR" HOOK_SHELL="$BATS_TEST_TMPDIR/bin/sh" run sh "$REPO_ROOT/plugins/yaml-hooks/tests/test-hook.sh"
  assert_status 0
  local skipped
  skipped=$(grep -m 1 '^skip - ' <<<"$output" || true)
  [ -z "$skipped" ] || tool_missing "test-hook.sh skipped: ${skipped#skip - }"
}
