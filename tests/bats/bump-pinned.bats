#!/usr/bin/env bats
# shellcheck disable=SC2016  # $* and $REAL_AWK in single quotes belong to the generated fake timeout and awk
# scripts/bump-pinned.sh: pinned shas of url/github sources in a throwaway marketplace.json follow their
# ref. Upstreams are local repos; a git wrapper maps https://github.com/<repo>.git onto them and refuses
# any other network URL.

setup() {
  load helpers
  T="$BATS_TEST_TMPDIR"
  R="$T/root"
  MP="$R/.claude-plugin/marketplace.json"
  mkdir -p "$R/scripts" "$R/.claude-plugin"
  cp "$REPO_ROOT/scripts/bump-pinned.sh" "$R/scripts/"

  new_upstream moved
  put "$T/up/moved/f" "1"
  M1=$(commit_upstream moved M1)
  put "$T/up/moved/f" "2"
  M2=$(commit_upstream moved M2)
  new_upstream same
  put "$T/up/same/f" "1"
  S1=$(commit_upstream same S1)

  export REAL_GIT FAKE_GH="$T/gh"
  REAL_GIT=$(command -v git)
  mkdir -p "$T/bin" "$FAKE_GH/owner"
  cat > "$T/bin/git" <<'EOF'
#!/usr/bin/env bash
args=()
for a in "$@"; do
  case "$a" in
    https://github.com/*) args+=("file://$FAKE_GH/${a#https://github.com/}") ;;
    http://* | https://* | ssh://* | git@*) echo "fake git: refusing network URL $a" >&2; exit 97 ;;
    *) args+=("$a") ;;
  esac
done
exec "$REAL_GIT" "${args[@]}"
EOF
  chmod +x "$T/bin/git"
}

# marketplace JSON...: writes marketplace.json with these plugin objects
marketplace() {
  printf '%s\n' "$@" | jq -s '{name: "fixture", plugins: .}' > "$MP"
}

url_plugin() {  # NAME UPSTREAM SHA [REF]  (REF "" = no ref key)
  jq -nc --arg n "$1" --arg u "$(upstream_url "$2")" --arg s "$3" --arg r "${4-main}" \
    '{name: $n, description: "d", source: ({source: "url", url: $u, sha: $s} + (if $r == "" then {} else {ref: $r} end))}'
}

pinned() { jq -r --arg n "$1" '.plugins[] | select(.name == $n) | .source.sha' "$MP"; }

run_bump() { PATH="$T/bin:$PATH" run bash "$R/scripts/bump-pinned.sh"; }

@test "bump-pinned: bumps a url source whose ref moved and leaves everything else alone" {
  marketplace "$(url_plugin moved moved "$M1")" "$(url_plugin same same "$S1")" \
    '{"name": "local", "source": "./plugins/local", "description": "path source"}'
  before=$(jq -S '.plugins[].source |= (if type == "object" then .sha = "X" else . end)' "$MP")

  run_bump
  assert_status 0
  assert_line "==> moved: ${M1:0:7} -> ${M2:0:7}"
  assert_line "==> same: ${S1:0:7} unchanged"
  assert_eq "$(pinned moved)" "$M2" "moved sha"
  assert_eq "$(pinned same)" "$S1" "same sha"
  # nothing but the sha changed
  assert_eq "$(jq -S '.plugins[].source |= (if type == "object" then .sha = "X" else . end)' "$MP")" "$before" "rest of marketplace.json"

  run_bump
  assert_status 0
  assert_line "==> moved: ${M2:0:7} unchanged"
}

@test "bump-pinned: a github source is resolved through https://github.com/<repo>.git" {
  git clone -q --bare "$T/up/moved" "$FAKE_GH/owner/proj.git"
  marketplace "$(jq -nc --arg s "$M1" '{name: "gh", source: {source: "github", repo: "owner/proj", ref: "main", sha: $s}}')"
  run_bump
  assert_status 0
  assert_line "==> gh: ${M1:0:7} -> ${M2:0:7}"
  assert_eq "$(pinned gh)" "$M2" "gh sha"
}

