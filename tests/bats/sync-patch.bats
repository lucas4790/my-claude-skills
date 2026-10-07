#!/usr/bin/env bats
# scripts/sync.sh "patch" support: plain apply, the 3-way fallback, conflicts, broken and missing
# patches, --locked. The patches are made the documented way (README, "Patching vendored files"):
# vendor pure upstream, commit, edit the vendored files and `git diff` them.

# skill_md L2 L4 L9 L10: a SKILL.md whose lines 6, 8, 13 and 14 are the arguments
skill_md() {
  printf -- '---\nname: demo\ndescription: Demo skill. Use when testing patches.\n---\nline 1\n%s\nline 3\n%s\nline 5\nline 6\nline 7\nline 8\n%s\n%s\n' "$@"
}
# extra_txt X3 X5
extra_txt() { printf 'x1\nx2\n%s\nx4\n%s\nx6\nx7\nx8\nx9\nx10\n' "$@"; }
# sed_file SCRIPT FILE: edits FILE in place (portable: GNU and BSD/macOS sed disagree on -i)
sed_file() { sed "$1" "$2" > "$2.tmp" && mv "$2.tmp" "$2"; }

setup() {
  load helpers
  T="$BATS_TEST_TMPDIR"
  new_root fake multi plain
  F="$R/plugins/fake/skills/demo/SKILL.md"
  M="$R/plugins/multi/skills/m"

  new_upstream up-a
  put "$T/up/up-a/skills/demo/SKILL.md" "$(skill_md "line 2" "line 4 original" "line 9" "line 10")"
  put "$T/up/up-a/LICENSE" "license a"
  A1=$(commit_upstream up-a A1)
  new_upstream up-c
  put "$T/up/up-c/skills/m/extra.txt" "$(extra_txt x3 x5)"
  put "$T/up/up-c/skills/m/drop.txt" "dropped by the patch"
  commit_upstream up-c C1 >/dev/null
  new_upstream up-b
  put "$T/up/up-b/skills/other/SKILL.md" $'---\nname: other\ndescription: Other skill. Use when testing patches.\n---\nother v1\n'
  B1=$(commit_upstream up-b B1)

  add_source fake-patched up-a low
  add_copy fake-patched skills/demo plugins/fake/skills/demo
  add_copy fake-patched LICENSE plugins/fake/LICENSE
  add_source fake-multi up-c low
  add_copy fake-multi skills/m plugins/multi/skills/m
  add_source fake-plain up-b high
  add_copy fake-plain skills/other plugins/plain/skills/other

  # vendor pure upstream, then derive the patches from local edits
  run_sync
  assert_status 0
  commit_root "vendor pure upstream"
  mkdir -p "$R/patches"
  sed_file 's/^line 4 original$/line 4 PATCHED by us/' "$F"
  git -C "$R" diff -- plugins/fake > "$R/patches/fake.patch"
  sed_file 's/^x5$/x5 PATCHED by us/' "$M/extra.txt"
  rm "$M/drop.txt"
  put "$M/new.txt" "added by the patch"
  git -C "$R" add -A plugins/multi
  git -C "$R" diff --cached -- plugins/multi > "$R/patches/multi.patch"
  git -C "$R" reset -q -- plugins/multi
  git -C "$R" checkout -q -- plugins
  git -C "$R" clean -fdq -- plugins
  set_patch fake-patched plugins/fake/skills/demo patches/fake.patch
  set_patch fake-multi plugins/multi/skills/m patches/multi.patch
  commit_root "add patches"
}

# sync_and_commit: a successful full sync whose result becomes HEAD
sync_and_commit() {
  run_sync
  assert_status 0
  commit_root "sync"
}

expected_msg() { printf 'error: patches/fake.patch no longer applies to fake-patched@%s; refresh it (see README)' "${1:0:7}"; }

