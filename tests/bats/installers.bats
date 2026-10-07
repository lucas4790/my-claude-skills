#!/usr/bin/env bats
# shellcheck disable=SC2016  # $*, $3 and $FAKE_CALLS belong to the generated fake scripts
# Static checks of the installers and scripts, and runs of install.sh and install-copilot.sh against
# fakes: claude, copilot, git, node, npm, curl (no network), pipx, pwsh on a PATH of only these fakes and
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

# need_pwsh: $PWSH_BIN = $PWSH, else pwsh on PATH
need_pwsh() {
  PWSH_BIN="${PWSH:-}"
  [ -n "$PWSH_BIN" ] || PWSH_BIN=$(command -v pwsh) || tool_missing "pwsh not installed (set PWSH=/path/to/pwsh to run this)"
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
  need_tool shellcheck
  run shellcheck "$REPO_ROOT/install-copilot.sh"
  assert_status 0
}

@test "static: shellcheck install.sh (all severities except SC2016: PowerShell \$ inside single quotes is intended)" {
  need_tool shellcheck
  run shellcheck --exclude=SC2016 "$REPO_ROOT/install.sh"
  assert_status 0
}

@test "static: shellcheck scripts/*.sh" {
  need_tool shellcheck
  run shellcheck "$REPO_ROOT"/scripts/*.sh
  assert_status 0
}

@test "static: shellcheck the bats suites and their helpers" {
  need_tool shellcheck
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
  need_pwsh
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
  run "$PWSH_BIN" -NoLogo -NoProfile -NonInteractive -File "$T/parse.ps1" \
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

# install_fixture: fake claude (installs all but $FAKE_CLAUDE_INSTALL_FAIL and lists them), git, node, npm
# and curl (serves only the main branch's marketplace manifest, with alpha and beta, and its profiles.json) on $IPATH;
# CLAUDE_CONFIG_DIR does not exist yet
install_fixture() {
  mkdir -p "$T/ifake" "$T/home" "$T/tmp"
  export HOME="$T/home" CLAUDE_CONFIG_DIR="$T/claude" XDG_DATA_HOME="$T/data" XDG_CACHE_HOME="$T/cache" \
    XDG_CONFIG_HOME="$T/config" TMPDIR="$T/tmp" FAKE_CALLS="$T/calls.log" FAKE_INSTALLED="$T/installed" \
    MY_CLAUDE_SKILLS_ATTRIBUTION=keep
  unset MY_CLAUDE_SKILLS_YES FAKE_CLAUDE_INSTALL_FAIL
  KNOWN="$CLAUDE_CONFIG_DIR/plugins/my-claude-skills-known-plugins"
  cat > "$T/ifake/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude $*" >> "$FAKE_CALLS"
case "$*" in
  --version) echo "2.1.0 (Claude Code)" ;;
  "plugin install "*) [ "${3%@*}" != "${FAKE_CLAUDE_INSTALL_FAIL:-}" ] || exit 1; echo "$3" >> "$FAKE_INSTALLED" ;;
  "plugin list --json") if [ -f "$FAKE_INSTALLED" ]; then jq -R '{id: .}' "$FAKE_INSTALLED" | jq -s .; else echo '[]'; fi ;;
esac
EOF
  cat > "$T/ifake/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$FAKE_CALLS"
case "$*" in
  *"/main/.claude-plugin/marketplace.json") echo '{"plugins": [{"name": "alpha"}, {"name": "beta"}]}' ;;
  *"/main/profiles.json") echo '{"profiles": {"core": ["remote-one"], "claude-only": ["remote-two"]}}' ;;
  *) exit 22 ;;
esac
EOF
  printf '#!/bin/sh\necho "git version 2.43.0"\n' > "$T/ifake/git"
  printf '#!/bin/sh\necho v22.0.0\n' > "$T/ifake/node"
  printf '#!/bin/sh\nexit 0\n' > "$T/ifake/npm"
  chmod +x "$T/ifake/"*
  # (date, touch and cmp: for update-plugins.sh)
  link_tools "$T/isys" bash env dirname mkdir cp mv chmod cat rm mktemp grep sed jq head sort awk uname date touch cmp
  IPATH="$T/ifake:$T/isys"
}

# offers NAME...: the marketplace clone that `claude plugin marketplace add` made lists NAME...
offers() {
  local clone="$CLAUDE_CONFIG_DIR/plugins/marketplaces/my-claude-skills"
  mkdir -p "$clone/.claude-plugin"
  printf '%s\n' "$@" | jq -R '{name: .}' | jq -s '{name: "my-claude-skills", plugins: .}' > "$clone/.claude-plugin/marketplace.json"
}

run_install() { run env PATH="$IPATH" "${INSTALL_BASH:-$BASH}" "$REPO_ROOT/install.sh" "$@"; }
hook_cmd() { printf 'bash "%s"' "$XDG_DATA_HOME/my-claude-skills/update-plugins.sh"; }
session_start_count() { jq '[.hooks.SessionStart[]? | select(.hooks[0].command == $c)] | length' --arg c "$(hook_cmd)" "$1"; }

# profile_fixture: $C = a checkout-like copy of install.sh with the updater, a profiles.json and a marketplace
# manifest, and a marketplace clone that offers alpha to epsilon
profile_fixture() {
  install_fixture
  C="$T/checkout"
  mkdir -p "$C/.claude-plugin" "$C/scripts"
  cp "$REPO_ROOT/install.sh" "$C/"
  cp "$REPO_ROOT/scripts/update-plugins.sh" "$C/scripts/"
  echo '{"name": "my-claude-skills", "plugins": []}' > "$C/.claude-plugin/marketplace.json"
  echo '{"profiles": {"core": ["alpha", "beta"], "extra": ["gamma"], "claude-only": ["delta"]}, "unrelated": 1}' > "$C/profiles.json"
  offers alpha beta gamma delta epsilon
  PROFILES="$CLAUDE_CONFIG_DIR/plugins/my-claude-skills-profiles"
  PKNOWN="$CLAUDE_CONFIG_DIR/plugins/my-claude-skills-profile-plugins"
}
run_profiled() { run env PATH="$IPATH" "${INSTALL_BASH:-$BASH}" "$C/install.sh" "$@"; }
# run_piped ARG...: $C/install.sh piped into bash -s, as curl | bash does
run_piped() { run env PATH="$IPATH" "$BASH" -s -- "$@" < "$C/install.sh"; }
# run_updater: the updater copy the installer left in XDG_DATA_HOME, forced
run_updater() { run env PATH="$IPATH" bash "$XDG_DATA_HOME/my-claude-skills/update-plugins.sh" --force; }
# run_profiles_json SRC: install.sh's profiles_json (extracted into $T/profiles_json.sh) with SRC as the script
# file (empty under curl | bash) and HERE = the checkout $C
run_profiles_json() { run env PATH="$IPATH" REPO=lucas4790/my-claude-skills HERE="$C" SRC="$1" "$BASH" -c '. "$1"; profiles_json' _ "$T/profiles_json.sh"; }
claude_installs() { grep '^claude plugin install ' "$FAKE_CALLS" | sed 's/^claude plugin install //; s/@my-claude-skills$//' | tr '\n' ' ' || true; }


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

@test "install.sh: records the plugins for the updater without the failed ones, so the next update retries those" {
  install_fixture
  offers alpha beta gamma
  FAKE_CLAUDE_INSTALL_FAIL=beta run_install alpha beta
  assert_status 1
  assert_line "warning: failed plugins: beta"
  # gamma was left out: known, so it stays out; beta failed: not known, so the updater installs it
  assert_file_content "$KNOWN" $'alpha\ngamma\n'
  : > "$FAKE_CALLS"
  run env PATH="$IPATH" bash "$XDG_DATA_HOME/my-claude-skills/update-plugins.sh" --force
  assert_status 0
  assert_eq "$(grep '^claude plugin install' "$FAKE_CALLS")" "claude plugin install beta@my-claude-skills" "the updater's installs"
  assert_file_content "$KNOWN" $'alpha\nbeta\ngamma\n'

  # a re-run adds what it installed and takes a failed plugin out; delta, new upstream, stays new
  printf 'alpha\nbeta\n' > "$KNOWN"
  offers alpha beta gamma delta
  FAKE_CLAUDE_INSTALL_FAIL=beta run_install beta gamma
  assert_status 1
  assert_file_content "$KNOWN" $'alpha\ngamma\n'
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
  assert_output_contains "warning: yamllint 1.26.3 ($T/old/yamllint) is older than 1.30: the yaml-hooks hook does not lint with it (it only reports that it is inactive)."

  # a current one is left as it is
  printf '#!/bin/sh\necho "yamllint 1.30.0"\n' > "$T/old/yamllint"
  : > "$FAKE_CALLS"
  run_install yaml-hooks
  assert_status 0
  assert_line "==> yamllint present (1.30.0)"
  refute grep -q "pipx" "$FAKE_CALLS"
}

@test "install.sh: powershell installs Pester 6 unless 6.0.0 or newer is present, and PSScriptAnalyzer when missing" {
  install_fixture
  export FAKE_MODULES="$T/modules.ps1"
  # a fake pwsh: answers the version query and records the module command
  cat > "$T/ifake/pwsh" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = -Command ]; then
    case "$2" in *PSVersionTable*) echo 7.5.0 ;; *) printf '%s\n' "$2" > "$FAKE_MODULES" ;; esac
  fi
  shift
done
EOF
  chmod +x "$T/ifake/pwsh"
  run_install powershell
  assert_status 0
  assert_line "==> pwsh present (7.5.0)"
  assert_exists "$FAKE_MODULES"
  # run the recorded command with stubs in a real pwsh: which modules would it install?
  need_pwsh
  cat > "$T/modules-driver.ps1" <<'PS1'
$have = @{}
if ($args[0] -ne 'none') { $have.Pester = [version] $args[0] }
if ($args[1] -ne 'none') { $have.PSScriptAnalyzer = [version] $args[1] }
function Get-Module { param([switch] $ListAvailable, [string] $Name) if ($have[$Name]) { [pscustomobject]@{ Name = $Name; Version = $have[$Name] } } }
function Install-Module { param([string] $Name, [version] $MinimumVersion, [string] $Scope, [switch] $Force, [switch] $SkipPublisherCheck) "install $Name min=$MinimumVersion" }
Invoke-Expression (Get-Content -Raw $args[2])
PS1
  run "$PWSH_BIN" -NoLogo -NoProfile -NonInteractive -File "$T/modules-driver.ps1" 5.7.1 1.21.0 "$FAKE_MODULES"
  assert_status 0
  assert_eq "$output" "install Pester min=6.0.0" "with Pester 5.7.1"
  run "$PWSH_BIN" -NoLogo -NoProfile -NonInteractive -File "$T/modules-driver.ps1" 6.1.0 1.21.0 "$FAKE_MODULES"
  assert_status 0
  assert_eq "$output" "" "with Pester 6.1.0"
  run "$PWSH_BIN" -NoLogo -NoProfile -NonInteractive -File "$T/modules-driver.ps1" none none "$FAKE_MODULES"
  assert_status 0
  assert_eq "$output" $'install PSScriptAnalyzer min=\ninstall Pester min=6.0.0' "with neither"
}

@test "install.sh --profile: installs the plugins of the profiles and the named ones, records both, and the updater then keeps to them" {
  profile_fixture
  run_profiled --profile core delta
  assert_status 0
  assert_eq "$(claude_installs)" "alpha beta delta " "installs"
  assert_line "==> profiles core: 2 plugin(s)"
  assert_file_content "$PROFILES" $'core\n'
  assert_file_content "$PKNOWN" $'alpha\nbeta\n'
  assert_file_content "$KNOWN" $'alpha\nbeta\ngamma\ndelta\nepsilon\n'
  refute grep -q "profiles.json" "$FAKE_CALLS"   # a checkout reads its own

  # epsilon joins core, zeta joins extra, and the marketplace gets both
  offers alpha beta gamma delta epsilon zeta
  echo '{"profiles": {"core": ["alpha", "beta", "epsilon"], "extra": ["gamma", "zeta"], "claude-only": ["delta"]}}' \
    > "$CLAUDE_CONFIG_DIR/plugins/marketplaces/my-claude-skills/profiles.json"
  : > "$FAKE_CALLS"
  run_updater
  assert_status 0
  assert_eq "$(claude_installs)" "epsilon " "the updater's installs"
  grep -qxF "available (outside profiles core): zeta" "$XDG_CACHE_HOME/my-claude-skills/update.log"
}

@test "install.sh --profile: an unknown profile is an error before anything is installed" {
  profile_fixture
  run_profiled --profile core,nope,also-not
  assert_status 1
  assert_line "error: unknown profile(s): nope also-not (available: core, extra, claude-only)"
  refute grep -q "^claude " "$FAKE_CALLS"
  assert_not_exists "$CLAUDE_CONFIG_DIR/plugins/my-claude-skills-profiles"
  assert_not_exists "$XDG_DATA_HOME"
}

@test "install.sh --profile: names are split at commas, trimmed and joined over repeats; claude-only is a profile like the others" {
  profile_fixture
  run_profiled --profile " core, extra,core" --profile=claude-only
  assert_status 0
  assert_eq "$(claude_installs)" "alpha beta gamma delta " "installs"
  assert_file_content "$PROFILES" $'core\nextra\nclaude-only\n'

  run_profiled --profile
  assert_status 1
  assert_line "error: --profile needs a value (e.g. --profile cloud,dotnet)"
  run_profiled --profile ","
  assert_status 1
  assert_line "error: --profile needs a value (e.g. --profile cloud,dotnet)"

  # an empty value is the same error, never "no --profile" (that would install everything and drop the record)
  : > "$FAKE_CALLS"
  run_profiled --profile ""
  assert_status 1
  assert_line "error: --profile needs a value (e.g. --profile cloud,dotnet)"
  run_profiled --profile=
  assert_status 1
  assert_line "error: --profile needs a value (e.g. --profile cloud,dotnet)"
  run_profiled --profile "" alpha
  assert_status 1
  assert_line "error: --profile needs a value (e.g. --profile cloud,dotnet)"
  refute grep -q . "$FAKE_CALLS"   # nothing ran, nothing was fetched
  assert_file_content "$PROFILES" $'core\nextra\nclaude-only\n'

  run_profiled --bogus
  assert_status 1
  assert_line "error: unknown option --bogus"
  run_profiled --profile 'we"ird'   # a quote is part of the (unknown) name, not a parse error
  assert_status 1
  assert_line 'error: unknown profile(s): we"ird (available: core, extra, claude-only)'
}

@test "install.sh: plugin names alone keep the recorded profiles; no arguments install everything and drop them" {
  profile_fixture
  run_profiled --profile extra
  assert_file_content "$PROFILES" $'extra\n'
  run_profiled alpha
  assert_status 0
  assert_file_content "$PROFILES" $'extra\n'
  assert_file_content "$PKNOWN" $'gamma\n'

  : > "$FAKE_CALLS"
  run_install
  assert_status 0
  assert_eq "$(claude_installs)" "alpha beta " "installs"
  assert_not_exists "$PROFILES"
  assert_not_exists "$PKNOWN"
  refute grep -q "profiles.json" "$FAKE_CALLS"   # no argument never fetches it
}

@test "install.sh --profile: a failed plugin stays out of the snapshot of the profile, so the updater retries it" {
  profile_fixture
  FAKE_CLAUDE_INSTALL_FAIL=beta run_profiled --profile core
  assert_status 1
  assert_line "warning: failed plugins: beta"
  refute_output_contains "does not retry"   # a failed plugin of the profile is retried
  assert_file_content "$PROFILES" $'core\n'
  assert_file_content "$PKNOWN" $'alpha\n'
}

@test "install.sh --profile: when every plugin of the profile failed, the snapshot stays empty and the updater installs them" {
  profile_fixture
  FAKE_CLAUDE_INSTALL_FAIL=gamma run_profiled --profile extra   # offline, not logged in: all of a profile fail together
  assert_status 1
  assert_file_content "$PROFILES" $'extra\n'
  assert_file_content "$PKNOWN" ""
  assert_file_content "$KNOWN" $'alpha\nbeta\ndelta\nepsilon\n'

  cp "$C/profiles.json" "$CLAUDE_CONFIG_DIR/plugins/marketplaces/my-claude-skills/profiles.json"
  : > "$FAKE_CALLS"
  run_updater
  assert_status 0
  assert_eq "$(claude_installs)" "gamma " "the updater's installs"
  grep -qxF "new plugin: gamma" "$XDG_CACHE_HOME/my-claude-skills/update.log"
  refute grep -q "no profile snapshot yet" "$XDG_CACHE_HOME/my-claude-skills/update.log"
  assert_file_content "$PKNOWN" $'gamma\n'
  assert_file_content "$KNOWN" $'alpha\nbeta\ngamma\ndelta\nepsilon\n'
}

@test "install.sh --profile: a failed plugin named outside the profiles is not retried, and the installer says so" {
  profile_fixture
  FAKE_CLAUDE_INSTALL_FAIL="delta" run_profiled --profile core delta
  assert_status 1
  assert_line "warning: failed plugins: delta"
  assert_line "warning: the updater does not retry delta (outside the profiles); re-run this installer to retry"
  assert_file_content "$PKNOWN" $'alpha\nbeta\n'

  cp "$C/profiles.json" "$CLAUDE_CONFIG_DIR/plugins/marketplaces/my-claude-skills/profiles.json"
  : > "$FAKE_CALLS"
  run_updater
  assert_status 0
  assert_eq "$(claude_installs)" "" "the updater's installs"
  grep -qxF "available (outside profiles core): delta" "$XDG_CACHE_HOME/my-claude-skills/update.log"

  # without profiles the updater retries the failure, so the installer does not say otherwise
  FAKE_CLAUDE_INSTALL_FAIL="delta" run_profiled delta
  assert_line "warning: failed plugins: delta"
  refute_output_contains "does not retry"
}

@test "install.sh --profile: a plugin name that is also a profile name gets a warning (a forgotten comma)" {
  profile_fixture
  run_profiled --profile core extra
  assert_status 0
  assert_line "warning: extra is also a profile name; it is installed as the plugin of that name. For the profile too: --profile core,extra"
  assert_eq "$(claude_installs)" "alpha beta extra " "installs"
  assert_file_content "$PROFILES" $'core\n'

  run_profiled extra   # without --profile it is only the plugin
  assert_status 0
  refute_output_contains "also a profile name"
}

@test "install.sh --profile: a record that cannot be written is a warning that names the consequence" {
  profile_fixture
  printf '#!/bin/sh\nexit 1\n' > "$T/ifake/mv"   # every rename fails, as on a read-only disk
  chmod +x "$T/ifake/mv"
  run_profiled --profile core
  assert_status 0
  assert_output_contains "warning: could not write $PROFILES; the updater keeps following the earlier record, or installs every new plugin, until you re-run with --profile"
  assert_not_exists "$PROFILES"
  assert_eq "$(ls "$CLAUDE_CONFIG_DIR/plugins")" "marketplaces" "files left behind"
}

@test "install.sh piped to bash reads profiles.json from the repo, never from the current directory" {
  profile_fixture
  mkdir -p "$T/old-clone/.claude-plugin"
  echo '{"profiles": {"core": ["stale-plugin"]}}' > "$T/old-clone/profiles.json"
  echo '{"name": "my-claude-skills", "plugins": []}' > "$T/old-clone/.claude-plugin/marketplace.json"
  cd "$T/old-clone"
  run_piped --profile core
  assert_status 0
  assert_eq "$(claude_installs)" "remote-one " "installs"
  grep -qF "curl -fsSL https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/profiles.json" "$FAKE_CALLS"

  run_piped --help
  assert_status 0
  assert_output_contains "Usage: install.sh [--profile NAME[,NAME...]] [plugin ...]"
}

@test "install.sh: profiles_json reads the directory of the script only for a script file, not under curl | bash (where it is /)" {
  profile_fixture
  sed -n '/^profiles_json() {/,/^}/p' "$REPO_ROOT/install.sh" > "$T/profiles_json.sh"
  run_profiles_json ""
  assert_status 0
  assert_output_contains "remote-one"   # main's profiles.json, though HERE holds a checkout
  run_profiles_json "$C/install.sh"
  assert_status 0
  assert_output_contains '"extra": ["gamma"]'   # the checkout's own
}

@test "install.sh --help prints the usage and installs nothing" {
  link_tools "$T/sys" bash sed dirname
  HOME="$T/home" run env PATH="$T/sys" "$BASH" "$REPO_ROOT/install.sh" --help
  assert_status 0
  assert_output_contains "install.sh --profile cloud,dotnet"
  assert_not_exists "$T/home"
}

@test "install.sh --profile resolves the same plugins as install-copilot.sh --profile" {
  profile_fixture
  run_profiled --profile core,extra
  assert_status 0
  local ours; ours=$(claude_installs)
  copilot_fixture
  echo '{"profiles": {"core": ["alpha", "beta"], "extra": ["gamma"], "claude-only": ["delta"]}, "copilotDefault": ["core"]}' > "$C/profiles.json"
  run_copilot --profile core,extra
  assert_status 0
  assert_eq "$ours" "$(installs | sed 's/@my-claude-skills//' | tr '\n' ' ')" "install order"
}

@test "install.sh --profile runs under bash 3.2, macOS's /bin/bash (set BASH32=/path/to/bash-3.2)" {
  [ -n "${BASH32:-}" ] || skip "set BASH32=/path/to/bash-3.2 to run this"
  profile_fixture
  INSTALL_BASH="$BASH32" run_profiled --profile core,extra delta
  assert_status 0
  refute_output_contains "command not found"
  refute_output_contains "unbound variable"
  assert_eq "$(claude_installs)" "alpha beta gamma delta " "installs"
  assert_file_content "$PROFILES" $'core\nextra\n'
  assert_file_content "$PKNOWN" $'alpha\nbeta\ngamma\n'
  INSTALL_BASH="$BASH32" run_profiled --profile extra
  assert_status 0
  INSTALL_BASH="$BASH32" run_profiled
  assert_status 0
  refute_output_contains "unbound variable"
}

@test "install.sh and install-copilot.sh run under bash 3.2, macOS's /bin/bash (set BASH32=/path/to/bash-3.2)" {
  [ -n "${BASH32:-}" ] || skip "set BASH32=/path/to/bash-3.2 to run this"
  install_fixture
  offers alpha beta
  INSTALL_BASH="$BASH32" run_install
  assert_status 0
  refute_output_contains "command not found"
  refute_output_contains "unbound variable"
  assert_eq "$(grep -c '^claude plugin install' "$FAKE_CALLS")" "2" "installs"
  assert_file_content "$KNOWN" $'alpha\nbeta\n'

  copilot_fixture
  run env PATH="$T/fake:$T/sys" "$BASH32" "$C/install-copilot.sh" --profile cloud,claude-only
  assert_status 0
  refute_output_contains "unbound variable"
  assert_eq "$(installs)" $'alpha@my-claude-skills\nbeta@my-claude-skills' "installs"
}
