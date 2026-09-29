# shellcheck shell=bash
# shellcheck disable=SC2154  # status, output: set by bats' run
# shellcheck disable=SC2016  # the $names in single-quoted jq programs are jq variables
# Shared helpers for the bats suites (plain bats-core, no helper libraries; bats 1.10 compatible).
#
# Every test works in $BATS_TEST_TMPDIR: a throwaway copy of the repo layout ($R) with the real
# scripts copied in, and fake upstream repos served over file:// URLs. Nothing touches the checkout,
# the network, ~/.claude or the global git config.

# Every fixture path hangs off BATS_TEST_TMPDIR (bats >= 1.4); never let it fall back to "" or "/".
[ -n "${BATS_TEST_TMPDIR:-}" ] && [ -d "$BATS_TEST_TMPDIR" ] || {
  echo "helpers.bash: BATS_TEST_TMPDIR is not set; bats-core >= 1.4 is required" >&2
  exit 1
}

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
export REPO_ROOT

# Fixture commits get a neutral identity from the environment. The user's global and system git config
# are neither read nor written: commit.gpgsign, hook.* or init.templateDir there would change or break
# every fixture commit.
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# A test started from inside a git hook would otherwise operate on the outer repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

# --- assertions (bats prints the test's output when one fails) ------------------------------------

assert_status() {
  [ "$status" -eq "$1" ] && return 0
  printf 'expected exit status %s, got %s\n--- output:\n%s\n' "$1" "$status" "$output"
  return 1
}

# assert_line TEXT: $output has a line that is exactly TEXT
assert_line() {
  grep -qxF -- "$1" <<<"$output" && return 0
  printf 'expected a line: %s\n--- output:\n%s\n' "$1" "$output"
  return 1
}

# refute_output_contains TEXT: TEXT appears nowhere in $output
refute_output_contains() {
  grep -qF -- "$1" <<<"$output" || return 0
  printf 'unexpected text in output: %s\n--- output:\n%s\n' "$1" "$output"
  return 1
}

# assert_output_contains TEXT: TEXT appears somewhere in $output
assert_output_contains() {
  grep -qF -- "$1" <<<"$output" && return 0
  printf 'expected text in output: %s\n--- output:\n%s\n' "$1" "$output"
  return 1
}

# assert_file_content FILE TEXT: FILE holds exactly TEXT (as printf '%s' writes it)
assert_file_content() {
  local actual
  [ -f "$1" ] || { echo "missing file: $1"; return 1; }
  if ! cmp -s "$1" <(printf '%s' "$2"); then
    actual=$(cat "$1")
    printf 'content mismatch in %s\n--- expected:\n%s\n--- actual:\n%s\n' "$1" "$2" "$actual"
    return 1
  fi
}

assert_exists()     { [ -e "$1" ] || { echo "expected to exist: $1"; return 1; }; }
assert_not_exists() { [ ! -e "$1" ] || { echo "expected not to exist: $1"; return 1; }; }

# assert_eq ACTUAL EXPECTED [WHAT]
assert_eq() {
  [ "$1" = "$2" ] && return 0
  printf '%s: expected [%s], got [%s]\n' "${3:-value}" "$2" "$1"
  return 1
}

# known_bug TEXT: skips a test that documents a bug in a script under test. The test body asserts the
# correct behaviour; RUN_KNOWN_BUGS=1 runs it anyway to show the failure. Delete the call with the fix.
known_bug() {
  [ -n "${RUN_KNOWN_BUGS:-}" ] || skip "KNOWN BUG: $*"
}

# tool_missing REASON: a check cannot run for lack of an optional tool. Skips the test, or fails it when
# SKILL_EXAMPLES_REQUIRE_TOOLS is set to anything but 0 (CI: every check must run), the rule of
# scripts/test-skill-examples.sh, its pytest suite and scripts/run-tests.sh.
tool_missing() {
  case ${SKILL_EXAMPLES_REQUIRE_TOOLS:-} in
    '' | 0) skip "$*" ;;
  esac
  echo "$* (SKILL_EXAMPLES_REQUIRE_TOOLS is set)"
  return 1
}

# need_tool TOOL...: tool_missing unless every TOOL is on PATH
need_tool() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || tool_missing "$t not installed" || return 1
  done
}

# --- fake upstream repositories ---------------------------------------------------------------------

# new_upstream NAME: empty repo at $T/up/NAME that, like GitHub, serves partial clones and fetches
# by sha (sync.sh --locked fetches the lockfile sha)
new_upstream() {
  local d="$T/up/$1"
  git init -q -b main "$d"
  git -C "$d" config uploadpack.allowFilter true
  git -C "$d" config uploadpack.allowAnySHA1InWant true
}

# commit_upstream NAME MESSAGE: commits the whole tree and prints the new sha
commit_upstream() {
  git -C "$T/up/$1" add -A
  git -C "$T/up/$1" commit -qm "$2"
  git -C "$T/up/$1" rev-parse HEAD
}