@test "patch: applies with plain git apply once the copies are written" {
  run_sync
  assert_status 0
  assert_line "    patch patches/fake.patch"
  assert_line "    patch patches/multi.patch"
  assert_file_content "$F" "$(skill_md "line 2" "line 4 PATCHED by us" "line 9" "line 10")"
  cmp "$R/plugins/fake/LICENSE" "$T/up/up-a/LICENSE"
  assert_eq "$(lock_sha fake-patched)" "$A1" "lock sha"
  index_matches_head
}

@test "patch: a patch that modifies, deletes and creates files" {
  run_sync --only fake-multi
  assert_status 0
  assert_file_content "$M/extra.txt" "$(extra_txt x3 "x5 PATCHED by us")"
  assert_not_exists "$M/drop.txt"
  assert_file_content "$M/new.txt" "added by the patch"
}

@test "patch: running twice leaves the patched tree byte-identical" {
  sync_and_commit
  run_sync
  assert_status 0
  worktree_clean
}

@test "patch: 3-way fallback when upstream changed a nearby line (base blob in history)" {
  sync_and_commit
  # line 2 is in the hunk's context: plain `git apply` fails, a 3-way merge does not
  put "$T/up/up-a/skills/demo/SKILL.md" "$(skill_md "line 2 changed upstream" "line 4 original" "line 9" "line 10")"
  A2=$(commit_upstream up-a A2)

  run_sync --only fake-patched
  assert_status 0
  assert_line "    patch patches/fake.patch (3-way merge)"
  assert_file_content "$F" "$(skill_md "line 2 changed upstream" "line 4 PATCHED by us" "line 9" "line 10")"
  assert_eq "$(lock_sha fake-patched)" "$A2" "lock sha"
  index_matches_head
  refute grep -rq '^<<<<<<<' "$R/plugins/fake"
  commit_root "sync A2"

  # and it stays stable
  run_sync --only fake-patched
  assert_status 0
  worktree_clean
}

@test "patch: 3-way fallback with a modify+delete+create patch" {
  sync_and_commit
  put "$T/up/up-c/skills/m/extra.txt" "$(extra_txt "x3 changed upstream" x5)"
  commit_upstream up-c C2 >/dev/null
  run_sync --only fake-multi
  assert_status 0
  assert_line "    patch patches/multi.patch (3-way merge)"
  assert_file_content "$M/extra.txt" "$(extra_txt "x3 changed upstream" "x5 PATCHED by us")"
  assert_not_exists "$M/drop.txt"
  assert_file_content "$M/new.txt" "added by the patch"
  index_matches_head
}

@test "patch: without the base blob (shallow clone, as in CI) the 3-way fallback fails the source" {
  sync_and_commit
  put "$T/up/up-a/skills/demo/SKILL.md" "$(skill_md "line 2 changed upstream" "line 4 original" "line 9" "line 10")"
  A2=$(commit_upstream up-a A2)
  git clone -q --depth 1 "file://$R" "$T/ci"
  run bash "$T/ci/scripts/sync.sh" --only fake-patched
  assert_status 1
  assert_line "$(expected_msg "$A2")"
  [ -z "$(git -C "$T/ci" status --porcelain -- plugins)" ]
}

@test "patch: a conflicting patch fails the source, restores its files and leaves the index alone" {
  sync_and_commit
  # upstream rewrote the patched line itself
  put "$T/up/up-a/skills/demo/SKILL.md" "$(skill_md "line 2" "line 4 rewritten upstream" "line 9" "line 10")"
  A2=$(commit_upstream up-a A2)
  put "$T/up/up-b/skills/other/SKILL.md" $'---\nname: other\ndescription: Other skill. Use when testing patches.\n---\nother v2, longer\n'
  B2=$(commit_upstream up-b B2)

  run_sync
  assert_status 1
  assert_line "$(expected_msg "$A2")"
  assert_line "==> FAILED sources: fake-patched"
  cmp "$F" <(git -C "$R" show "HEAD:plugins/fake/skills/demo/SKILL.md")
  refute grep -rqE '^(<<<<<<<|>>>>>>>)' "$R/plugins"
  worktree_clean plugins/fake
  index_matches_head
  assert_eq "$(lock_sha fake-patched)" "$A1" "fake-patched lock sha"
  # the other sources still synced
  assert_eq "$(lock_sha fake-plain)" "$B2" "fake-plain lock sha"
  cmp "$R/plugins/plain/skills/other/SKILL.md" "$T/up/up-b/skills/other/SKILL.md"
}

