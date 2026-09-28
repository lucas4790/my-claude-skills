#!/usr/bin/env bats
# yaml-hooks: the PostToolUse yamllint hook, through the plugin's own self-contained test script
# (no network; its lint cases are skipped when yamllint is not installed).

setup() {
  load helpers
}

@test "yaml-hooks: yamllint-hook.sh passes its test script" {
  TMPDIR="$BATS_TEST_TMPDIR" run sh "$REPO_ROOT/plugins/yaml-hooks/tests/test-hook.sh"
  assert_status 0
}

@test "yaml-hooks: hook and test scripts are shellcheck clean" {
  command -v shellcheck >/dev/null || skip "shellcheck not installed"
  run shellcheck "$REPO_ROOT"/plugins/yaml-hooks/scripts/*.sh "$REPO_ROOT"/plugins/yaml-hooks/tests/*.sh
  assert_status 0
}
