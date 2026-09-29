#!/usr/bin/env bats
# shellcheck disable=SC2016  # $*, $3 and $FAKE_CALLS belong to the generated fake scripts
# Static checks of the installers and scripts, and runs of install.sh and install-copilot.sh against
# fakes: claude, copilot, git, node, npm, curl (no network), pipx on a PATH of only these fakes and
# the system tools the installers need, with HOME, CLAUDE_CONFIG_DIR, COPILOT_HOME, TMPDIR and the
# XDG dirs in temp dirs. install.sh runs with MY_CLAUDE_SKILLS_ATTRIBUTION=keep: the git attribution
# guard it would install has its own tests (tools/attribution-guard/tests).

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

# --- install-copilot.sh against a fake copilot ------------------------------------------------------

# copilot_fixture: $C = a checkout-like copy of install-copilot.sh with a fixture profiles.json and a
# marketplace manifest; fake copilot, curl (serves only the main branch's profiles.json) and git
copilot_fixture() {
  C="$T/checkout"
  mkdir -p "$C/.claude-plugin" "$T/fake" "$T/home" "$T/tmp"
  cp "$REPO_ROOT/install-copilot.sh" "$C/"
  echo '{"name": "my-claude-skills", "plugins": []}' > "$C/.claude-plugin/marketplace.json"
  echo '{"profiles": {"cloud": ["alpha", "beta"], "dotnet": ["gamma"], "claude-only": ["delta"]},
    "copilotDefault": ["cloud"]}' > "$C/profiles.json"
  export HOME="$T/home" COPILOT_HOME="$T/copilot-home" TMPDIR="$T/tmp" FAKE_CALLS="$T/calls.log"
  unset FAKE_COPILOT_INSTALL_FAIL FAKE_COPILOT_MARKETPLACES
  cat > "$T/fake/copilot" <<'EOF'
#!/usr/bin/env bash
echo "copilot $*" >> "$FAKE_CALLS"
case "$*" in
  --version) echo "GitHub Copilot CLI 1.0.80" ;;
  "plugin marketplace list") echo "${FAKE_COPILOT_MARKETPLACES:-}" ;;
  "plugin install "*) [ "${3%@*}" != "${FAKE_COPILOT_INSTALL_FAIL:-}" ] || { echo "install failed" >&2; exit 1; } ;;
esac
EOF
  cat > "$T/fake/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$FAKE_CALLS"
case "$*" in
  *"/main/profiles.json") echo '{"profiles": {"cloud": ["remote-one"]}, "copilotDefault": ["cloud"]}' ;;
  *) exit 22 ;;
esac
EOF
  printf '#!/bin/sh\nexit 0\n' > "$T/fake/git"
  chmod +x "$T/fake/copilot" "$T/fake/curl" "$T/fake/git"
  link_tools "$T/sys" bash env sed dirname jq grep head sort mktemp cat rm mkdir
}

run_copilot() { run env PATH="$T/fake:$T/sys" "$BASH" "$C/install-copilot.sh" "$@"; }
installs() { grep '^copilot plugin install ' "$FAKE_CALLS" | sed 's/^copilot plugin install //' || true; }

@test "install-copilot.sh: the default profile; a missing settings.json is created with includeCoAuthoredBy off" {
  copilot_fixture
  run_copilot
  assert_status 0
  grep -qxF "copilot plugin marketplace add lucas4790/my-claude-skills" "$FAKE_CALLS"
  assert_eq "$(installs)" $'alpha@my-claude-skills\nbeta@my-claude-skills' "installs"
  refute grep -q "^curl" "$FAKE_CALLS"
  jq -e '.includeCoAuthoredBy == false
    and .extraKnownMarketplaces["my-claude-skills"] == {source: {source: "github", repo: "lucas4790/my-claude-skills"}, autoUpdate: true}' \
    "$COPILOT_HOME/settings.json"
  refute_output_contains "warning"
}

