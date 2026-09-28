#!/usr/bin/env bats
# shellcheck disable=SC2016  # $* and $FAKE_CALLS belong to the generated fake script
# scripts/update-plugins.sh: throttling, --force, missing tools, and the update/install loop.
# claude and copilot are fakes that log their arguments; HOME, the caches and CLAUDE_CONFIG_DIR are
# temp dirs, and PATH holds only the fakes plus symlinks to the system tools the script needs, so the
# real CLIs and ~/.claude are never touched.

setup() {
  load helpers
  T="$BATS_TEST_TMPDIR"
  SCRIPT="$REPO_ROOT/scripts/update-plugins.sh"
  export HOME="$T/home" XDG_CACHE_HOME="$T/cache" XDG_CONFIG_HOME="$T/config" CLAUDE_CONFIG_DIR="$T/claude"
  unset MY_CLAUDE_SKILLS_INTERVAL MY_CLAUDE_SKILLS_ATTRIBUTION COPILOT_HOME
  mkdir -p "$HOME"
  CACHE="$XDG_CACHE_HOME/my-claude-skills"
  STAMP="$CACHE/last-run"
  LOG="$CACHE/update.log"
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
  "plugin list --json") cat "$FAKE_STATE/claude-installed.json" ;;
  "plugin update alpha@"*) echo "alpha is already up to date" ;;
  "plugin update "*) echo "updated ${3%@*} to 2.0.0" ;;
  "plugin install "*) echo "installed ${3%@*}" ;;
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

  local tools=(bash sh env mkdir date stat touch grep cat sed tr head)
  link_tools "$T/sys" "${tools[@]}" jq
  link_tools "$T/sys-nojq" "${tools[@]}"
}

# run_update PATH-DIRS ARGS...: runs the real script with PATH set to PATH-DIRS only
run_update() {
  local path="$1"; shift
  run env PATH="$path" "$BASH" "$SCRIPT" "$@"
}

calls() { cat "$FAKE_CALLS" 2>/dev/null; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
# age FILE SECONDS: sets FILE's mtime SECONDS in the past (portable, no GNU touch -d)
age() { python3 -c 'import os, sys, time; t = time.time() - int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"; }

@test "update-plugins: --force refreshes the marketplace, updates installed plugins, installs new ones" {
  run_update "$T/fake-claude-only:$T/sys" --force
  assert_status 0
  assert_eq "$output" "" "stdout/stderr (everything goes to the log)"
  assert_eq "$(calls)" "claude plugin marketplace update my-claude-skills
claude plugin list --json
claude plugin update alpha@my-claude-skills
claude plugin install beta@my-claude-skills
claude plugin update gamma@my-claude-skills" "claude calls"
  grep -qxF "new plugin: beta" "$LOG"
  grep -qxF "updated gamma to 2.0.0" "$LOG"
  refute grep -q "already up to date" "$LOG"
  grep -qxF "done" "$LOG"
  grep -qE '^=== [0-9]{4}-[0-9]{2}-[0-9]{2}T' "$LOG"
  assert_exists "$STAMP"
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
  assert_eq "$(grep -c '^claude ' "$FAKE_CALLS")" "5" "claude calls"
}

@test "update-plugins: a stamp younger than the interval exits 0 without doing anything" {
  mkdir -p "$CACHE"
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
  mkdir -p "$CACHE"
  touch "$STAMP"
  age "$STAMP" 120
  before=$(mtime "$STAMP")
  MY_CLAUDE_SKILLS_INTERVAL=60 run_update "$T/fake-claude-only:$T/sys"
  assert_status 0
  grep -qxF "claude plugin marketplace update my-claude-skills" "$FAKE_CALLS"
  [ "$(mtime "$STAMP")" -gt "$before" ]
}

@test "update-plugins: the same stamp is still fresh under the default interval (6 h)" {
  mkdir -p "$CACHE"
  touch "$STAMP"
  age "$STAMP" 120
  run_update "$T/fake-claude-only:$T/sys"
  assert_status 0
  assert_not_exists "$FAKE_CALLS"
}

@test "update-plugins: --force ignores a fresh stamp" {
  mkdir -p "$CACHE"
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