@test "patch: a corrupted patch fails the source (normal and --locked)" {
  sync_and_commit
  sed_file 's/^ line 3$/ line 3 CORRUPT/' "$R/patches/fake.patch"
  refute cmp -s "$R/patches/fake.patch" <(git -C "$R" show HEAD:patches/fake.patch)

  run_sync --only fake-patched
  assert_status 1
  assert_line "$(expected_msg "$A1")"
  worktree_clean plugins
  index_matches_head

  put "$T/up/up-a/LICENSE" "license a, version 2"
  commit_upstream up-a A2 >/dev/null
  run_sync --locked --only fake-patched
  assert_status 1
  assert_line "$(expected_msg "$A1")"
  worktree_clean plugins
}

@test "patch: a missing patch file fails the source before anything is cloned" {
  sync_and_commit
  lock_before=$(jq -c '."fake-patched"' "$R/UPSTREAM.lock.json")
  set_patch fake-patched plugins/fake/skills/demo patches/does-not-exist.patch
  real_git=$(command -v git)
  mkdir -p "$T/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$T/git.log" "$real_git" > "$T/bin/git"
  chmod +x "$T/bin/git"

  PATH="$T/bin:$PATH" run_sync
  assert_status 1
  assert_line "error: fake-patched: patch file patches/does-not-exist.patch not found"
  assert_line "==> FAILED sources: fake-patched"
  refute_output_contains "==> fake-patched"
  refute grep -q "up/up-a" "$T/git.log"
  grep -q "clone .*up/up-b" "$T/git.log"
  grep -q "clone .*up/up-c" "$T/git.log"
  assert_eq "$(jq -c '."fake-patched"' "$R/UPSTREAM.lock.json")" "$lock_before" "lock entry"
  worktree_clean plugins

  : > "$T/git.log"
  PATH="$T/bin:$PATH" run_sync --locked --only fake-patched
  assert_status 1
  assert_line "error: fake-patched: patch file patches/does-not-exist.patch not found"
  refute grep -qE '(^| )(init|clone|fetch)( |$)' "$T/git.log"
}

@test "patch: --locked applies the patch on the locked sha" {
  sync_and_commit
  put "$T/up/up-a/skills/demo/SKILL.md" "$(skill_md "line 2" "line 4 original" "line 9 moved on upstream" "line 10")"
  commit_upstream up-a A2 >/dev/null
  put "$F" "local garbage"

  run_sync --locked
  assert_status 0
  assert_line "==> fake-patched ($(upstream_url up-a) @ ${A1:0:7}, locked)"
  assert_line "    patch patches/fake.patch"
  assert_file_content "$F" "$(skill_md "line 2" "line 4 PATCHED by us" "line 9" "line 10")"
  assert_eq "$(lock_sha fake-patched)" "$A1" "lock sha"
  worktree_clean
}

@test "patch: a source without a patch key is unaffected by the others' patches" {
  run_sync --only fake-plain
  assert_status 0
  refute_output_contains "    patch "
  cmp "$R/plugins/plain/skills/other/SKILL.md" "$T/up/up-b/skills/other/SKILL.md"
  assert_eq "$(lock_sha fake-plain)" "$B1" "lock sha"
}

@test "patch: a file the patch creates at an excluded path is rebuilt on every sync" {
  sync_and_commit
  assert_file_content "$M/new.txt" "added by the patch"
  # upstream has no new.txt, but the entry excludes it: the leftover goes before the patch creates it again
  jq_edit "$R/sources.json" '(.sources[] | select(.name == "fake-multi") | .copy[0].exclude) = ["new.txt"]'
  run_sync --only fake-multi
  assert_status 0
  assert_line "    patch patches/multi.patch"
  assert_file_content "$M/new.txt" "added by the patch"
  index_matches_head
  commit_root "exclude new.txt"
  run_sync --only fake-multi
  assert_status 0
  worktree_clean
}