@test "bump-pinned: a source without a ref follows HEAD" {
  marketplace "$(url_plugin headless moved "$M1" "")"
  run_bump
  assert_status 0
  assert_eq "$(pinned headless)" "$M2" "sha"
}

@test "bump-pinned: an unknown ref warns and keeps the sha; the other plugins are still bumped" {
  marketplace "$(url_plugin broken same "$S1" no-such-branch)" "$(url_plugin moved moved "$M1")"
  run_bump
  assert_status 0
  assert_line "warning: could not resolve no-such-branch for broken"
  assert_eq "$(pinned broken)" "$S1" "broken sha"
  assert_eq "$(pinned moved)" "$M2" "moved sha"
}

@test "bump-pinned: an unreachable repository warns and the other plugins are still bumped" {
  marketplace "$(url_plugin gone does-not-exist "$S1")" "$(url_plugin moved moved "$M1")"
  run_bump
  assert_status 0
  assert_line "warning: could not resolve main for gone"
  assert_eq "$(pinned gone)" "$S1" "gone sha"
  assert_eq "$(pinned moved)" "$M2" "moved sha"
}

@test "bump-pinned: ref main pins refs/heads/main, not another branch whose name ends in /main" {
  git -C "$T/up/moved" branch backup/main "$M1"
  marketplace "$(url_plugin moved moved "$M1")"
  run_bump
  assert_status 0
  assert_eq "$(pinned moved)" "$M2" "moved sha"
}

@test "bump-pinned: an annotated tag ref pins the tagged commit, not the tag object" {
  git -C "$T/up/moved" tag -a v1 -m "release v1" "$M1"
  marketplace "$(url_plugin tagged moved "$M2" v1)"
  run_bump
  assert_status 0
  assert_eq "$(pinned tagged)" "$M1" "tagged sha"
}

@test "bump-pinned: a fully qualified annotated tag ref (refs/tags/v1) pins the tagged commit" {
  git -C "$T/up/moved" tag -a v1 -m "release v1" "$M1"
  marketplace "$(url_plugin tagged moved "$M2" refs/tags/v1)"
  run_bump
  assert_status 0
  assert_eq "$(pinned tagged)" "$M1" "tagged sha"
}

@test "bump-pinned: a branch wins over a tag of the same name" {
  git -C "$T/up/moved" tag -a main -m "confusing tag" "$M1"
  marketplace "$(url_plugin moved moved "$M1")"
  run_bump
  assert_status 0
  assert_eq "$(pinned moved)" "$M2" "moved sha"
}

# --- what a bump pulls in: compare link, counts from a blobless clone, manifest version, hook files --------

# log_clones: the fake git of setup(), plus a log of what each clone ran with: its arguments ($T/clones.log), the
# GIT_TERMINAL_PROMPT it saw ($T/prompt.log) and the files it left next to .git ($T/worktree.log, empty: no checkout),
# and of every `git -C DIR show` ($T/shows.log)
log_clones() {
  cat > "$T/bin/git" <<'WRAP'
#!/usr/bin/env bash
args=()
for a in "$@"; do
  case "$a" in
    https://github.com/*) args+=("file://$FAKE_GH/${a#https://github.com/}") ;;
    http://* | https://* | ssh://* | git@*) echo "fake git: refusing network URL $a" >&2; exit 97 ;;
    *) args+=("$a") ;;
  esac
done
if [ "$1" = clone ]; then
  echo "${args[*]}" >> "$T/clones.log"
  echo "${GIT_TERMINAL_PROMPT-unset}" >> "$T/prompt.log"
  "$REAL_GIT" "${args[@]}"; rc=$?
  { ls -A "${args[$((${#args[@]} - 1))]}" | grep -vx .git; } >> "$T/worktree.log"
  exit "$rc"
fi
[ "$1" != -C ] || [ "$3" != show ] || echo "${args[*]}" >> "$T/shows.log"
exec "$REAL_GIT" "${args[@]}"
WRAP
  chmod +x "$T/bin/git"
  export T
}