upstream_url() { printf 'file://%s/up/%s' "$T" "$1"; }

# put FILE TEXT: writes TEXT (printf '%s') to FILE, creating parent directories.
# rsync's quick check compares size and whole-second mtime, so a change a test syncs twice within
# one second must also change the file size (sync.sh uses rsync -a without --checksum).
put() {
  mkdir -p "$(dirname "$1")"
  printf '%s' "$2" > "$1"
}

# --- a throwaway copy of the repo layout ------------------------------------------------------------

# new_root: $R = git repo with the real scripts/sync.sh and scripts/gen-catalog.py (+ the skill_descriptions.py it imports), an empty
# sources.json, a marketplace.json with the plugins passed as arguments (./plugins/<name>) and the
# real .gitignore, committed once.
new_root() {
  R="$T/root"
  mkdir -p "$R/scripts" "$R/.claude-plugin" "$R/plugins"
  cp "$REPO_ROOT/scripts/sync.sh" "$REPO_ROOT/scripts/gen-catalog.py" "$REPO_ROOT/scripts/skill_descriptions.py" "$R/scripts/"
  cp "$REPO_ROOT/.gitignore" "$R/.gitignore"
  echo '{"sources": []}' > "$R/sources.json"
  write_marketplace "$@"
  git init -q -b main "$R"
  commit_root "initial layout"
}

# write_marketplace NAME...: .claude-plugin/marketplace.json listing ./plugins/NAME for each NAME
write_marketplace() {
  printf '%s\n' "$@" | jq -R . | jq -s '{name: "fixture", owner: {name: "test"},
    plugins: [.[] | select(. != "") | {name: ., source: ("./plugins/" + .), description: ("Plugin " + .)}]}' \
    > "$R/.claude-plugin/marketplace.json"
}

commit_root() {
  git -C "$R" add -A
  git -C "$R" commit -qm "$1"
}

# jq_edit FILE JQ-ARGS...: rewrites FILE in place with jq
jq_edit() {
  local f="$1"; shift
  jq "$@" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# add_source NAME UPSTREAM TRUST [REF]: appends a source that has no copy entries yet
add_source() {
  jq_edit "$R/sources.json" --arg n "$1" --arg r "$(upstream_url "$2")" --arg t "$3" --arg ref "${4:-main}" \
    '.sources += [{name: $n, repo: $r, ref: $ref, trust: $t, copy: []}]'
}

# add_copy SOURCE FROM TO [EXTRA-JSON]: appends a copy entry, e.g. '{"exclude": ["x"]}' or '{"patch": "p"}'
add_copy() {
  jq_edit "$R/sources.json" --arg n "$1" --arg f "$2" --arg to "$3" --argjson x "${4:-null}" \
    '(.sources[] | select(.name == $n) | .copy) += [{from: $f, to: $to} + ($x // {})]'
}

# set_patch SOURCE TO PATCH: sets (or with PATCH="" removes) the patch of that copy entry
set_patch() {
  if [ -n "$3" ]; then
    jq_edit "$R/sources.json" --arg n "$1" --arg to "$2" --arg p "$3" \
      '(.sources[] | select(.name == $n) | .copy[] | select(.to == $to)) .patch = $p'
  else
    jq_edit "$R/sources.json" --arg n "$1" --arg to "$2" \
      '(.sources[] | select(.name == $n) | .copy[] | select(.to == $to)) |= del(.patch)'
  fi
}

# run_sync ARGS...: runs the copied sync.sh; bats puts stdout+stderr in $output, the exit code in $status
run_sync() {
  run bash "$R/scripts/sync.sh" "$@"
}

lock_sha() { jq -r --arg n "$1" '.[$n].sha // empty' "$R/UPSTREAM.lock.json"; }

# worktree_clean [PATH...]: no staged, unstaged or untracked change (under PATH)
worktree_clean() {
  local st
  st=$(git -C "$R" status --porcelain -- "$@")
  [ -z "$st" ] && return 0
  printf 'worktree not clean:\n%s\n' "$st"
  return 1
}

# index_matches_head: the real index was not touched (no staged change, no unmerged entry)
index_matches_head() {
  git -C "$R" diff --cached --quiet || { echo "index differs from HEAD:"; git -C "$R" diff --cached --stat; return 1; }
  [ -z "$(git -C "$R" ls-files -u)" ] || { echo "unmerged index entries:"; git -C "$R" ls-files -u; return 1; }
}

# link_tools DIR TOOL...: DIR/TOOL -> the TOOL found on PATH, for a PATH with only these tools
link_tools() {
  local dir="$1" t p; shift
  mkdir -p "$dir"
  for t in "$@"; do
    p=$(command -v "$t") || continue
    ln -sf "$p" "$dir/$t"
  done
}

# refute CMD...: CMD must fail. (`! CMD` cannot fail a bats test: errexit ignores negated commands.)
refute() {
  if "$@"; then
    echo "expected to fail: $*"
    return 1
  fi
}
