#!/usr/bin/env bats
# shellcheck disable=SC2016  # $* and $FAKE_* in single quotes belong to the generated fakes and PowerShell
# The Windows scripts under pwsh: a Windows PowerShell 5.1 compatibility check (PSScriptAnalyzer) of
# install.ps1, install-copilot.ps1 and scripts/update-plugins.ps1, and behaviour tests of the installers'
# control flow and settings edits.
#
# The behaviour tests run the real installers with fake claude/copilot/git/node/winget/npm.cmd/uv/yamllint
# on PATH and HOME, USERPROFILE, LOCALAPPDATA, COPILOT_HOME, XDG_CONFIG_HOME and TMPDIR in the test's temp
# dir (env -i: nothing else from the caller's environment). A driver stubs what Linux lacks
# (Get-AppxPackage) or would reach the network: Invoke-WebRequest and Invoke-RestMethod serve this
# repository's raw.githubusercontent.com URLs from the checkout and throw for anything else.
#
# pwsh: $PWSH, else pwsh on PATH. Without pwsh (or PSScriptAnalyzer, for the compatibility check) the tests
# skip, unless SKILL_EXAMPLES_REQUIRE_TOOLS=1, where a missing tool fails them.

setup() {
  load helpers
  T="$BATS_TEST_TMPDIR"
  FAKE_ENV=()
  export FAKE_CALLS="$T/calls.log" FAKE_STATE="$T/state"
  mkdir -p "$T/bin" "$T/home" "$T/local" "$T/tmp" "$FAKE_STATE"
  link_tools "$T/sys" bash touch cp chmod dirname basename
  SETTINGS="$T/home/.claude/settings.json"
  UPDATER="$T/local/my-claude-skills/update-plugins.ps1"
  HOOK_CMD="powershell -NoProfile -ExecutionPolicy Bypass -File \"$UPDATER\""
}

# missing_tool REASON: skips, or fails when SKILL_EXAMPLES_REQUIRE_TOOLS=1
missing_tool() {
  if [ "${SKILL_EXAMPLES_REQUIRE_TOOLS:-}" = 1 ]; then
    echo "required tool missing (SKILL_EXAMPLES_REQUIRE_TOOLS=1): $*"
    return 1
  fi
  skip "$*"
}

need_pwsh() {
  PWSH_BIN="${PWSH:-}"
  [ -n "$PWSH_BIN" ] || PWSH_BIN=$(command -v pwsh) || missing_tool "pwsh not installed (set PWSH=/path/to/pwsh to run this)"
}

# fake NAME: an executable $T/bin/NAME that logs "NAME ARGS" to $FAKE_CALLS, then runs the script on stdin
fake() {
  { echo '#!/usr/bin/env bash'; echo "echo \"$1 \$*\" >> \"\$FAKE_CALLS\""; cat; } > "$T/bin/$1"
  chmod +x "$T/bin/$1"
}

# the fakes every install.ps1 run needs: git, node and claude (plugin "broken" fails to install)
base_fakes() {
  fake git <<'EOF'
case "$1" in
  --version) echo "git version 2.51.0" ;;
  --exec-path) [ -z "${FAKE_GIT_EXEC_PATH:-}" ] || echo "$FAKE_GIT_EXEC_PATH" ;;
esac
EOF
  fake node <<<'echo v22.20.0'
  fake claude <<'EOF'
case "$*" in
  --version) echo "2.1.0 (Claude Code)" ;;
  "plugin install broken@"*) echo "claude-says: cannot install $3" >&2; exit 1 ;;
  "plugin install "*) echo "claude-says: installed $3" ;;
esac
EOF
}