@test "install-copilot.sh: --profile picks profiles and skips claude-only with a warning; named plugins are installed as named" {
  copilot_fixture
  run_copilot --profile cloud,dotnet,claude-only
  assert_status 0
  assert_eq "$(installs)" $'alpha@my-claude-skills\nbeta@my-claude-skills\ngamma@my-claude-skills' "installs"
  assert_output_contains "warning: skipping profile claude-only"

  : > "$FAKE_CALLS"
  run_copilot --profile=dotnet
  assert_status 0
  assert_eq "$(installs)" "gamma@my-claude-skills" "installs"

  : > "$FAKE_CALLS"
  run_copilot delta gamma
  assert_status 0
  assert_eq "$(installs)" $'delta@my-claude-skills\ngamma@my-claude-skills' "installs"
}

@test "install-copilot.sh: an unknown profile, or --profile without a value, exits 1 before installing anything" {
  copilot_fixture
  run_copilot --profile cloud,nope
  assert_status 1
  assert_line "error: unknown profile(s): nope (see profiles.json)"

  run_copilot --profile
  assert_status 1
  assert_line "error: --profile needs a value (e.g. --profile cloud,dotnet)"

  refute grep -q "plugin" "$FAKE_CALLS"
  assert_not_exists "$COPILOT_HOME"
}

@test "install-copilot.sh: keeps the other settings and a symlinked settings.json, and turns includeCoAuthoredBy off" {
  copilot_fixture
  mkdir -p "$T/dotfiles" "$COPILOT_HOME"
  echo '{"model": "x", "includeCoAuthoredBy": true,
    "extraKnownMarketplaces": {"my-claude-skills": {"source": {"source": "github", "repo": "someone/fork"}}}}' \
    > "$T/dotfiles/copilot.json"
  ln -s "$T/dotfiles/copilot.json" "$COPILOT_HOME/settings.json"
  FAKE_COPILOT_MARKETPLACES="my-claude-skills" run_copilot
  assert_status 0
  grep -qxF "copilot plugin marketplace update my-claude-skills" "$FAKE_CALLS"
  [ -L "$COPILOT_HOME/settings.json" ]
  jq -e '.model == "x" and .includeCoAuthoredBy == false
    and .extraKnownMarketplaces["my-claude-skills"] == {source: {source: "github", repo: "someone/fork"}, autoUpdate: true}' \
    "$T/dotfiles/copilot.json"
  assert_eq "$(ls -A "$TMPDIR")" "" "temp files left behind"
}

@test "install-copilot.sh: a settings.json that is not plain JSON is left alone, with a warning that names includeCoAuthoredBy" {
  copilot_fixture
  mkdir -p "$COPILOT_HOME"
  printf '{\n  // mine\n  "model": "x",\n}\n' > "$COPILOT_HOME/settings.json"
  cp "$COPILOT_HOME/settings.json" "$T/before.json"
  run_copilot
  assert_status 0
  cmp "$T/before.json" "$COPILOT_HOME/settings.json"
  assert_output_contains "set includeCoAuthoredBy = false and extraKnownMarketplaces.my-claude-skills.autoUpdate = true"
  assert_eq "$(ls -A "$TMPDIR")" "" "temp files left behind"
}

@test "install-copilot.sh: a failed plugin install is named and makes the exit status 1" {
  copilot_fixture
  FAKE_COPILOT_INSTALL_FAIL=beta run_copilot
  assert_status 1
  assert_line "warning: failed plugins: beta"
  assert_eq "$(installs)" $'alpha@my-claude-skills\nbeta@my-claude-skills' "installs"
}

@test "install-copilot.sh piped to bash reads profiles.json from the repo, never from the current directory" {
  copilot_fixture
  # the caller's directory is an old clone
  mkdir -p "$T/old-clone/.claude-plugin"
  echo '{"profiles": {"cloud": ["stale-plugin"]}, "copilotDefault": ["cloud"]}' > "$T/old-clone/profiles.json"
  echo '{"name": "my-claude-skills", "plugins": []}' > "$T/old-clone/.claude-plugin/marketplace.json"
  cd "$T/old-clone"
  run env PATH="$T/fake:$T/sys" "$BASH" -s < "$C/install-copilot.sh"
  assert_status 0
  assert_eq "$(installs)" "remote-one@my-claude-skills" "installs"
  grep -qF "curl -fsSL https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/profiles.json" "$FAKE_CALLS"

  run env PATH="$T/fake:$T/sys" "$BASH" -s -- --help < "$C/install-copilot.sh"
  assert_status 0
  assert_output_contains "Usage: install-copilot.sh"
  refute_output_contains "can't read"
}