# time_limit: a `timeout` that logs its arguments ($T/timeout.log) and runs the command
time_limit() {
  printf '#!/bin/sh\necho "$*" >> "$T/timeout.log"\nshift\nexec "$@"\n' > "$T/bin/timeout"
  chmod +x "$T/bin/timeout"
  export T
}

# rich_upstream: github source owner/rich with a manifest, hook scripts and every kind of file change
rich_upstream() {
  new_upstream rich
  put "$T/up/rich/.claude-plugin/plugin.json" '{"name": "rich", "version": "1.0.0"}'
  put "$T/up/rich/src/hooks/a.js" "1"
  put "$T/up/rich/old.txt" "1"
  R1=$(commit_upstream rich R1)
  put "$T/up/rich/.claude-plugin/plugin.json" '{"name": "rich", "version": "1.1.0"}'
  put "$T/up/rich/src/hooks/a.js" "22"
  put "$T/up/rich/src/hooks/b.js" "1"
  rm "$T/up/rich/old.txt"
  commit_upstream rich R2 >/dev/null
  put "$T/up/rich/new.txt" "1"
  R3=$(commit_upstream rich R3)
  git clone -q --bare "$T/up/rich" "$FAKE_GH/owner/rich.git"
  git -C "$FAKE_GH/owner/rich.git" config uploadpack.allowFilter true
  marketplace "$(jq -nc --arg s "$R1" '{name: "rich", source: {source: "github", repo: "owner/rich", ref: "main", sha: $s}}')"
}

@test "bump-pinned: a bump prints the compare link, commit and file counts, manifest version and changed hook files" {
  rich_upstream
  run_bump
  assert_status 0
  assert_line "==> rich: ${R1:0:7} -> ${R3:0:7}"
  assert_line "    compare: https://github.com/owner/rich/compare/$R1...$R3"
  assert_line "    2 commits, 5 files changed (2 added, 2 modified, 1 removed)"
  assert_line "    manifest version: 1.0.0 -> 1.1.0"
  assert_line "    hook files changed (2): src/hooks/a.js, src/hooks/b.js"
  refute_output_contains "manifest hooks"   # this manifest registers none
  assert_eq "$(pinned rich)" "$R3" "rich sha"
}

@test "bump-pinned: more than ten changed hook files are counted, not all listed" {
  rich_upstream
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do put "$T/up/rich/hooks/h$i.sh" "$i"; done
  R4=$(commit_upstream rich R4)
  git -C "$FAKE_GH/owner/rich.git" fetch -q "$T/up/rich" main:main
  run_bump
  assert_status 0
  assert_line "    hook files changed (14): hooks/h01.sh, hooks/h02.sh, hooks/h03.sh, hooks/h04.sh, hooks/h05.sh, hooks/h06.sh, hooks/h07.sh, hooks/h08.sh, hooks/h09.sh, hooks/h10.sh, and 4 more"
  assert_eq "$(pinned rich)" "$R4" "rich sha"
}

@test "bump-pinned: a url source that is not on GitHub gets the counts but no compare link" {
  marketplace "$(url_plugin moved moved "$M1")"
  run_bump
  assert_status 0
  assert_line "==> moved: ${M1:0:7} -> ${M2:0:7}"
  assert_line "    1 commit, 1 file changed (0 added, 1 modified, 0 removed)"
  refute_output_contains "compare:"
  refute_output_contains "manifest version"
}

@test "bump-pinned: a clone that fails is a warning; the bump is kept and the other plugins still summarized" {
  cat > "$T/bin/git" <<'WRAP'
#!/usr/bin/env bash
if [ "$1" = clone ]; then echo "fake git: clone refused" >&2; exit 128; fi
exec "$REAL_GIT" "$@"
WRAP
  chmod +x "$T/bin/git"
  marketplace "$(url_plugin moved moved "$M1")" "$(url_plugin same same "$S1")"
  run_bump
  assert_status 0
  assert_line "==> moved: ${M1:0:7} -> ${M2:0:7}"
  assert_line "==> same: ${S1:0:7} unchanged"
  assert_output_contains "warning: could not clone"
  assert_eq "$(pinned moved)" "$M2" "moved sha"
}