# driver: stubs, then runs an installer
#   driver.ps1 file SCRIPT [PLUGIN...]  & SCRIPT PLUGIN, ... (as .\install.ps1 dotnet, powershell); prints exit=<code>
#   driver.ps1 plugin SCRIPT PLUGIN...  & SCRIPT -Plugin PLUGIN, ...; prints exit=<code>
#   driver.ps1 iex SCRIPT               Get-Content -Raw SCRIPT | Invoke-Expression, as `irm | iex` does,
#                                       then prints what the installer left in the session
write_driver() {
  cat > "$T/driver.ps1" <<'PS1'
# pwsh puts its own directory first on PATH; without it, `pwsh` is the fake (and the fakes are all there is)
$env:PATH = @($env:PATH -split [IO.Path]::PathSeparator | Where-Object { $_ -and $_ -ne $PSHOME }) -join [IO.Path]::PathSeparator
function global:Invoke-WebRequest {
    param([string] $Uri, [string] $OutFile, [switch] $UseBasicParsing)
    $prefix = 'https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/'
    if (-not $Uri.StartsWith($prefix)) { throw "no network in tests: $Uri" }
    Copy-Item (Join-Path $env:REPO_ROOT $Uri.Substring($prefix.Length)) $OutFile
}
function global:Invoke-RestMethod {
    param([string] $Uri)
    if ($Uri -like '*/main/.claude-plugin/marketplace.json' -and $env:FAKE_MANIFEST) { return (Get-Content -Raw $env:FAKE_MANIFEST | ConvertFrom-Json) }
    throw "no network in tests: $Uri"
}
function global:Get-AppxPackage { if ($env:FAKE_DESKTOP) { [pscustomobject]@{ Name = 'Claude' } } }
function global:Read-Host { $env:FAKE_REPLY }

$mode, $installer, $rest = $args
if ($mode -ne 'iex') {
    $global:LASTEXITCODE = 0
    try {
        if (-not $rest) { & $installer }
        elseif ($mode -eq 'file') { & $installer @($rest) }
        else { & $installer -Plugin @($rest) }
        "exit=$LASTEXITCODE"
    } catch { "threw: $($_.Exception.Message)" }
} else {
    try { Get-Content -Raw $installer | Invoke-Expression } catch { "threw: $($_.Exception.Message)" }
    'still in the session'
    "ErrorActionPreference=$ErrorActionPreference"
    $vars = @('repo', 'name', 'failed', 'settings', 'settingsPath', 'updater', 'existing', 'scriptFile', 'here') | Where-Object { Test-Path "variable:$_" }
    "leaked variables=[$($vars -join ',')]"
    $fns = @('Test-Cmd', 'Install-Winget', 'Invoke-Quiet', 'Test-PlainJson') | Where-Object { Test-Path "function:$_" }
    "leaked functions=[$($fns -join ',')]"
}
"ATTRIBUTION_GUARD_SKIP_CLAUDE=[$env:ATTRIBUTION_GUARD_SKIP_CLAUDE]"
PS1
}

# run_ps MODE SCRIPT [PLUGIN...]: runs the driver in pwsh with an empty environment apart from the temp dirs,
# PATH = the fakes plus bash, and the FAKE_* settings in the FAKE_ENV array
run_ps() {
  need_pwsh
  write_driver
  run env -i HOME="$T/home" USERPROFILE="$T/home" LOCALAPPDATA="$T/local" COPILOT_HOME="$T/copilot" \
    XDG_CONFIG_HOME="$T/home/.config" TMPDIR="$T/tmp" PATH="$T/bin:$T/sys" LANG=C.UTF-8 \
    POWERSHELL_TELEMETRY_OPTOUT=1 POWERSHELL_UPDATECHECK=Off DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    REPO_ROOT="$REPO_ROOT" FAKE_CALLS="$FAKE_CALLS" FAKE_STATE="$FAKE_STATE" "${FAKE_ENV[@]}" \
    "$PWSH_BIN" -NoLogo -NoProfile -NonInteractive -File "$T/driver.ps1" "$@"
}

# with_env NAME=VALUE...: settings for the fakes and the driver, passed by the next run_ps calls
with_env() { FAKE_ENV+=("$@"); }