# pv_stamp: the version of the patched plugin's manifest
pv_stamp() { jq -r .version "$R/plugins/pv/.claude-plugin/plugin.json"; }

@test "patch: the version is stamped after the patches, so a patch to the manifest next to its version line applies" {
  new_upstream up-p
  put "$T/up/up-p/plugins/pv/.claude-plugin/plugin.json" $'{\n  "name": "pv",\n  "version": "2.0.0",\n  "description": "Plugin pv",\n  "skills": ["./skills/"]\n}\n'
  put "$T/up/up-p/plugins/pv/skills/p/SKILL.md" $'---\nname: p\ndescription: Skill p. Use when testing patches.\n---\nline 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\n'
  commit_upstream up-p P1 >/dev/null
  add_source fake-pv up-p low
  add_copy fake-pv plugins/pv plugins/pv
  run_sync --only fake-pv
  assert_status 0
  commit_root "vendor pure upstream, stamped"
  unpatched=$(pv_stamp)
  [[ "$unpatched" =~ ^2\.0\.0\+[0-9a-f]{7}$ ]] || { echo "unexpected stamp: $unpatched"; return 1; }

  # the patch is made against upstream's version value (the stamp comes after the patches): put it back
  # in the manifest before editing next to it
  cp "$T/up/up-p/plugins/pv/.claude-plugin/plugin.json" "$R/plugins/pv/.claude-plugin/plugin.json"
  git -C "$R" add -A plugins/pv
  sed_file 's/^  "description": "Plugin pv",$/  "description": "Plugin pv, patched",/' "$R/plugins/pv/.claude-plugin/plugin.json"
  sed_file 's/^line 7$/line 7 PATCHED by us/' "$R/plugins/pv/skills/p/SKILL.md"
  git -C "$R" diff -- plugins/pv > "$R/patches/pv.patch"
  git -C "$R" reset -q -- plugins/pv
  git -C "$R" checkout -q -- plugins/pv
  set_patch fake-pv plugins/pv patches/pv.patch
  commit_root "add patch"

  run_sync --only fake-pv
  assert_status 0
  assert_line "    patch patches/pv.patch"
  assert_eq "$(jq -r .description "$R/plugins/pv/.claude-plugin/plugin.json")" "Plugin pv, patched" "patched description"
  grep -qx 'line 7 PATCHED by us' "$R/plugins/pv/skills/p/SKILL.md"
  patched=$(pv_stamp)
  [[ "$patched" =~ ^2\.0\.0\+[0-9a-f]{7}$ ]] || { echo "unexpected stamp: $patched"; return 1; }
  [ "$patched" != "$unpatched" ] || { echo "the stamp ignores the patch: $patched"; return 1; }
  index_matches_head
  commit_root "patched"

  # and it stays stable, also when the 3-way fallback runs (line 4 is in the hunk's context)
  run_sync --only fake-pv
  assert_status 0
  worktree_clean
  put "$T/up/up-p/plugins/pv/skills/p/SKILL.md" $'---\nname: p\ndescription: Skill p. Use when testing patches.\n---\nline 1\nline 2\nline 3\nline 4 changed upstream\nline 5\nline 6\nline 7\nline 8\n'
  commit_upstream up-p P2 >/dev/null
  run_sync --only fake-pv
  assert_status 0
  assert_line "    patch patches/pv.patch (3-way merge)"
  [ "$(pv_stamp)" != "$patched" ] || { echo "stamp did not follow the new upstream content: $patched"; return 1; }
  grep -qx 'line 4 changed upstream' "$R/plugins/pv/skills/p/SKILL.md"
  grep -qx 'line 7 PATCHED by us' "$R/plugins/pv/skills/p/SKILL.md"
  index_matches_head
  commit_root "sync P2"
  run_sync --only fake-pv
  assert_status 0
  worktree_clean

  # --locked rebuilds the same bytes
  run_sync --locked --only fake-pv
  assert_status 0
  worktree_clean
}
