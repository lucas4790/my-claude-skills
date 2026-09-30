#!/usr/bin/env bats
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