# our_hooks FILE: the SessionStart commands that run update-plugins.ps1, one per line
our_hooks() {
  jq -r '.hooks.SessionStart[]?.hooks[]? | select(.command | test("update-plugins\\.ps1")) | .command' "$1"
}

manifest() {
  printf '%s\n' "$@" | jq -R . | jq -s '{name: "my-claude-skills", plugins: [.[] | {name: .}]}' > "$T/manifest.json"
  with_env FAKE_MANIFEST="$T/manifest.json"
}

# --- Windows PowerShell 5.1 compatibility ------------------------------------------------------------

@test "static: install.ps1, install-copilot.ps1 and scripts/update-plugins.ps1 are Windows PowerShell 5.1 compatible (PSScriptAnalyzer)" {
  need_pwsh
  "$PWSH_BIN" -NoLogo -NoProfile -NonInteractive -Command 'if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { exit 1 }' \
    || missing_tool "PSScriptAnalyzer not installed (Install-Module PSScriptAnalyzer -Scope CurrentUser)"
  cat > "$T/compat.ps1" <<'PS1'
# The two Windows PowerShell 5.1 profiles PSScriptAnalyzer ships (Windows 10 and Server 2019)
$profiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework',
              'win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
$settings = @{
    IncludeRules = @('PSUseCompatibleSyntax', 'PSUseCompatibleCommands', 'PSUseCompatibleTypes')
    Rules = @{
        PSUseCompatibleSyntax   = @{ Enable = $true; TargetVersions = @('5.1') }
        # native CLIs, not PowerShell commands (some profiles list the ones found on the profiled machine)
        PSUseCompatibleCommands = @{ Enable = $true; TargetProfiles = $profiles; IgnoreCommands = @('git', 'node', 'npm', 'dotnet', 'pwsh', 'uv', 'winget') }
        PSUseCompatibleTypes    = @{ Enable = $true; TargetProfiles = $profiles }
    }
}
$bad = 0
foreach ($f in $args) {
    foreach ($d in Invoke-ScriptAnalyzer -Path $f -Settings $settings) {
        '{0}:{1}: {2}: {3}' -f $f, $d.Line, $d.RuleName, $d.Message
        $bad = 1
    }
}
exit $bad
PS1
  # the check itself works: PowerShell 7-only syntax, a 7-only parameter and a .NET Core-only method are caught
  # (PSUseCompatibleTypes checks members only for full type names, not for accelerators such as [IO.Path])
  cat > "$T/ps7-only.ps1" <<'PS1'
$x = $env:FOO ?? 'default'
$j = '{}' | ConvertFrom-Json -AsHashtable
[System.IO.Path]::GetRelativePath('C:\a', 'C:\a\b')
PS1
  run "$PWSH_BIN" -NoLogo -NoProfile -NonInteractive -File "$T/compat.ps1" "$T/ps7-only.ps1"
  assert_status 1
  assert_output_contains "ps7-only.ps1:1: PSUseCompatibleSyntax"
  assert_output_contains "ps7-only.ps1:2: PSUseCompatibleCommands"
  assert_output_contains "ps7-only.ps1:3: PSUseCompatibleTypes"

  run "$PWSH_BIN" -NoLogo -NoProfile -NonInteractive -File "$T/compat.ps1" \
    "$REPO_ROOT/install.ps1" "$REPO_ROOT/install-copilot.ps1" "$REPO_ROOT/scripts/update-plugins.ps1"
  assert_status 0
}

# --- install.ps1 --------------------------------------------------------------------------------------