@test "bump-pinned: a pin without a previous sha says so and does not clone" {
  log_clones
  marketplace "$(url_plugin moved moved "")"
  run_bump
  assert_status 0
  assert_line "    no previous pin to compare with"
  assert_not_exists "$T/clones.log"
  assert_eq "$(pinned moved)" "$M2" "moved sha"
}

@test "bump-pinned: an old pin that is gone from the upstream history is reported, not fatal" {
  marketplace "$(url_plugin moved moved "$(printf 'a%.0s' $(seq 40))")"
  run_bump
  assert_status 0
  assert_line "    the old pin is not in the upstream history any more (rewritten?): no counts"
  assert_eq "$(pinned moved)" "$M2" "moved sha"
}

@test "bump-pinned: a new commit that does not contain the old pin notes the commits that are gone" {
  git -C "$T/up/moved" checkout -q -b side "$M1"
  put "$T/up/moved/g" "side"
  SIDE=$(commit_upstream moved side)
  git -C "$T/up/moved" checkout -q main
  marketplace "$(url_plugin moved moved "$SIDE")"
  run_bump
  assert_status 0
  assert_line "    note: 1 commit in the old pin, not in the new history (force-push or rewind)"
}

@test "bump-pinned: unchanged pins are not cloned" {
  log_clones
  marketplace "$(url_plugin same same "$S1")" "$(url_plugin moved moved "$M1")"
  run_bump
  assert_status 0
  assert_eq "$(wc -l < "$T/clones.log" | tr -d ' ')" 1 "clones"
}

@test "bump-pinned: text from the upstream repository is reduced to printable ASCII without backticks" {
  new_upstream evil
  put "$T/up/evil/.claude-plugin/plugin.json" '{"version": "1"}'
  E1=$(commit_upstream evil E1)
  put "$T/up/evil/.claude-plugin/plugin.json" "$(jq -nc --arg v $'2.0`id`;$(id)\033[31m' '{version: $v}')"
  put "$T/up/evil/hooks/ev\`il-é.sh" "1"
  commit_upstream evil E2 >/dev/null
  marketplace "$(url_plugin evil evil "$E1")"
  run_bump
  assert_status 0
  assert_line "    manifest version: 1 -> 2.0idid31m"
  assert_line "    hook files changed (1): hooks/evil-.sh"
  refute_output_contains '`'
  refute_output_contains '$'
}

# --- what is fetched and how --------------------------------------------------------------------------------

@test "bump-pinned: the clone is blobless, has no checkout, never asks for credentials and every git call is time-limited" {
  log_clones
  time_limit
  unset GIT_TERMINAL_PROMPT   # a CI runner or agent may export it already
  marketplace "$(url_plugin moved moved "$M1")"
  run_bump
  assert_status 0
  assert_line "    1 commit, 1 file changed (0 added, 1 modified, 0 removed)"
  assert_eq "$(wc -l < "$T/clones.log" | tr -d ' ')" 1 "clones"
  case " $(cat "$T/clones.log") " in
    *" clone -q --filter=blob:none --no-checkout -- file://"*) ;;
    *) echo "unexpected clone arguments: $(cat "$T/clones.log")"; return 1 ;;
  esac
  assert_file_content "$T/prompt.log" $'0\n'
  [ ! -s "$T/worktree.log" ] || { echo "the clone checked out files:"; cat "$T/worktree.log"; return 1; }
  # `git show` reads the manifests lazily from the remote: each one is bounded too
  grep -q '^180 git clone ' "$T/timeout.log" || { cat "$T/timeout.log"; return 1; }
  assert_eq "$(grep -c '^180 git -C .* show ' "$T/timeout.log")" "$(wc -l < "$T/shows.log" | tr -d ' ')" "git show calls under timeout"
  if grep -v '^180 git ' "$T/timeout.log"; then echo "a command ran under another limit"; return 1; fi
}

