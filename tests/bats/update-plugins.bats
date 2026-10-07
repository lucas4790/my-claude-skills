#!/usr/bin/env bats
# shellcheck disable=SC2016  # $* and $FAKE_CALLS belong to the generated fake script
# scripts/update-plugins.sh: throttling, --force, missing tools, the update/install loop with its
# snapshot of known plugins, and the refresh of the installed copy.
# claude and copilot are fakes that log their arguments; HOME, the caches and CLAUDE_CONFIG_DIR are
# temp dirs, and PATH holds only the fakes plus symlinks to the system tools the script needs, so the
# real CLIs and ~/.claude are never touched. The script runs from the checkout, where it never
# refreshes itself; the refresh tests run a copy outside it.

setup() {
  load helpers
  T="$BATS_TEST_TMPDIR"
  SCRIPT="$REPO_ROOT/scripts/update-plugins.sh"
  export HOME="$T/home" XDG_CACHE_HOME="$T/cache" XDG_CONFIG_HOME="$T/config" CLAUDE_CONFIG_DIR="$T/claude"
  unset MY_CLAUDE_SKILLS_INTERVAL MY_CLAUDE_SKILLS_ATTRIBUTION COPILOT_HOME
  unset FAKE_CLAUDE_MP_RC FAKE_CLAUDE_LIST_RC FAKE_CLAUDE_INSTALL_FAIL
  mkdir -p "$HOME"
  CACHE="$XDG_CACHE_HOME/my-claude-skills"
  LOG="$CACHE/update.log"
  KNOWN="$CLAUDE_CONFIG_DIR/plugins/my-claude-skills-known-plugins"
  STAMP="$CLAUDE_CONFIG_DIR/plugins/my-claude-skills-last-run"   # per config dir, next to KNOWN
  PROFILES="$CLAUDE_CONFIG_DIR/plugins/my-claude-skills-profiles"
  PKNOWN="$CLAUDE_CONFIG_DIR/plugins/my-claude-skills-profile-plugins"
  MP_DIR="$CLAUDE_CONFIG_DIR/plugins/marketplaces/my-claude-skills"
  export FAKE_CALLS="$T/calls.log" FAKE_STATE="$T/state"
  mkdir -p "$FAKE_STATE" "$MP_DIR/.claude-plugin"

  # the marketplace clone offers alpha, beta, gamma; Claude Code has alpha and gamma (plus a plugin
  # of another marketplace); Copilot CLI has alpha (plus another marketplace's zeta)
  echo '{"name": "my-claude-skills", "plugins": [{"name": "alpha"}, {"name": "beta"}, {"name": "gamma"}]}' \
    > "$MP_DIR/.claude-plugin/marketplace.json"
  echo '[{"id": "alpha@my-claude-skills"}, {"id": "gamma@my-claude-skills"}, {"id": "zeta@other-market"}]' \
    > "$FAKE_STATE/claude-installed.json"
  echo '[{"name": "alpha", "marketplace": "my-claude-skills"}, {"name": "zeta", "marketplace": "other-market"}]' \
    > "$FAKE_STATE/copilot-installed.json"

  mkdir -p "$T/fake" "$T/fake-claude-only"
  cat > "$T/fake/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude $*" >> "$FAKE_CALLS"
case "$*" in
  "plugin marketplace update "*) exit "${FAKE_CLAUDE_MP_RC:-0}" ;;
  "plugin list --json")
    [ -z "${FAKE_CLAUDE_LIST_RC:-}" ] || { echo "error: plugin list failed" >&2; exit "$FAKE_CLAUDE_LIST_RC"; }
    cat "$FAKE_STATE/claude-installed.json" ;;
  "plugin update alpha@"*) echo "alpha is already up to date" ;;
  "plugin update "*) echo "updated ${3%@*} to 2.0.0" ;;
  "plugin install "*)
    [ "${3%@*}" != "${FAKE_CLAUDE_INSTALL_FAIL:-}" ] || { echo "error: installing ${3%@*} failed"; exit 1; }
    echo "installed ${3%@*}" ;;
esac
EOF
  cat > "$T/fake/copilot" <<'EOF'
#!/usr/bin/env bash
echo "copilot $*" >> "$FAKE_CALLS"
case "$*" in
  "plugin list --json") cat "$FAKE_STATE/copilot-installed.json" ;;
esac
EOF
  chmod +x "$T/fake/claude" "$T/fake/copilot"
  cp "$T/fake/claude" "$T/fake-claude-only/claude"

  local tools=(bash sh env mkdir date stat touch grep cat sed tr head cmp cp mv rm dirname)
  link_tools "$T/sys" "${tools[@]}" jq
  link_tools "$T/sys-nojq" "${tools[@]}"
}

# run_update PATH-DIRS ARGS...: runs $SCRIPT (the real script) with PATH set to PATH-DIRS only
run_update() {
  local path="$1"; shift
  run env PATH="$path" "${UPDATE_BASH:-$BASH}" "$SCRIPT" "$@"
}