@test "install.ps1 under irm | iex: a failed plugin is reported, the session stays open and keeps its settings" {
  base_fakes
  manifest alpha broken
  run_ps iex "$REPO_ROOT/install.ps1"
  assert_line "still in the session"
  assert_line "ErrorActionPreference=Continue"
  assert_line "leaked variables=[]"
  assert_line "leaked functions=[]"
  assert_line "ATTRIBUTION_GUARD_SKIP_CLAUDE=[]"
  assert_output_contains "failed plugins: broken"
  refute_output_contains "threw:"
  grep -qxF "claude plugin install alpha@my-claude-skills" "$FAKE_CALLS"
  grep -qxF "claude plugin install broken@my-claude-skills" "$FAKE_CALLS"
  # update-plugins.ps1 came from the (stubbed) download, and the hook runs it
  cmp "$REPO_ROOT/scripts/update-plugins.ps1" "$UPDATER"
  assert_eq "$(our_hooks "$SETTINGS")" "$HOOK_CMD" "hook command"
}

@test "install.ps1 under irm | iex: answering no at the desktop-app prompt returns to the session" {
  base_fakes
  manifest alpha
  with_env FAKE_DESKTOP=1 FAKE_REPLY=n
  run_ps iex "$REPO_ROOT/install.ps1"
  assert_line "Aborted at your request."
  assert_line "still in the session"
  assert_line "leaked variables=[]"
  refute grep -q "plugin install" "$FAKE_CALLS"
  assert_not_exists "$SETTINGS"
}

@test "install.ps1 as a file: installs the plugins it is given and exits 1 when one failed" {
  base_fakes
  run_ps file "$REPO_ROOT/install.ps1" alpha broken
  assert_line "exit=1"
  assert_output_contains "failed plugins: broken"
  assert_eq "$(grep 'plugin install' "$FAKE_CALLS")" "claude plugin install alpha@my-claude-skills
claude plugin install broken@my-claude-skills" "installs"
  # the local scripts/update-plugins.ps1 is copied, nothing is downloaded
  cmp "$REPO_ROOT/scripts/update-plugins.ps1" "$UPDATER"

  : > "$FAKE_CALLS"
  run_ps file "$REPO_ROOT/install.ps1" alpha
  assert_line "exit=0"
  assert_eq "$(grep 'plugin install' "$FAKE_CALLS")" "claude plugin install alpha@my-claude-skills" "installs"
}

@test "install.ps1 registers the SessionStart hook once, however often it runs, and replaces an older registration" {
  base_fakes
  mkdir -p "$(dirname "$SETTINGS")"
  # an older install's entry (Windows path, JSON-escaped backslashes) next to a hook of the user's own
  cat > "$SETTINGS" <<'EOF'
{
  "model": "opus",
  "hooks": {
    "SessionStart": [
      { "matcher": "startup", "hooks": [ { "type": "command", "shell": "powershell", "async": true,
          "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\u\\AppData\\Local\\my-claude-skills\\update-plugins.ps1\"" } ] },
      { "matcher": "startup", "hooks": [ { "type": "command", "command": "echo mine" } ] }
    ]
  }
}
EOF
  run_ps file "$REPO_ROOT/install.ps1" alpha
  assert_line "exit=0"
  run_ps file "$REPO_ROOT/install.ps1" alpha
  assert_line "exit=0"
  assert_eq "$(our_hooks "$SETTINGS")" "$HOOK_CMD" "our hooks after two runs"
  assert_eq "$(jq -c '[.hooks.SessionStart[] | select(.hooks[].command | test("update-plugins")) | .matcher, .hooks[0].shell, .hooks[0].async]' "$SETTINGS")" \
    '["startup","powershell",true]' "our hook's matcher, shell and async"
  assert_eq "$(jq -r '[.hooks.SessionStart[].hooks[].command] | map(select(. == "echo mine")) | length' "$SETTINGS")" 1 "the user's hook"
  assert_eq "$(jq -r .model "$SETTINGS")" opus "other settings"
  assert_eq "$(jq -c .attribution "$SETTINGS")" '{"commit":"","pr":"","sessionUrl":false}' "attribution"
  # UTF-8 without BOM
  assert_eq "$(head -c 1 "$SETTINGS")" "{" "first byte"
}