# --- install.sh against a fake claude ---------------------------------------------------------------

# install_fixture: fake claude, git, node, npm and curl (serves only the main branch's marketplace
# manifest, with alpha and beta) on $IPATH; CLAUDE_CONFIG_DIR does not exist yet
install_fixture() {
  mkdir -p "$T/ifake" "$T/home" "$T/tmp"
  export HOME="$T/home" CLAUDE_CONFIG_DIR="$T/claude" XDG_DATA_HOME="$T/data" XDG_CACHE_HOME="$T/cache" \
    XDG_CONFIG_HOME="$T/config" TMPDIR="$T/tmp" FAKE_CALLS="$T/calls.log" MY_CLAUDE_SKILLS_ATTRIBUTION=keep
  unset MY_CLAUDE_SKILLS_YES
  cat > "$T/ifake/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude $*" >> "$FAKE_CALLS"
case "$*" in --version) echo "2.1.0 (Claude Code)" ;; esac
EOF
  cat > "$T/ifake/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$FAKE_CALLS"
case "$*" in
  *"/main/.claude-plugin/marketplace.json") echo '{"plugins": [{"name": "alpha"}, {"name": "beta"}]}' ;;
  *) exit 22 ;;
esac
EOF
  printf '#!/bin/sh\necho "git version 2.43.0"\n' > "$T/ifake/git"
  printf '#!/bin/sh\necho v22.0.0\n' > "$T/ifake/node"
  printf '#!/bin/sh\nexit 0\n' > "$T/ifake/npm"
  chmod +x "$T/ifake/"*
  link_tools "$T/isys" bash env dirname mkdir cp mv chmod cat rm mktemp grep sed jq head sort awk uname
  IPATH="$T/ifake:$T/isys"
}

run_install() { run env PATH="$IPATH" "${INSTALL_BASH:-$BASH}" "$REPO_ROOT/install.sh" "$@"; }
hook_cmd() { printf 'bash "%s"' "$XDG_DATA_HOME/my-claude-skills/update-plugins.sh"; }
session_start_count() { jq '[.hooks.SessionStart[]? | select(.hooks[0].command == $c)] | length' --arg c "$(hook_cmd)" "$1"; }

@test "install.sh: installs the manifest's plugins and registers the startup hook once, creating CLAUDE_CONFIG_DIR" {
  install_fixture
  run_install
  assert_status 0
  grep -qxF "claude plugin marketplace add lucas4790/my-claude-skills" "$FAKE_CALLS"
  assert_eq "$(grep '^claude plugin install' "$FAKE_CALLS")" "claude plugin install alpha@my-claude-skills
claude plugin install beta@my-claude-skills" "installs"
  cmp "$REPO_ROOT/scripts/update-plugins.sh" "$XDG_DATA_HOME/my-claude-skills/update-plugins.sh"
  assert_eq "$(session_start_count "$CLAUDE_CONFIG_DIR/settings.json")" "1" "hooks"
  jq -e '.hooks.SessionStart[0] | .matcher == "startup" and .hooks[0].async == true' "$CLAUDE_CONFIG_DIR/settings.json"
  assert_not_exists "$HOME/.claude"

  run_install alpha
  assert_status 0
  assert_line "==> startup auto-update hook already registered"
  assert_eq "$(session_start_count "$CLAUDE_CONFIG_DIR/settings.json")" "1" "hooks after a re-run"
}

@test "install.sh: exits 1 with a message when the plugin list cannot be fetched" {
  install_fixture
  printf '#!/bin/sh\nexit 22\n' > "$T/ifake/curl"
  run_install
  assert_status 1
  assert_output_contains "error: could not read the plugin list from"
  refute grep -q "plugin install" "$FAKE_CALLS"
}