calls() { cat "$FAKE_CALLS" 2>/dev/null; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
# age FILE SECONDS: sets FILE's mtime SECONDS in the past (portable, no GNU touch -d)
age() { python3 -c 'import os, sys, time; t = time.time() - int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"; }
# snapshot NAME...: the known-plugins snapshot a previous run left behind
snapshot() { mkdir -p "$(dirname "$KNOWN")"; printf '%s\n' "$@" > "$KNOWN"; }
# follow PROFILE...: what install.sh --profile recorded for this config dir
follow() { mkdir -p "$(dirname "$PROFILES")"; printf '%s\n' "$@" > "$PROFILES"; }
# profile_snapshot NAME...: the plugins of the recorded profiles that earlier runs handled
profile_snapshot() { mkdir -p "$(dirname "$PKNOWN")"; printf '%s\n' "$@" > "$PKNOWN"; }
# profiles_json JSON: profiles.json of the marketplace clone
profiles_json() { printf '%s\n' "$1" > "$MP_DIR/profiles.json"; }
# offers CLONE NAME...: the marketplace clone CLONE lists the plugins NAME...
offers() {
  local clone="$1"; shift
  mkdir -p "$clone/.claude-plugin"
  printf '%s\n' "$@" | jq -R '{name: .}' | jq -s '{name: "my-claude-skills", plugins: .}' > "$clone/.claude-plugin/marketplace.json"
}
# installed NAME...: the plugins of this marketplace that Claude Code reports as installed
installed() { printf '%s\n' "$@" | jq -R '{id: (. + "@my-claude-skills")}' | jq -s . > "$FAKE_STATE/claude-installed.json"; }

@test "update-plugins: --force refreshes the marketplace, updates installed plugins, records a first snapshot" {
  # the shared list in the cache dir of an earlier version of this branch is not this config's snapshot
  mkdir -p "$CACHE"
  echo alpha > "$CACHE/known-plugins"
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  assert_eq "$output" "" "stdout/stderr (everything goes to the log)"
  # no snapshot yet (first run of this version): beta is not installed, since nothing says it is new
  assert_eq "$(calls)" "claude plugin marketplace update my-claude-skills
claude plugin list --json
claude plugin update alpha@my-claude-skills
claude plugin update gamma@my-claude-skills" "claude calls"
  grep -qxF "no plugin snapshot yet: recording the marketplace's 3 plugins, installing none" "$LOG"
  assert_file_content "$KNOWN" $'alpha\nbeta\ngamma\n'
  grep -qxF "updated gamma to 2.0.0" "$LOG"
  refute grep -q "already up to date" "$LOG"
  refute grep -q "new plugin" "$LOG"
  grep -qxF "done" "$LOG"
  grep -qE '^=== [0-9]{4}-[0-9]{2}-[0-9]{2}T' "$LOG"
  assert_exists "$STAMP"
}

@test "update-plugins: a subset install stays a subset (a known plugin that is not installed is left out)" {
  snapshot alpha beta gamma
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  refute grep -q "plugin install" "$FAKE_CALLS"
  grep -qxF "claude plugin update alpha@my-claude-skills" "$FAKE_CALLS"
  grep -qxF "claude plugin update gamma@my-claude-skills" "$FAKE_CALLS"
  refute grep -q "beta" "$FAKE_CALLS"
  assert_file_content "$KNOWN" $'alpha\nbeta\ngamma\n'
}

@test "update-plugins: an uninstalled plugin does not come back" {
  installed alpha beta gamma
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  assert_file_content "$KNOWN" $'alpha\nbeta\ngamma\n'

  installed alpha beta   # the user uninstalls gamma
  : > "$FAKE_CALLS"
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  refute grep -q "gamma" "$FAKE_CALLS"
  refute grep -q "plugin install" "$FAKE_CALLS"
}

@test "update-plugins: a plugin added to the marketplace after the snapshot is installed and recorded" {
  snapshot alpha gamma
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  assert_eq "$(calls)" "claude plugin marketplace update my-claude-skills
claude plugin list --json
claude plugin update alpha@my-claude-skills
claude plugin install beta@my-claude-skills
claude plugin update gamma@my-claude-skills" "claude calls"
  grep -qxF "new plugin: beta" "$LOG"
  grep -qxF "installed beta" "$LOG"
  assert_file_content "$KNOWN" $'alpha\nbeta\ngamma\n'
}

@test "update-plugins: a failed install of a new plugin stays out of the snapshot and is retried" {
  snapshot alpha gamma
  FAKE_CLAUDE_INSTALL_FAIL=beta run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  grep -qxF "install failed: beta (retried next run)" "$LOG"
  assert_file_content "$KNOWN" $'alpha\ngamma\n'

  : > "$FAKE_CALLS"
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  grep -qxF "claude plugin install beta@my-claude-skills" "$FAKE_CALLS"
  assert_file_content "$KNOWN" $'alpha\nbeta\ngamma\n'
}

@test "update-plugins: a plugin that leaves the marketplace and comes back is not new again" {
  installed alpha   # a subset install
  snapshot alpha beta gamma
  offers "$MP_DIR" alpha gamma   # beta leaves the marketplace for a while
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  assert_file_content "$KNOWN" $'alpha\ngamma\nbeta\n'

  offers "$MP_DIR" alpha beta gamma   # and comes back
  : > "$FAKE_CALLS"
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  refute grep -q "plugin install" "$FAKE_CALLS"
  refute grep -q "new plugin" "$LOG"
  assert_file_content "$KNOWN" $'alpha\nbeta\ngamma\n'
}

@test "update-plugins: every Claude config dir has its own snapshot, so a plugin added later reaches each one" {
  local cfg
  for cfg in work personal; do
    offers "$T/$cfg/plugins/marketplaces/my-claude-skills" alpha beta gamma
    CLAUDE_CONFIG_DIR="$T/$cfg" run_update "$T/fake-claude-only:$T/sys" --force
    assert_status 0
  done
  : > "$FAKE_CALLS"
  for cfg in work personal; do
    offers "$T/$cfg/plugins/marketplaces/my-claude-skills" alpha beta gamma delta
    CLAUDE_CONFIG_DIR="$T/$cfg" run_update "$T/fake-claude-only:$T/sys" --force
    assert_status 0
    assert_file_content "$T/$cfg/plugins/my-claude-skills-known-plugins" $'alpha\nbeta\ngamma\ndelta\n'
  done
  assert_eq "$(grep -c '^claude plugin install' "$FAKE_CALLS")" 2 "installs"
  assert_eq "$(grep -c '^claude plugin install delta@my-claude-skills$' "$FAKE_CALLS")" 2 "installs of delta"
  assert_not_exists "$CACHE/known-plugins"
}

@test "update-plugins: a failing plugin list installs nothing, still updates, and keeps the snapshot" {
  snapshot alpha gamma   # beta would be new
  FAKE_CLAUDE_LIST_RC=1 run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  refute grep -q "plugin install" "$FAKE_CALLS"
  grep -qxF "claude plugin update alpha@my-claude-skills" "$FAKE_CALLS"
  grep -qxF "claude plugin update gamma@my-claude-skills" "$FAKE_CALLS"
  grep -qxF "claude plugin list --json failed or gave no JSON list: updating only, installing no new plugins" "$LOG"
  assert_file_content "$KNOWN" $'alpha\ngamma\n'
  grep -qxF "done" "$LOG"
}

@test "update-plugins: plugin list output that is not a JSON list counts as a failed list" {
  snapshot alpha gamma
  echo "not json" > "$FAKE_STATE/claude-installed.json"
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  refute grep -q "plugin install" "$FAKE_CALLS"
  grep -qF "failed or gave no JSON list" "$LOG"
  assert_file_content "$KNOWN" $'alpha\ngamma\n'

  # and without a snapshot, none is recorded from such a run
  rm "$KNOWN"
  echo '{"plugins": "not a list"}' > "$FAKE_STATE/claude-installed.json"
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  refute grep -q "plugin install" "$FAKE_CALLS"
  assert_not_exists "$KNOWN"
}

@test "update-plugins: with copilot on PATH, updates only its installed plugins of this marketplace" {
  run_update "$T/fake:$T/sys" --force
  assert_status 0
  grep -qxF "copilot plugin marketplace update my-claude-skills" "$FAKE_CALLS"
  grep -qxF "copilot plugin list --json" "$FAKE_CALLS"
  grep -qxF "copilot plugin update alpha@my-claude-skills" "$FAKE_CALLS"
  refute grep -q "^copilot plugin install" "$FAKE_CALLS"
  refute grep -q "zeta" "$FAKE_CALLS"
  # Claude Code is still handled after Copilot
  assert_eq "$(grep -c '^claude ' "$FAKE_CALLS")" "4" "claude calls"
}

@test "update-plugins: a stamp younger than the interval exits 0 without doing anything" {
  mkdir -p "$(dirname "$STAMP")"
  touch "$STAMP"
  age "$STAMP" 60
  before=$(mtime "$STAMP")
  run_update "$T/fake:$T/sys"
  assert_status 0
  assert_eq "$output" "" "output"
  assert_not_exists "$FAKE_CALLS"
  assert_not_exists "$LOG"
  assert_eq "$(mtime "$STAMP")" "$before" "stamp mtime"
}

@test "update-plugins: a stamp older than MY_CLAUDE_SKILLS_INTERVAL runs and refreshes the stamp" {
  mkdir -p "$(dirname "$STAMP")"
  touch "$STAMP"
  age "$STAMP" 120
  before=$(mtime "$STAMP")
  MY_CLAUDE_SKILLS_INTERVAL=60 run_update "$T/fake-claude-only:$T/sys"
  assert_status 0
  grep -qxF "claude plugin marketplace update my-claude-skills" "$FAKE_CALLS"
  [ "$(mtime "$STAMP")" -gt "$before" ]
}

@test "update-plugins: every Claude config dir has its own throttle stamp, so a second config still runs right after the first" {
  local cfg
  for cfg in work personal; do
    offers "$T/$cfg/plugins/marketplaces/my-claude-skills" alpha beta gamma
  done
  CLAUDE_CONFIG_DIR="$T/work" run_update "$T/fake-claude-only:$T/sys"
  assert_status 0
  # a session in the other config dir, seconds later: not throttled by the first one's run
  : > "$FAKE_CALLS"
  CLAUDE_CONFIG_DIR="$T/personal" run_update "$T/fake-claude-only:$T/sys"
  assert_status 0
  grep -qxF "claude plugin marketplace update my-claude-skills" "$FAKE_CALLS"
  assert_eq "$(grep -c '^done$' "$LOG")" 2 "finished runs"
  # the stamps sit next to each config's known-plugins list, not in the shared cache dir
  assert_exists "$T/work/plugins/my-claude-skills-last-run"
  assert_exists "$T/personal/plugins/my-claude-skills-last-run"
  # each one is still throttled by its own stamp
  : > "$FAKE_CALLS"
  for cfg in work personal; do
    CLAUDE_CONFIG_DIR="$T/$cfg" run_update "$T/fake-claude-only:$T/sys"
    assert_status 0
  done
  assert_eq "$(calls)" "" "claude calls of the throttled runs"
  assert_not_exists "$CACHE/last-run"
}

@test "update-plugins: each run's log header names its config dir, so runs of different config dirs can be told apart in the shared log" {
  local cfg
  for cfg in work personal; do
    offers "$T/$cfg/plugins/marketplaces/my-claude-skills" alpha beta gamma
    CLAUDE_CONFIG_DIR="$T/$cfg" run_update "$T/fake-claude-only:$T/sys" --force
    assert_status 0
  done
  # no CLAUDE_CONFIG_DIR: ~/.claude
  offers "$HOME/.claude/plugins/marketplaces/my-claude-skills" alpha beta gamma
  CLAUDE_CONFIG_DIR='' run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  assert_eq "$(grep '^=== ' "$LOG" | sed -E 's/^=== [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z //')" \
    "$T/work
$T/personal
$HOME/.claude" "config dirs in the run headers"
}

@test "update-plugins: the same stamp is still fresh under the default interval (6 h)" {
  mkdir -p "$(dirname "$STAMP")"
  touch "$STAMP"
  age "$STAMP" 120
  run_update "$T/fake-claude-only:$T/sys"
  assert_status 0
  assert_not_exists "$FAKE_CALLS"
}

@test "update-plugins: --force ignores a fresh stamp" {
  mkdir -p "$(dirname "$STAMP")"
  touch "$STAMP"
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  grep -qxF "claude plugin marketplace update my-claude-skills" "$FAKE_CALLS"
}

@test "update-plugins: the first run (no stamp) runs and creates the stamp" {
  run_update "$T/fake-claude-only:$T/sys"
  assert_status 0
  assert_exists "$STAMP"
  grep -qxF "done" "$LOG"
}

@test "update-plugins: exits 0 quietly when claude is not installed" {
  run_update "$T/sys" --force
  assert_status 0
  assert_eq "$output" "" "output"
  assert_not_exists "$LOG"
  assert_not_exists "$FAKE_CALLS"
}

@test "update-plugins: exits 0 quietly when jq is not installed" {
  run_update "$T/fake:$T/sys-nojq" --force
  assert_status 0
  assert_eq "$output" "" "output"
  assert_not_exists "$LOG"
  assert_not_exists "$FAKE_CALLS"
}

@test "update-plugins: a failed marketplace update exits 1 and installs nothing" {
  FAKE_CLAUDE_MP_RC=1 run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 1
  grep -qxF "marketplace update failed" "$LOG"
  assert_eq "$(calls)" "claude plugin marketplace update my-claude-skills" "claude calls"
}

@test "update-plugins: a missing marketplace manifest exits 1 with a message" {
  rm "$MP_DIR/.claude-plugin/marketplace.json"
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 1
  grep -qxF "marketplace manifest not found at $MP_DIR/.claude-plugin/marketplace.json" "$LOG"
  refute grep -qE "plugin (install|update)" "$FAKE_CALLS"
}

@test "update-plugins: refreshes the attribution guard only where it is installed and not opted out" {
  mkdir -p "$MP_DIR/tools/attribution-guard"
  printf '#!/bin/sh\necho "guard install.sh $*" >> "$FAKE_CALLS"\n' > "$MP_DIR/tools/attribution-guard/install.sh"

  # guard not installed on this machine (no ~/.config/git/attribution-guard): not run
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  refute grep -q "^guard" "$FAKE_CALLS"

  mkdir -p "$XDG_CONFIG_HOME/git/attribution-guard"
  : > "$FAKE_CALLS"
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  grep -qxF "guard install.sh " "$FAKE_CALLS"

  : > "$FAKE_CALLS"
  MY_CLAUDE_SKILLS_ATTRIBUTION=keep run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  refute grep -q "^guard" "$FAKE_CALLS"
}

# copy_to DIR: SCRIPT = a copy of the script in DIR
copy_to() {
  mkdir -p "$1"
  SCRIPT="$1/update-plugins.sh"
  cp "$REPO_ROOT/scripts/update-plugins.sh" "$SCRIPT"
}

# installed_copy: SCRIPT = a copy of the script where install.sh puts it, outside any checkout
installed_copy() { copy_to "$T/data/my-claude-skills"; }

# newer_in_clone: the marketplace clone holds a newer update-plugins.sh
newer_in_clone() {
  mkdir -p "$MP_DIR/scripts"
  { cat "$REPO_ROOT/scripts/update-plugins.sh"; echo "# a newer version"; } > "$MP_DIR/scripts/update-plugins.sh"
}

@test "update-plugins: refreshes its installed copy from the marketplace clone, for the next run" {
  installed_copy
  newer_in_clone
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  cmp "$MP_DIR/scripts/update-plugins.sh" "$SCRIPT"
  grep -qxF "refreshed $SCRIPT from the marketplace (applies next run)" "$LOG"
  grep -qxF "done" "$LOG"   # the running copy finished its pass
  assert_eq "$(ls "$T/data/my-claude-skills")" "update-plugins.sh" "files next to the copy"

  # the refreshed copy runs next time and has nothing to refresh
  : > "$LOG"
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  refute grep -q "refreshed" "$LOG"
  grep -qxF "done" "$LOG"
}

@test "update-plugins: never refreshes a copy in a checkout of the repo, nor after a failed marketplace update" {
  newer_in_clone
  mkdir -p "$T/checkout/.claude-plugin"
  echo '{}' > "$T/checkout/.claude-plugin/marketplace.json"
  copy_to "$T/checkout/scripts"
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  cmp "$REPO_ROOT/scripts/update-plugins.sh" "$SCRIPT"
  refute grep -q "refresh" "$LOG"

  installed_copy
  FAKE_CLAUDE_MP_RC=1 run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 1
  cmp "$REPO_ROOT/scripts/update-plugins.sh" "$SCRIPT"
}

@test "update-plugins: piped into bash (no script file) it refreshes nothing: no file in the cwd, not the shell" {
  newer_in_clone
  mkdir -p "$T/cwd" "$T/shell"
  cp "$BASH" "$T/shell/bash"
  cd "$T/cwd"
  # $0 is "bash" here, and the copied shell's path below: neither is the updater
  run env PATH="$T/fake-claude-only:$T/sys" bash -s -- --force < "$SCRIPT"
  assert_status 0
  run env PATH="$T/fake-claude-only:$T/sys" "$T/shell/bash" -s -- --force < "$SCRIPT"
  assert_status 0
  assert_eq "$(grep -c '^done$' "$LOG")" 2 "finished runs"
  assert_eq "$(ls -A "$T/cwd")" "" "files in the cwd"
  cmp "$BASH" "$T/shell/bash"
  refute grep -q "refresh" "$LOG"
}

@test "update-plugins.ps1: the same snapshot rules and self-refresh (pwsh, or \$PWSH)" {
  local pwsh="${PWSH:-}"
  [ -n "$pwsh" ] || pwsh=$(command -v pwsh) || tool_missing "pwsh not installed (set PWSH=/path/to/pwsh to run this)"
  export LOCALAPPDATA="$T/local"
  local ps1="$T/data/update-plugins.ps1" known="$KNOWN"
  mkdir -p "$T/data" "$MP_DIR/scripts"
  cp "$REPO_ROOT/scripts/update-plugins.ps1" "$ps1"
  { cat "$REPO_ROOT/scripts/update-plugins.ps1"; echo "# a newer version"; } > "$MP_DIR/scripts/update-plugins.ps1"
  run_ps1() { run env PATH="$T/fake-claude-only:$T/sys" "$pwsh" -NoLogo -NoProfile -NonInteractive -File "$ps1" -Force; }

  # first run: records the snapshot, installs nothing, refreshes the copy for the next run
  run_ps1
  assert_status 0
  assert_eq "$(calls)" "claude plugin marketplace update my-claude-skills
claude plugin list --json
claude plugin update alpha@my-claude-skills
claude plugin update gamma@my-claude-skills" "claude calls"
  assert_eq "$(cat "$known")" $'alpha\nbeta\ngamma' "snapshot"
  cmp "$MP_DIR/scripts/update-plugins.ps1" "$ps1"

  # a failing list installs nothing and keeps the snapshot
  printf 'alpha\ngamma\n' > "$known"
  : > "$FAKE_CALLS"
  FAKE_CLAUDE_LIST_RC=1 run_ps1
  assert_status 0
  refute grep -q "plugin install" "$FAKE_CALLS"
  grep -qxF "claude plugin update gamma@my-claude-skills" "$FAKE_CALLS"
  assert_eq "$(cat "$known")" $'alpha\ngamma' "snapshot"

  # beta is new since the snapshot: installed and recorded
  : > "$FAKE_CALLS"
  run_ps1
  assert_status 0
  grep -qxF "claude plugin install beta@my-claude-skills" "$FAKE_CALLS"
  assert_eq "$(cat "$known")" $'alpha\nbeta\ngamma' "snapshot"

  # beta is known but not installed (left out or uninstalled): it stays out
  : > "$FAKE_CALLS"
  run_ps1
  assert_status 0
  refute grep -q "plugin install" "$FAKE_CALLS"

  # beta leaves the marketplace and comes back: still known, so still out
  offers "$MP_DIR" alpha gamma
  run_ps1
  assert_status 0
  assert_eq "$(cat "$known")" $'alpha\ngamma\nbeta' "snapshot"
  offers "$MP_DIR" alpha beta gamma
  run_ps1
  assert_status 0
  refute grep -q "plugin install" "$FAKE_CALLS"

  # another config dir keeps its own snapshot: delta, added later, reaches both
  local other="$T/claude2"
  offers "$other/plugins/marketplaces/my-claude-skills" alpha beta gamma
  CLAUDE_CONFIG_DIR="$other" run_ps1
  assert_status 0
  assert_eq "$(cat "$other/plugins/my-claude-skills-known-plugins")" $'alpha\nbeta\ngamma' "the other config's snapshot"
  offers "$MP_DIR" alpha beta gamma delta
  offers "$other/plugins/marketplaces/my-claude-skills" alpha beta gamma delta
  : > "$FAKE_CALLS"
  run_ps1
  assert_status 0
  CLAUDE_CONFIG_DIR="$other" run_ps1
  assert_status 0
  assert_eq "$(grep '^claude plugin install' "$FAKE_CALLS")" "claude plugin install delta@my-claude-skills
claude plugin install delta@my-claude-skills" "installs"
  assert_not_exists "$T/local/my-claude-skills/known-plugins"
}

@test "update-plugins.ps1: every Claude config dir has its own throttle stamp (pwsh, or \$PWSH)" {
  local pwsh="${PWSH:-}"
  [ -n "$pwsh" ] || pwsh=$(command -v pwsh) || tool_missing "pwsh not installed (set PWSH=/path/to/pwsh to run this)"
  local cfg
  for cfg in work personal; do
    offers "$T/$cfg/plugins/marketplaces/my-claude-skills" alpha beta gamma
  done
  # throttled runs (no -Force), as the SessionStart hook starts them
  run_ps1() {
    run env PATH="$T/fake-claude-only:$T/sys" LOCALAPPDATA="$T/local" CLAUDE_CONFIG_DIR="$T/$1" \
      "$pwsh" -NoLogo -NoProfile -NonInteractive -File "$REPO_ROOT/scripts/update-plugins.ps1"
  }

  run_ps1 work
  assert_status 0
  # a session in the other config dir, seconds later: not throttled by the first one's run
  : > "$FAKE_CALLS"
  run_ps1 personal
  assert_status 0
  grep -qxF "claude plugin marketplace update my-claude-skills" "$FAKE_CALLS"
  # the stamps sit next to each config's known-plugins list, not in the shared cache dir
  assert_exists "$T/work/plugins/my-claude-skills-last-run"
  assert_exists "$T/personal/plugins/my-claude-skills-last-run"
  # each one is still throttled by its own stamp
  : > "$FAKE_CALLS"
  run_ps1 work
  assert_status 0
  run_ps1 personal
  assert_status 0
  assert_eq "$(calls)" "" "claude calls of the throttled runs"
  assert_not_exists "$T/local/my-claude-skills/last-run"
}

@test "update-plugins.ps1: each run's log header names its config dir (pwsh, or \$PWSH)" {
  local pwsh="${PWSH:-}"
  [ -n "$pwsh" ] || pwsh=$(command -v pwsh) || tool_missing "pwsh not installed (set PWSH=/path/to/pwsh to run this)"
  local cfg
  offers "$HOME/.claude/plugins/marketplaces/my-claude-skills" alpha beta gamma
  for cfg in work personal ''; do   # '': no CLAUDE_CONFIG_DIR, so ~/.claude
    [ -z "$cfg" ] || offers "$T/$cfg/plugins/marketplaces/my-claude-skills" alpha beta gamma
    run env PATH="$T/fake-claude-only:$T/sys" LOCALAPPDATA="$T/local" CLAUDE_CONFIG_DIR="${cfg:+$T/$cfg}" \
      "$pwsh" -NoLogo -NoProfile -NonInteractive -File "$REPO_ROOT/scripts/update-plugins.ps1" -Force
    assert_status 0
  done
  assert_eq "$(grep '^=== ' "$T/local/my-claude-skills/update.log" | sed -E 's/^=== [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z //')" \
    "$T/work
$T/personal
$HOME/.claude" "config dirs in the run headers"
}

@test "update-plugins.ps1: the self-refresh copies to a temp file of its own and leaves another run's alone (pwsh, or \$PWSH)" {
  local pwsh="${PWSH:-}"
  [ -n "$pwsh" ] || pwsh=$(command -v pwsh) || tool_missing "pwsh not installed (set PWSH=/path/to/pwsh to run this)"
  local ps1="$T/data/update-plugins.ps1"
  mkdir -p "$T/data" "$MP_DIR/scripts"
  cp "$REPO_ROOT/scripts/update-plugins.ps1" "$ps1"
  { cat "$REPO_ROOT/scripts/update-plugins.ps1"; echo "# a newer version"; } > "$MP_DIR/scripts/update-plugins.ps1"
  # runs of other config dirs refresh the same copy: their temp files, half written (the fixed name an older
  # version used, and the name of another process)
  echo "half of another run's copy" > "$ps1.new"
  echo "half of another run's copy" > "$ps1.1"
  run env PATH="$T/fake-claude-only:$T/sys" LOCALAPPDATA="$T/local" \
    "$pwsh" -NoLogo -NoProfile -NonInteractive -File "$ps1" -Force
  assert_status 0
  cmp "$MP_DIR/scripts/update-plugins.ps1" "$ps1"
  grep -qF "refreshed $ps1 from the marketplace (applies next run)" "$T/local/my-claude-skills/update.log"
  assert_file_content "$ps1.new" "half of another run's copy
"
  assert_file_content "$ps1.1" "half of another run's copy
"
  # and its own temp file is gone
  assert_eq "$(ls "$T/data")" "update-plugins.ps1
update-plugins.ps1.1
update-plugins.ps1.new" "files next to the copy"
}

@test "update-plugins: runs under bash 3.2, macOS's /bin/bash (set BASH32=/path/to/bash-3.2)" {
  [ -n "${BASH32:-}" ] || skip "set BASH32=/path/to/bash-3.2 to run this"
  installed_copy
  newer_in_clone
  snapshot alpha
  UPDATE_BASH="$BASH32" run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  assert_eq "$(calls)" "claude plugin marketplace update my-claude-skills
claude plugin list --json
claude plugin update alpha@my-claude-skills
claude plugin install beta@my-claude-skills
claude plugin update gamma@my-claude-skills" "claude calls"
  assert_file_content "$KNOWN" $'alpha\nbeta\ngamma\n'
  cmp "$MP_DIR/scripts/update-plugins.sh" "$SCRIPT"
  refute grep -qE "command not found|unbound variable" "$LOG"

  # an empty marketplace and no snapshot: empty arrays under set -u
  echo '{"name": "my-claude-skills", "plugins": []}' > "$MP_DIR/.claude-plugin/marketplace.json"
  rm "$KNOWN"
  UPDATE_BASH="$BASH32" run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  refute grep -qE "command not found|unbound variable" "$LOG"
  assert_not_exists "$KNOWN"
}

# --- recorded profiles (install.sh --profile) -----------------------------------------------------------

# the clone offers alpha..epsilon; Claude Code has alpha and gamma; profile core holds alpha, beta, delta and
# profile other gamma and epsilon; this config dir follows core and has seen alpha, beta and gamma
profile_fixture() {
  offers "$MP_DIR" alpha beta gamma delta epsilon
  profiles_json '{"profiles": {"core": ["alpha", "beta", "delta"], "other": ["gamma", "epsilon"]}, "unrelated": 1}'
  follow core
  snapshot alpha beta gamma
  profile_snapshot alpha beta
}

@test "update-plugins: with a recorded profile, a new plugin of it is installed and a new one outside it is listed as available, once" {
  profile_fixture
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  assert_eq "$(grep '^claude plugin install' "$FAKE_CALLS")" "claude plugin install delta@my-claude-skills" "installs"
  grep -qxF "new plugin: delta" "$LOG"
  grep -qxF "available (outside profiles core): epsilon" "$LOG"
  assert_eq "$(grep -c '^available' "$LOG")" 1 "available lines"
  assert_file_content "$KNOWN" $'alpha\nbeta\ngamma\ndelta\nepsilon\n'
  assert_file_content "$PKNOWN" $'alpha\nbeta\ndelta\n'
  assert_file_content "$PROFILES" $'core\n'

  : > "$FAKE_CALLS"; : > "$LOG"
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  refute grep -q "plugin install" "$FAKE_CALLS"
  refute grep -q "^available" "$LOG"
}

@test "update-plugins: a plugin that profiles.json moves into a recorded profile counts as new, one that moves out stays" {
  profile_fixture
  offers "$MP_DIR" alpha beta gamma
  profiles_json '{"profiles": {"core": ["alpha"], "other": ["beta", "gamma"]}}'
  installed alpha beta gamma
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  refute grep -q "plugin install" "$FAKE_CALLS"   # beta moved out of core: still installed, still updated
  grep -qxF "claude plugin update beta@my-claude-skills" "$FAKE_CALLS"
  assert_file_content "$PKNOWN" $'alpha\nbeta\n'   # snapshots only grow

  # gamma (known, never in core) moves into core: new for this config dir
  profiles_json '{"profiles": {"core": ["alpha", "gamma"], "other": ["beta"]}}'
  installed alpha beta
  : > "$FAKE_CALLS"
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  assert_eq "$(grep '^claude plugin install' "$FAKE_CALLS")" "claude plugin install gamma@my-claude-skills" "installs"
  grep -qxF "new plugin: gamma" "$LOG"
  assert_file_content "$PKNOWN" $'alpha\ngamma\nbeta\n'

  # moves out and back in: not new again
  profiles_json '{"profiles": {"core": ["alpha"], "other": ["beta", "gamma"]}}'
  run_update "$T/fake-claude-only:$T/sys" --force
  profiles_json '{"profiles": {"core": ["alpha", "gamma"], "other": ["beta"]}}'
  installed alpha beta   # the user uninstalled gamma meanwhile
  : > "$FAKE_CALLS"
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  refute grep -q "plugin install" "$FAKE_CALLS"
}

@test "update-plugins: with a recorded profile, a plugin of it that was uninstalled stays out and a failed install is retried" {
  profile_fixture
  profile_snapshot alpha beta delta   # beta and delta are known members that are not installed
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  refute grep -q "plugin install" "$FAKE_CALLS"

  profile_snapshot alpha beta
  FAKE_CLAUDE_INSTALL_FAIL="delta" run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  grep -qxF "install failed: delta (retried next run)" "$LOG"
  assert_file_content "$PKNOWN" $'alpha\nbeta\n'
  : > "$FAKE_CALLS"
  run_update "$T/fake-claude-only:$T/sys" --force
  grep -qxF "claude plugin install delta@my-claude-skills" "$FAKE_CALLS"
  assert_file_content "$PKNOWN" $'alpha\nbeta\ndelta\n'
}

@test "update-plugins: a recorded profile without a snapshot of its plugins records them and installs none" {
  profile_fixture
  rm "$PKNOWN"
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  refute grep -q "plugin install" "$FAKE_CALLS"
  grep -qxF "no profile snapshot yet: recording the 3 plugins of profiles core, installing none" "$LOG"
  assert_file_content "$PKNOWN" $'alpha\nbeta\ndelta\n'
}

@test "update-plugins: an empty snapshot of a recorded profile's plugins is a snapshot, so its members that are not installed are new" {
  profile_fixture
  : > "$PKNOWN"   # install.sh left it empty: every plugin of the profile failed to install
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  assert_eq "$(grep '^claude plugin install' "$FAKE_CALLS")" "claude plugin install beta@my-claude-skills
claude plugin install delta@my-claude-skills" "installs"
  grep -qxF "new plugin: beta" "$LOG"
  refute grep -q "no profile snapshot yet" "$LOG"
  assert_file_content "$PKNOWN" $'alpha\nbeta\ndelta\n'

  # they fail again: the snapshot stays empty, so the next run retries them
  : > "$PKNOWN"; : > "$FAKE_CALLS"
  FAKE_CLAUDE_INSTALL_FAIL="beta" run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  grep -qxF "install failed: beta (retried next run)" "$LOG"
  assert_file_content "$PKNOWN" $'alpha\ndelta\n'
}

@test "update-plugins: a recorded profile that profiles.json lacks is named; without profiles.json nothing new is installed" {
  profile_fixture
  follow core gone
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  grep -qxF "recorded profile(s) not in profiles.json: gone" "$LOG"
  grep -qxF "claude plugin install delta@my-claude-skills" "$FAKE_CALLS"   # core still counts

  rm "$MP_DIR/profiles.json"
  profile_snapshot alpha beta
  snapshot alpha gamma
  : > "$FAKE_CALLS"
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  grep -qxF "profiles.json of the marketplace clone is missing or unreadable: installing no new plugins (profiles: core,gone)" "$LOG"
  refute grep -q "plugin install" "$FAKE_CALLS"
  grep -qxF "claude plugin update alpha@my-claude-skills" "$FAKE_CALLS"
  assert_file_content "$KNOWN" $'alpha\ngamma\n'
  grep -qxF "done" "$LOG"
}

@test "update-plugins: when none of the recorded profiles is in profiles.json, nothing new is installed or recorded" {
  profile_fixture
  follow gone renamed
  snapshot alpha gamma
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  assert_eq "$(grep -c '^recorded profile' "$LOG")" 1 "log lines about it"
  grep -qxF "recorded profile(s) not in profiles.json: gone,renamed: installing no new plugins" "$LOG"
  refute grep -q "plugin install" "$FAKE_CALLS"
  refute grep -q "^available" "$LOG"
  grep -qxF "claude plugin update alpha@my-claude-skills" "$FAKE_CALLS"   # installed plugins are still updated
  assert_file_content "$KNOWN" $'alpha\ngamma\n'   # beta, delta and epsilon stay undecided
  assert_file_content "$PKNOWN" $'alpha\nbeta\n'

  # the profile comes back (or is re-recorded): the undecided plugins are decided then
  follow core
  : > "$FAKE_CALLS"; : > "$LOG"
  run_update "$T/fake-claude-only:$T/sys" --force
  grep -qxF "new plugin: delta" "$LOG"
  grep -qxF "available (outside profiles core): epsilon" "$LOG"
}

@test "update-plugins: no recorded profile is today's behaviour, whatever else is in the config dir" {
  profile_fixture
  rm "$PROFILES"
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  assert_eq "$(grep '^claude plugin install' "$FAKE_CALLS")" "claude plugin install delta@my-claude-skills
claude plugin install epsilon@my-claude-skills" "installs"
  refute grep -q "^available" "$LOG"
  assert_file_content "$PKNOWN" $'alpha\nbeta\n'   # untouched without a record
}

@test "update-plugins: every Claude config dir has its own recorded profiles" {
  local cfg
  for cfg in work personal; do
    offers "$T/$cfg/plugins/marketplaces/my-claude-skills" alpha beta
    printf '%s\n' alpha beta > "$T/$cfg/plugins/my-claude-skills-known-plugins"
  done
  printf '{"profiles": {"core": ["alpha"], "other": ["beta", "delta"]}}\n' > "$T/work/plugins/marketplaces/my-claude-skills/profiles.json"
  printf 'core\n' > "$T/work/plugins/my-claude-skills-profiles"
  printf 'alpha\n' > "$T/work/plugins/my-claude-skills-profile-plugins"
  for cfg in work personal; do
    offers "$T/$cfg/plugins/marketplaces/my-claude-skills" alpha beta delta
    CLAUDE_CONFIG_DIR="$T/$cfg" run_update "$T/fake-claude-only:$T/sys" --force
    assert_status 0
  done
  assert_eq "$(grep -c '^claude plugin install delta@my-claude-skills$' "$FAKE_CALLS")" 1 "installs of delta (personal only)"
  grep -qxF "available (outside profiles core): delta" "$LOG"
}

@test "update-plugins: a failing plugin list installs nothing for a recorded profile either and keeps both snapshots" {
  profile_fixture
  FAKE_CLAUDE_LIST_RC=1 run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  refute grep -q "plugin install" "$FAKE_CALLS"
  refute grep -q "^available" "$LOG"
  assert_file_content "$KNOWN" $'alpha\nbeta\ngamma\n'
  assert_file_content "$PKNOWN" $'alpha\nbeta\n'
}

@test "update-plugins: recorded profiles under bash 3.2 (set BASH32=/path/to/bash-3.2)" {
  [ -n "${BASH32:-}" ] || skip "set BASH32=/path/to/bash-3.2 to run this"
  profile_fixture
  UPDATE_BASH="$BASH32" run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  grep -qxF "available (outside profiles core): epsilon" "$LOG"
  assert_file_content "$PKNOWN" $'alpha\nbeta\ndelta\n'
  refute grep -qE "command not found|unbound variable" "$LOG"

  # nothing available and nothing installed: empty arrays under set -u
  profiles_json '{"profiles": {"core": []}}'
  UPDATE_BASH="$BASH32" run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  refute grep -qE "command not found|unbound variable" "$LOG"
}

@test "update-plugins.ps1: the same recorded-profile rules (pwsh, or \$PWSH)" {
  local pwsh="${PWSH:-}"
  [ -n "$pwsh" ] || pwsh=$(command -v pwsh) || tool_missing "pwsh not installed (set PWSH=/path/to/pwsh to run this)"
  run_ps1() { run env PATH="$T/fake-claude-only:$T/sys" LOCALAPPDATA="$T/local" "$pwsh" -NoLogo -NoProfile -NonInteractive -File "$REPO_ROOT/scripts/update-plugins.ps1" -Force; }

  # delta is new in core and installed, epsilon is new outside it and listed; beta is a known member that stays out
  profile_fixture
  run_ps1
  assert_status 0
  assert_eq "$(grep '^claude plugin install' "$FAKE_CALLS")" "claude plugin install delta@my-claude-skills" "installs"
  assert_eq "$(cat "$PKNOWN")" $'alpha\nbeta\ndelta' "profile snapshot"
  assert_eq "$(cat "$KNOWN")" $'alpha\nbeta\ngamma\ndelta\nepsilon' "snapshot"
  grep -qxF "available (outside profiles core): epsilon" "$T/local/my-claude-skills/update.log"
  : > "$FAKE_CALLS"
  run_ps1
  refute grep -q "plugin install" "$FAKE_CALLS"

  # gamma moves into core: new for this config dir
  profiles_json '{"profiles": {"core": ["alpha", "beta", "delta", "gamma"], "other": ["epsilon"]}}'
  installed alpha delta
  run_ps1
  assert_eq "$(grep '^claude plugin install' "$FAKE_CALLS")" "claude plugin install gamma@my-claude-skills" "installs after the move"

  # no snapshot of the profile's plugins: recorded, nothing installed; no record: today's behaviour
  rm "$PKNOWN"; : > "$FAKE_CALLS"
  run_ps1
  refute grep -q "plugin install" "$FAKE_CALLS"
  assert_eq "$(cat "$PKNOWN")" $'alpha\nbeta\ngamma\ndelta' "recorded"
  rm "$PROFILES" "$KNOWN"; snapshot alpha beta gamma; : > "$FAKE_CALLS"
  run_ps1
  assert_eq "$(grep '^claude plugin install' "$FAKE_CALLS")" "claude plugin install epsilon@my-claude-skills" "installs without a record (delta is installed)"

  # profiles.json missing: nothing new is installed
  follow core; rm "$MP_DIR/profiles.json"; snapshot alpha gamma; : > "$FAKE_CALLS"
  run_ps1
  assert_status 0
  refute grep -q "plugin install" "$FAKE_CALLS"
  grep -qF "profiles.json of the marketplace clone is missing or unreadable: installing no new plugins (profiles: core)" "$T/local/my-claude-skills/update.log"

  # an empty snapshot of the profile's plugins is a snapshot (install.ps1: every plugin of the profile failed): its members that are not installed are new
  profiles_json '{"profiles": {"core": ["alpha", "beta"], "other": ["gamma"]}}'
  installed alpha
  : > "$PKNOWN"; : > "$FAKE_CALLS"
  run_ps1
  assert_status 0
  assert_eq "$(grep '^claude plugin install' "$FAKE_CALLS")" "claude plugin install beta@my-claude-skills" "installs from an empty snapshot"
  assert_eq "$(cat "$PKNOWN")" $'alpha\nbeta' "snapshot"

  # none of the recorded profiles is in profiles.json: nothing new is installed or recorded
  follow gone; snapshot alpha gamma; : > "$FAKE_CALLS"
  run_ps1
  assert_status 0
  refute grep -q "plugin install" "$FAKE_CALLS"
  grep -qF "recorded profile(s) not in profiles.json: gone: installing no new plugins" "$T/local/my-claude-skills/update.log"
  assert_eq "$(cat "$KNOWN")" $'alpha\ngamma' "undecided plugins stay out of the snapshot"
}