@test "install.ps1 treats an empty settings.json as {}" {
  base_fakes
  mkdir -p "$(dirname "$SETTINGS")"
  : > "$SETTINGS"
  run_ps file "$REPO_ROOT/install.ps1" alpha
  assert_line "exit=0"
  refute_output_contains "could not"
  assert_eq "$(our_hooks "$SETTINGS")" "$HOOK_CMD" "hook command"
  assert_eq "$(jq -c .attribution "$SETTINGS")" '{"commit":"","pr":"","sessionUrl":false}' "attribution"
}

@test "install.ps1 leaves a settings.json with comments (JSONC) untouched and still finishes" {
  base_fakes
  mkdir -p "$(dirname "$SETTINGS")"
  printf '{\n  // my note: keep this\n  "model": "opus",\n}\n' > "$SETTINGS"
  cp "$SETTINGS" "$T/before.json"
  run_ps file "$REPO_ROOT/install.ps1" alpha
  assert_line "exit=0"
  cmp "$T/before.json" "$SETTINGS"
  assert_output_contains "could not register the startup auto-update hook in $SETTINGS (not plain JSON"
  assert_output_contains "could not update $SETTINGS; add \"attribution\""
  assert_line "Done. Restart Claude Code to load the plugins."
}

@test "install.ps1 sets ATTRIBUTION_GUARD_SKIP_CLAUDE only for the guard's install.sh" {
  base_fakes
  # Git for Windows layout: sh.exe in <root>\bin, three levels above `git --exec-path`
  mkdir -p "$T/git/bin" "$T/git/mingw64/libexec/git-core"
  cat > "$T/git/bin/sh.exe" <<'EOF'
#!/usr/bin/env bash
echo "sh.exe $(basename "$1") skip=${ATTRIBUTION_GUARD_SKIP_CLAUDE:-}" >> "$FAKE_CALLS"
EOF
  chmod +x "$T/git/bin/sh.exe"
  with_env FAKE_GIT_EXEC_PATH="$T/git/mingw64/libexec/git-core"
  run_ps file "$REPO_ROOT/install.ps1" alpha
  assert_line "exit=0"
  assert_line "ATTRIBUTION_GUARD_SKIP_CLAUDE=[]"
  grep -qxF "sh.exe install.sh skip=1" "$FAKE_CALLS"
  assert_eq "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("claude-pretooluse"))] | length' "$SETTINGS")" 1 "PreToolUse hook"
}

@test "install.ps1 stops with a clear message when git or node is still missing" {
  base_fakes
  rm "$T/bin/node"
  run_ps file "$REPO_ROOT/install.ps1" alpha
  assert_output_contains "winget not found; install Node.js LTS manually"
  assert_output_contains "threw: node not found; install it manually"
  refute_output_contains "is not recognized"
  refute grep -q "^claude " "$FAKE_CALLS"
}

@test "install.ps1 installs agent-browser through npm.cmd; a failure there still registers the hook" {
  base_fakes
  fake npm.cmd <<<':'
  # npm.cmd "succeeds" but no agent-browser.cmd appears: the tool step fails, the rest goes on
  run_ps file "$REPO_ROOT/install.ps1" agent-browser
  assert_line "exit=0"
  grep -qxF "npm.cmd install -g agent-browser" "$FAKE_CALLS"
  assert_output_contains "agent-browser install failed ("
  assert_eq "$(our_hooks "$SETTINGS")" "$HOOK_CMD" "hook command"

  # npm.cmd puts agent-browser.cmd on PATH, which then installs Chrome
  fake npm.cmd <<'EOF'
printf '#!/usr/bin/env bash\necho "agent-browser.cmd $*" >> "$FAKE_CALLS"\n' > "$(dirname "$0")/agent-browser.cmd"
chmod +x "$(dirname "$0")/agent-browser.cmd"
EOF
  run_ps file "$REPO_ROOT/install.ps1" agent-browser
  assert_line "exit=0"
  grep -qxF "agent-browser.cmd install" "$FAKE_CALLS"
}