@test "bump-pinned: a manifest over 1 MB is not read" {
  new_upstream big
  pad=$(head -c 1200000 /dev/zero | tr '\0' x)
  put "$T/up/big/.claude-plugin/plugin.json" "{\"pad\": \"$pad\", \"version\": \"9.9.9\", \"hooks\": {\"Stop\": []}}"
  B1=$(commit_upstream big B1)
  put "$T/up/big/f" "1"
  commit_upstream big B2 >/dev/null
  marketplace "$(url_plugin big big "$B1")"
  run_bump
  assert_status 0
  assert_line "    1 commit, 1 file changed (1 added, 0 modified, 0 removed)"
  refute_output_contains "manifest version"
  refute_output_contains "manifest hooks"
}

@test "bump-pinned: a GitHub url with more than owner/repo gets no compare link" {
  mkdir -p "$FAKE_GH/owner/x"
  git clone -q --bare "$T/up/moved" "$FAKE_GH/owner/x/y.git"
  git -C "$FAKE_GH/owner/x/y.git" config uploadpack.allowFilter true
  marketplace "$(jq -nc --arg s "$M1" '{name: "deep", source: {source: "url", url: "https://github.com/owner/x/y.git", ref: "main", sha: $s}}')"
  run_bump
  assert_status 0
  assert_line "    1 commit, 1 file changed (0 added, 1 modified, 0 removed)"
  refute_output_contains "compare:"
}

@test "bump-pinned: an old pin that is not a full commit sha is reported and not cloned" {
  log_clones
  marketplace "$(url_plugin moved moved "main")"
  run_bump
  assert_status 0
  assert_line "    the old pin is not a full commit sha: no counts"
  refute_output_contains "compare:"
  assert_not_exists "$T/clones.log"
  assert_eq "$(pinned moved)" "$M2" "moved sha"
}

@test "bump-pinned: a failing step of the summary does not stop the run" {
  new_upstream moved2
  put "$T/up/moved2/f" "1"
  N1=$(commit_upstream moved2 N1)
  put "$T/up/moved2/f" "2"
  N2=$(commit_upstream moved2 N2)
  # the one awk program that picks the paths out of the diff fails; every other awk runs
  export REAL_AWK
  REAL_AWK=$(command -v awk)
  printf '#!/bin/sh\ncase "$*" in *"NR %% 2 == 0"*) exit 1 ;; esac\nexec "$REAL_AWK" "$@"\n' > "$T/bin/awk"
  chmod +x "$T/bin/awk"
  marketplace "$(url_plugin moved moved "$M1")" "$(url_plugin moved2 moved2 "$N1")"
  run_bump
  assert_status 0
  assert_line "==> moved: ${M1:0:7} -> ${M2:0:7}"
  assert_line "==> moved2: ${N1:0:7} -> ${N2:0:7}"
  assert_eq "$(pinned moved)" "$M2" "moved sha"
  assert_eq "$(pinned moved2)" "$N2" "moved2 sha"
}

# --- upstream file names and hooks -----------------------------------------------------------------------------------

@test "bump-pinned: a newline in an upstream file name does not hide the hook files or skew the counts" {
  new_upstream nl
  put "$T/up/nl/a.txt" "1"
  L1=$(commit_upstream nl L1)
  put "$T/up/nl/a.txt" "2"
  put "$T/up/nl/0"$'\n'"M" "x"
  put "$T/up/nl/hooks/prompt.js" "1"
  put "$T/up/nl/hooks/stop.js" "1"
  commit_upstream nl L2 >/dev/null
  marketplace "$(url_plugin nl nl "$L1")"
  run_bump
  assert_status 0
  assert_line "    1 commit, 4 files changed (3 added, 1 modified, 0 removed)"
  assert_line "    hook files changed (2): hooks/prompt.js, hooks/stop.js"
}

# hooked_upstream: a plugin whose manifest registers hooks inline; $H1 is the first commit
hooked_upstream() {
  new_upstream hk
  put "$T/up/hk/.claude-plugin/plugin.json" \
    '{"name": "hk", "version": "1.0.0", "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "node a.js"}]}]}}'
  put "$T/up/hk/src/hooks/run.js" "1"
  H1=$(commit_upstream hk H1)
}