@test "install.sh: registering the hook keeps a symlinked settings.json and its other settings" {
  install_fixture
  mkdir -p "$T/dotfiles" "$CLAUDE_CONFIG_DIR"
  echo '{"model": "x"}' > "$T/dotfiles/settings.json"
  ln -s "$T/dotfiles/settings.json" "$CLAUDE_CONFIG_DIR/settings.json"
  run_install alpha
  assert_status 0
  [ -L "$CLAUDE_CONFIG_DIR/settings.json" ]
  jq -e '.model == "x"' "$T/dotfiles/settings.json"
  assert_eq "$(session_start_count "$T/dotfiles/settings.json")" "1" "hooks"
  assert_eq "$(ls -A "$TMPDIR")" "" "temp files left behind"
}

@test "install.sh: a settings.json that is not plain JSON is left alone, with a warning that the hook is not registered" {
  install_fixture
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf '{\n  // mine\n  "model": "x",\n}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
  cp "$CLAUDE_CONFIG_DIR/settings.json" "$T/before.json"
  run_install alpha
  assert_status 0
  cmp "$T/before.json" "$CLAUDE_CONFIG_DIR/settings.json"
  assert_output_contains "is not plain JSON; startup auto-update hook not registered"
  assert_eq "$(ls -A "$TMPDIR")" "" "temp files left behind"
}

@test "install.sh: yaml-hooks with a yamllint older than 1.30 gets a current one from pipx, else a warning" {
  install_fixture
  mkdir -p "$T/old"
  printf '#!/bin/sh\necho "yamllint 1.26.3"\n' > "$T/old/yamllint"
  cat > "$T/ifake/pipx" <<'EOF'
#!/bin/sh
echo "pipx $*" >> "$FAKE_CALLS"
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\necho "yamllint 1.38.0"\n' > "$HOME/.local/bin/yamllint"
chmod +x "$HOME/.local/bin/yamllint"
EOF
  chmod +x "$T/old/yamllint" "$T/ifake/pipx"
  IPATH="$T/old:$IPATH"
  run_install yaml-hooks
  assert_status 0
  assert_line "==> yamllint 1.26.3 is older than 1.30, which the yaml-hooks hook needs"
  grep -qxF "pipx install --force yamllint" "$FAKE_CALLS"
  refute_output_contains "warning: yamllint"

  # neither pipx nor uv: the old one stays, and the installer says what to do
  rm "$T/ifake/pipx" "$HOME/.local/bin/yamllint"
  run_install yaml-hooks
  assert_status 0
  assert_output_contains "warning: yamllint 1.26.3 ($T/old/yamllint) is older than 1.30: the yaml-hooks hook stays silent with it."

  # a current one is left as it is
  printf '#!/bin/sh\necho "yamllint 1.30.0"\n' > "$T/old/yamllint"
  : > "$FAKE_CALLS"
  run_install yaml-hooks
  assert_status 0
  assert_line "==> yamllint present (1.30.0)"
  refute grep -q "pipx" "$FAKE_CALLS"
}

@test "install.sh and install-copilot.sh run under bash 3.2, macOS's /bin/bash (set BASH32=/path/to/bash-3.2)" {
  [ -n "${BASH32:-}" ] || skip "set BASH32=/path/to/bash-3.2 to run this"
  install_fixture
  INSTALL_BASH="$BASH32" run_install
  assert_status 0
  refute_output_contains "command not found"
  refute_output_contains "unbound variable"
  assert_eq "$(grep -c '^claude plugin install' "$FAKE_CALLS")" "2" "installs"

  copilot_fixture
  run env PATH="$T/fake:$T/sys" "$BASH32" "$C/install-copilot.sh" --profile cloud,claude-only
  assert_status 0
  refute_output_contains "unbound variable"
  assert_eq "$(installs)" $'alpha@my-claude-skills\nbeta@my-claude-skills' "installs"
}
