#!/usr/bin/env bats
# Static checks of the installers and scripts, plus the one installer mode that installs nothing
# (install-copilot.sh --help / a bad option). The installers are never run otherwise: they install
# software and change the user's configuration.

setup() {
  load helpers
  T="$BATS_TEST_TMPDIR"
}

# each file separately: `bash -n a.sh b.sh` only checks a.sh (b.sh becomes its $1)
bash_n_each() {
  local f bad=0
  for f in "$@"; do
    bash -n "$REPO_ROOT/$f" || { echo "syntax error: $f"; bad=1; }
  done
  return "$bad"
}

need_shellcheck() {
  command -v shellcheck >/dev/null || skip "shellcheck not installed"
}

@test "static: bash -n on install.sh and install-copilot.sh" {
  bash_n_each install.sh install-copilot.sh
}

@test "static: bash -n on scripts/*.sh and the bats helpers" {
  local files=() f
  for f in "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/tests/bats/*.bash; do files+=("${f#"$REPO_ROOT"/}"); done
  bash_n_each "${files[@]}"
}

@test "static: shellcheck install-copilot.sh (all severities)" {
  need_shellcheck
  run shellcheck "$REPO_ROOT/install-copilot.sh"
  assert_status 0
}

@test "static: shellcheck install.sh (all severities except SC2016: PowerShell \$ inside single quotes is intended)" {
  need_shellcheck
  run shellcheck --exclude=SC2016 "$REPO_ROOT/install.sh"
  assert_status 0
}

@test "static: shellcheck scripts/*.sh" {
  need_shellcheck
  run shellcheck "$REPO_ROOT"/scripts/*.sh
  assert_status 0
}

@test "static: shellcheck the bats suites and their helpers" {
  need_shellcheck
  run shellcheck "$REPO_ROOT"/tests/bats/*.bats "$REPO_ROOT"/tests/bats/*.bash
  assert_status 0
}

@test "install-copilot.sh --help prints the usage and installs nothing" {
  link_tools "$T/sys" bash sed dirname
  HOME="$T/home" run env PATH="$T/sys" "$BASH" "$REPO_ROOT/install-copilot.sh" --help
  assert_status 0
  assert_output_contains "Usage: install-copilot.sh"
  assert_output_contains "--profile cloud,dotnet"
  assert_not_exists "$T/home"
}

@test "install-copilot.sh rejects an unknown option before installing anything" {
  link_tools "$T/sys" bash sed dirname
  HOME="$T/home" run env PATH="$T/sys" "$BASH" "$REPO_ROOT/install-copilot.sh" --bogus
  assert_status 1
  assert_line "error: unknown option --bogus"
  assert_not_exists "$T/home"
}

@test "static: PowerShell installers and scripts parse (pwsh, or \$PWSH)" {
  local pwsh="${PWSH:-}"
  [ -n "$pwsh" ] || pwsh=$(command -v pwsh) || skip "pwsh not installed (set PWSH=/path/to/pwsh to run this)"
  # -File, not -Command: -Command would join the file arguments into the script text
  cat > "$T/parse.ps1" <<'PS1'
$bad = 0
foreach ($f in $args) {
  $tokens = $null; $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors)
  foreach ($e in $errors) { "{0}:{1}: {2}" -f $f, $e.Extent.StartLineNumber, $e.Message; $bad = 1 }
}
exit $bad
PS1
  run "$pwsh" -NoLogo -NoProfile -NonInteractive -File "$T/parse.ps1" \
    "$REPO_ROOT/install.ps1" "$REPO_ROOT/install-copilot.ps1" "$REPO_ROOT"/scripts/*.ps1
  assert_status 0
}