@test "install.ps1 installs Pester 6 next to Windows' inbox Pester 3.4, with -SkipPublisherCheck" {
  base_fakes
  fake pwsh <<'EOF'
while [ "$#" -gt 0 ]; do
  if [ "$1" = -Command ]; then
    case "$2" in *PSVersionTable*) echo 7.5.0 ;; *) printf '%s\n' "$2" > "$FAKE_STATE/modules.ps1" ;; esac
  fi
  shift
done
EOF
  run_ps file "$REPO_ROOT/install.ps1" powershell
  assert_line "exit=0"
  assert_output_contains "pwsh present (7.5.0)"
  refute grep -q '"' "$FAKE_STATE/modules.ps1"   # Windows PowerShell 5.1 would drop double quotes
  # run the recorded command with stubs: which modules would it install?
  cat > "$T/modules-driver.ps1" <<'PS1'
$have = @{ Pester = [version] $args[0]; PSScriptAnalyzer = [version] '1.21.0' }
function Get-Module { param([switch] $ListAvailable, [string] $Name) if ($have[$Name]) { [pscustomobject]@{ Name = $Name; Version = $have[$Name] } } }
function Install-Module { param([string] $Name, [version] $MinimumVersion, [string] $Scope, [switch] $Force, [switch] $SkipPublisherCheck) "install $Name min=$MinimumVersion skip=$SkipPublisherCheck" }
Invoke-Expression (Get-Content -Raw $args[1])
PS1
  run "$PWSH_BIN" -NoLogo -NoProfile -NonInteractive -File "$T/modules-driver.ps1" 3.4.0 "$FAKE_STATE/modules.ps1"
  assert_status 0
  assert_eq "$output" "install Pester min=6.0.0 skip=True" "with Pester 3.4.0"
  run "$PWSH_BIN" -NoLogo -NoProfile -NonInteractive -File "$T/modules-driver.ps1" 6.1.0 "$FAKE_STATE/modules.ps1"
  assert_status 0
  assert_eq "$output" "" "with Pester 6.1.0"
}

@test "install.ps1 upgrades a yamllint older than 1.30 through uv tool" {
  base_fakes
  fake yamllint <<'EOF'
if [ -f "$FAKE_STATE/yamllint-new" ]; then echo "yamllint 1.38.0"; else echo "yamllint 1.26.3"; fi
EOF
  # uv manages this yamllint: `uv tool upgrade` updates it
  fake uv <<'EOF'
case "$*" in
  "tool list") printf 'yamllint v1.26.3\n- yamllint\n' ;;
  "tool upgrade yamllint") touch "$FAKE_STATE/yamllint-new" ;;
esac
EOF
  run_ps file "$REPO_ROOT/install.ps1" yaml-hooks
  assert_line "exit=0"
  grep -qxF "uv tool upgrade yamllint" "$FAKE_CALLS"
  refute_output_contains "older than 1.30"

  # a yamllint uv does not manage stays first on PATH after `uv tool install`: a warning names it
  rm "$FAKE_STATE/yamllint-new"
  : > "$FAKE_CALLS"
  fake uv <<<':'
  run_ps file "$REPO_ROOT/install.ps1" yaml-hooks
  assert_line "exit=0"
  grep -qxF "uv tool install yamllint" "$FAKE_CALLS"
  assert_output_contains "yamllint 1.26.3 ($T/bin/yamllint) comes first on PATH and is older than 1.30"

  # no uv and no winget: a warning, and the installer goes on
  rm "$T/bin/uv"
  run_ps file "$REPO_ROOT/install.ps1" yaml-hooks
  assert_line "exit=0"
  assert_output_contains "uv not found; install yamllint 1.30 or newer"
}