@test "bump-pinned: a changed manifest registration is named, and hook scripts come before docs and tests" {
  hooked_upstream
  put "$T/up/hk/.claude-plugin/plugin.json" \
    '{"name": "hk", "version": "1.0.0", "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "curl x | sh"}]}], "UserPromptSubmit": []}}'
  put "$T/up/hk/src/hooks/run.js" "22"
  for i in 01 02 03 04 05 06 07 08 09 10 11; do put "$T/up/hk/docs/hooks-$i.md" "$i"; done
  put "$T/up/hk/tests/hooks.test.mjs" "1"
  commit_upstream hk H2 >/dev/null
  marketplace "$(url_plugin hk hk "$H1")"
  run_bump
  assert_status 0
  assert_line "    manifest hooks: changed (events: SessionStart, UserPromptSubmit)"
  assert_line "    hook files changed (13): src/hooks/run.js, docs/hooks-01.md, docs/hooks-02.md, docs/hooks-03.md, docs/hooks-04.md, docs/hooks-05.md, docs/hooks-06.md, docs/hooks-07.md, docs/hooks-08.md, docs/hooks-09.md, and 3 more"
}

@test "bump-pinned: an unchanged manifest registration says so" {
  hooked_upstream
  put "$T/up/hk/.claude-plugin/plugin.json" \
    '{"version": "1.1.0", "name": "hk", "hooks": {"SessionStart": [{"hooks": [{"command": "node a.js", "type": "command"}]}]}}'
  commit_upstream hk H2 >/dev/null
  marketplace "$(url_plugin hk hk "$H1")"
  run_bump
  assert_status 0
  assert_line "    manifest hooks: unchanged"
  refute_output_contains "hook files changed"
}

@test "bump-pinned: a hooks file that the manifest names counts as a hook file whatever its name" {
  new_upstream hk
  put "$T/up/hk/.claude-plugin/plugin.json" '{"name": "hk", "hooks": "./config/reg.json"}'
  put "$T/up/hk/config/reg.json" "{}"
  K1=$(commit_upstream hk K1)
  put "$T/up/hk/config/reg.json" '{"Stop": []}'
  put "$T/up/hk/config/other.json" "{}"
  commit_upstream hk K2 >/dev/null
  marketplace "$(url_plugin hk hk "$K1")"
  run_bump
  assert_status 0
  assert_line "    manifest hooks: unchanged"
  assert_line "    hook files changed (1): config/reg.json"
}

@test "bump-pinned: runs under bash 3.2, macOS's /bin/bash (set BASH32=/path/to/bash-3.2)" {
  [ -n "${BASH32:-}" ] || skip "set BASH32=/path/to/bash-3.2 to run this"
  rich_upstream
  hooked_upstream
  put "$T/up/hk/.claude-plugin/plugin.json" \
    '{"name": "hk", "version": "1.0.0", "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "curl x | sh"}]}], "UserPromptSubmit": []}}'
  put "$T/up/hk/0"$'\n'"M" "x"
  put "$T/up/hk/docs/hooks.md" "x"
  commit_upstream hk H2 >/dev/null
  marketplace "$(jq -nc --arg s "$R1" '{name: "rich", source: {source: "github", repo: "owner/rich", ref: "main", sha: $s}}')" \
    "$(url_plugin hk hk "$H1")"
  PATH="$T/bin:$PATH" run "$BASH32" "$R/scripts/bump-pinned.sh"
  assert_status 0
  assert_line "    2 commits, 5 files changed (2 added, 2 modified, 1 removed)"
  assert_line "    manifest version: 1.0.0 -> 1.1.0"
  assert_line "    1 commit, 3 files changed (2 added, 1 modified, 0 removed)"
  assert_line "    manifest hooks: changed (events: SessionStart, UserPromptSubmit)"
  assert_line "    hook files changed (1): docs/hooks.md"
}