@test "install.ps1 keeps a yamllint that is new enough" {
  base_fakes
  fake yamllint <<<'echo "yamllint 1.30.0"'
  run_ps file "$REPO_ROOT/install.ps1" yaml-hooks
  assert_line "exit=0"
  assert_output_contains "yamllint present (1.30.0)"
  refute grep -q "^uv " "$FAKE_CALLS"
}

# --- install-copilot.ps1 ------------------------------------------------------------------------------

copilot_fakes() {
  fake copilot <<'EOF'
case "$*" in
  --version) echo "GitHub Copilot CLI 1.0.80" ;;
  "plugin marketplace add "*) echo "copilot-says: marketplace added" ;;
  "plugin install broken@"*) echo "copilot-says: error installing $3"; exit 1 ;;
  "plugin install "*) echo "copilot-says: installed $3" ;;
esac
EOF
}

@test "install-copilot.ps1 shows Copilot CLI's own output and reports a failed plugin" {
  copilot_fakes
  run_ps plugin "$REPO_ROOT/install-copilot.ps1" alpha broken
  assert_line "copilot-says: marketplace added"
  assert_line "copilot-says: error installing broken@my-claude-skills"
  assert_output_contains "failed plugins: broken"
  assert_output_contains "install-copilot finished with problems"
}

@test "install-copilot.ps1 installs Copilot CLI through winget, whose output stays visible" {
  fake winget <<'EOF'
echo "winget-says: installed GitHub.Copilot"
cp "$(dirname "$0")/copilot.pending" "$(dirname "$0")/copilot"
EOF
  copilot_fakes
  mv "$T/bin/copilot" "$T/bin/copilot.pending"
  run_ps plugin "$REPO_ROOT/install-copilot.ps1" alpha
  assert_line "winget-says: installed GitHub.Copilot"
  assert_line "copilot-says: installed alpha@my-claude-skills"
  refute_output_contains "finished with problems"
}

@test "install-copilot.ps1 creates a missing Copilot settings.json with autoUpdate on and co-author trailers off" {
  copilot_fakes
  assert_not_exists "$T/copilot"
  run_ps plugin "$REPO_ROOT/install-copilot.ps1" alpha
  refute_output_contains "WARNING"
  assert_eq "$(jq -c '{a: .extraKnownMarketplaces["my-claude-skills"], c: .includeCoAuthoredBy}' "$T/copilot/settings.json")" \
    '{"a":{"source":{"source":"github","repo":"lucas4790/my-claude-skills"},"autoUpdate":true},"c":false}' "settings"
}

@test "install-copilot.ps1 updates a plain Copilot settings.json in place, keeping the other settings" {
  copilot_fakes
  mkdir -p "$T/copilot"
  echo '{"model": "gpt-5", "extraKnownMarketplaces": {"my-claude-skills": {"source": {"source": "github", "repo": "fork/x"}}}}' \
    > "$T/copilot/settings.json"
  run_ps plugin "$REPO_ROOT/install-copilot.ps1" alpha
  assert_eq "$(jq -c . "$T/copilot/settings.json")" \
    '{"model":"gpt-5","extraKnownMarketplaces":{"my-claude-skills":{"source":{"source":"github","repo":"fork/x"},"autoUpdate":true}},"includeCoAuthoredBy":false}' "settings"
}

@test "install-copilot.ps1 leaves a Copilot settings.json with comments untouched and names both settings" {
  copilot_fakes
  mkdir -p "$T/copilot"
  printf '{\n  // keep me\n  "model": "x",\n}\n' > "$T/copilot/settings.json"
  cp "$T/copilot/settings.json" "$T/before.json"
  run_ps plugin "$REPO_ROOT/install-copilot.ps1" alpha
  cmp "$T/before.json" "$T/copilot/settings.json"
  assert_output_contains "not plain JSON (comments or trailing commas)"
  assert_output_contains "autoUpdate = true and includeCoAuthoredBy = false by hand"
}
