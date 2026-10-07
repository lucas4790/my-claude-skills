#!/usr/bin/env bats
# shellcheck disable=SC2016  # literal backticks in expected SKILLS.md rows
# scripts/sync.sh without patches: copying, filters, --locked, failures, option errors, the lockfile
# and SKILLS.md.
# Runs the real script in a throwaway copy of the repo layout against file:// upstreams.

setup() {
  load helpers
  T="$BATS_TEST_TMPDIR"
  new_root fake other

  # up-a: a skill folder plus a single file; README.md is not vendored
  new_upstream up-a
  put "$T/up/up-a/skills/demo/SKILL.md" $'---\nname: demo\ndescription: Demo skill. Use when testing sync.\n---\nbody v1\n'
  put "$T/up/up-a/skills/demo/sub/keep.txt" "keep"
  put "$T/up/up-a/skills/demo/sub/ignored.txt" "excluded"
  put "$T/up/up-a/skills/demo/deep/sub/ignored.txt" "same name, deeper: not excluded"
  put "$T/up/up-a/LICENSE" "license a"
  put "$T/up/up-a/README.md" "not vendored"
  A1=$(commit_upstream up-a A1)

  # up-b: high trust
  new_upstream up-b
  put "$T/up/up-b/skills/other/SKILL.md" $'---\nname: other\ndescription: Other skill. Use when testing trust tiers.\n---\nother v1\n'
  put "$T/up/up-b/NOTICE" "notice b"
  B1=$(commit_upstream up-b B1)

  add_source fake-a up-a low
  add_copy fake-a skills/demo plugins/fake/skills/demo '{"exclude": ["sub/ignored.txt"]}'
  add_copy fake-a LICENSE plugins/fake/LICENSE
  add_source fake-b up-b high
  add_copy fake-b skills/other plugins/other/skills/other
  add_copy fake-b NOTICE plugins/other/NOTICE
  commit_root "sources"
}

@test "sync: copies a directory (rsync) and a single file (cp), with progress lines" {
  run_sync
  assert_status 0
  assert_line "==> fake-a ($(upstream_url up-a) @ main, low trust)"
  assert_line "    skills/demo -> plugins/fake/skills/demo"
  assert_line "    LICENSE -> plugins/fake/LICENSE"
  assert_line "==> fake-b ($(upstream_url up-b) @ main, high trust)"
  cmp "$T/up/up-a/skills/demo/SKILL.md" "$R/plugins/fake/skills/demo/SKILL.md"
  cmp "$T/up/up-a/skills/demo/sub/keep.txt" "$R/plugins/fake/skills/demo/sub/keep.txt"
  cmp "$T/up/up-a/LICENSE" "$R/plugins/fake/LICENSE"
  cmp "$T/up/up-b/NOTICE" "$R/plugins/other/NOTICE"
  assert_not_exists "$R/plugins/fake/README.md"
  assert_not_exists "$R/plugins/fake/skills/demo/.git"
  assert_not_exists "$R/.sync-tmp"
}

@test "sync: exclude drops paths relative to from, anchored at its root" {
  run_sync
  assert_status 0
  assert_not_exists "$R/plugins/fake/skills/demo/sub/ignored.txt"
  assert_file_content "$R/plugins/fake/skills/demo/deep/sub/ignored.txt" "same name, deeper: not excluded"
}

@test "sync: files deleted upstream, local additions and leftovers at excluded paths are removed" {
  run_sync
  assert_status 0
  commit_root "vendor"
  rm "$T/up/up-a/skills/demo/sub/keep.txt"
  commit_upstream up-a "A2: drop keep.txt" >/dev/null
  put "$R/plugins/fake/skills/demo/local-edit.md" "hand edit, lost on the next sync"
  put "$R/plugins/fake/skills/demo/sub/ignored.txt" "local file at an excluded path"

  run_sync
  assert_status 0
  assert_not_exists "$R/plugins/fake/skills/demo/sub/keep.txt"
  assert_not_exists "$R/plugins/fake/skills/demo/local-edit.md"
  # an excluded path is not vendored, so what an earlier sync left there goes too (--delete-excluded)
  assert_not_exists "$R/plugins/fake/skills/demo/sub/ignored.txt"
  assert_file_content "$R/plugins/fake/skills/demo/deep/sub/ignored.txt" "same name, deeper: not excluded"
}

@test "sync: a newly excluded folder is removed with everything in it; repo-owned files outside the copy's to stay" {
  run_sync
  assert_status 0
  put "$R/plugins/fake/.claude-plugin/plugin.json" '{"name": "fake"}'   # next to, not inside, the vendored folder
  put "$R/plugins/fake/skills/owned.md" "repo-owned, a sibling of the vendored skill folder"
  commit_root "vendor"
  assert_exists "$R/plugins/fake/skills/demo/sub/keep.txt"

  # the entry now excludes the whole sub/ folder that the first sync vendored
  jq_edit "$R/sources.json" '.sources[0].copy[0].exclude = ["sub"]'
  run_sync --only fake-a
  assert_status 0
  assert_not_exists "$R/plugins/fake/skills/demo/sub"
  assert_file_content "$R/plugins/fake/skills/demo/deep/sub/ignored.txt" "same name, deeper: not excluded"
  assert_exists "$R/plugins/fake/skills/demo/SKILL.md"
  assert_file_content "$R/plugins/fake/.claude-plugin/plugin.json" '{"name": "fake"}'
  assert_file_content "$R/plugins/fake/skills/owned.md" "repo-owned, a sibling of the vendored skill folder"
  commit_root "exclude sub"

  # dropping the exclude brings the folder back from upstream
  jq_edit "$R/sources.json" '.sources[0].copy[0].exclude = ["sub/ignored.txt"]'
  run_sync --only fake-a
  assert_status 0
  assert_file_content "$R/plugins/fake/skills/demo/sub/keep.txt" "keep"
  assert_not_exists "$R/plugins/fake/skills/demo/sub/ignored.txt"
}

@test "sync: a folder copy whose to is not a clean path below the repo root fails the source with a reason and deletes nothing" {
  run_sync
  assert_status 0
  commit_root "vendor"
  add_copy fake-a skills/demo ""
  run_sync --only fake-a
  assert_status 1
  assert_line "error: fake-a: cannot copy skills/demo to \"\": a folder copy needs a clean path below the repo root (no empty, . or .. part)"
  assert_line "==> FAILED sources: fake-a"
  assert_exists "$R/scripts/sync.sh"
  assert_exists "$R/sources.json"
  assert_exists "$R/.claude-plugin/marketplace.json"
  worktree_clean plugins scripts

  # these spellings of a folder below the root worked once, but --delete-excluded makes a to that is
  # not clean too risky to guess at: the message says why
  local to
  for to in "plugins/../.." "./plugins/fake/skills/demo" "plugins//fake/skills/demo" "plugins/fake/./skills/demo"; do
    jq_edit "$R/sources.json" --arg to "$to" '.sources[0].copy[-1].to = $to'
    run_sync --only fake-a
    assert_status 1
    assert_line "error: fake-a: cannot copy skills/demo to \"$to\": a folder copy needs a clean path below the repo root (no empty, . or .. part)"
    assert_exists "$T/up/up-a/LICENSE"
    assert_exists "$R/scripts/sync.sh"
    worktree_clean plugins scripts
  done

  # a trailing slash is fine
  jq_edit "$R/sources.json" '.sources[0].copy[-1].to = "plugins/fake/skills/demo/"'
  run_sync --only fake-a
  assert_status 0
  assert_exists "$R/plugins/fake/skills/demo/SKILL.md"
}

@test "sync: an exclude removes what the repo keeps at that path; an entry nested in another's to survives when it comes after" {
  # outer: all of skills/demo into plugins/nest/outer, sub/ and LOCAL.md excluded; inner: sub/ again, into
  # plugins/nest/outer/sub, listed after it
  jq_edit "$R/sources.json" '.sources[0].copy = [
      {from: "skills/demo", to: "plugins/nest/outer", exclude: ["sub", "LOCAL.md"]},
      {from: "skills/demo/sub", to: "plugins/nest/outer/sub"}]'
  put "$R/plugins/nest/outer/LOCAL.md" "repo-owned, but at an excluded path"
  commit_root "nested entries"
  run_sync --only fake-a
  assert_status 0
  assert_not_exists "$R/plugins/nest/outer/LOCAL.md"
  assert_file_content "$R/plugins/nest/outer/sub/keep.txt" "keep"
  assert_file_content "$R/plugins/nest/outer/SKILL.md" $'---\nname: demo\ndescription: Demo skill. Use when testing sync.\n---\nbody v1\n'
  commit_root "vendor"

  # the second run: the outer entry deletes the excluded sub/ the first run vendored, the inner one brings it back
  run_sync --only fake-a
  assert_status 0
  assert_file_content "$R/plugins/nest/outer/sub/keep.txt" "keep"
  worktree_clean plugins
}

@test "sync: --only NAME syncs one source and keeps the other lock entries" {
  run_sync
  assert_status 0
  commit_root "vendor"
  put "$T/up/up-a/LICENSE" "license a, version 2"
  commit_upstream up-a A2 >/dev/null
  put "$T/up/up-b/NOTICE" "notice b, version 2"
  B2=$(commit_upstream up-b B2)

  run_sync --only fake-b
  assert_status 0
  refute_output_contains "==> fake-a"
  assert_line "==> fake-b ($(upstream_url up-b) @ main, high trust)"
  assert_file_content "$R/plugins/other/NOTICE" "notice b, version 2"
  assert_file_content "$R/plugins/fake/LICENSE" "license a"
  assert_eq "$(lock_sha fake-b)" "$B2" "fake-b lock sha"
  assert_eq "$(lock_sha fake-a)" "$A1" "fake-a lock sha"
}

@test "sync: --trust high and --trust low select sources by tier" {
  run_sync --trust high
  assert_status 0
  refute_output_contains "==> fake-a"
  assert_exists "$R/plugins/other/NOTICE"
  assert_not_exists "$R/plugins/fake/LICENSE"
  assert_eq "$(jq -c 'keys' "$R/UPSTREAM.lock.json")" '["fake-b"]' "lock keys after --trust high"

  run_sync --trust low
  assert_status 0
  refute_output_contains "==> fake-b"
  assert_exists "$R/plugins/fake/LICENSE"
  assert_eq "$(jq -c 'keys' "$R/UPSTREAM.lock.json")" '["fake-a","fake-b"]' "lock keys after --trust low"
  assert_eq "$(jq -r '."fake-a".trust + " " + ."fake-b".trust' "$R/UPSTREAM.lock.json")" "low high" "trust tiers"
}

@test "sync: --locked checks out the lockfile sha even when upstream moved on" {
  run_sync
  assert_status 0
  commit_root "vendor at A1"
  put "$T/up/up-a/skills/demo/SKILL.md" $'---\nname: demo\ndescription: Demo skill. Use when testing sync.\n---\nbody v2, longer\n'
  A2=$(commit_upstream up-a A2)
  put "$R/plugins/fake/skills/demo/SKILL.md" "local garbage"

  run_sync --locked
  assert_status 0
  assert_line "==> fake-a ($(upstream_url up-a) @ ${A1:0:7}, locked)"
  assert_line "==> fake-b ($(upstream_url up-b) @ ${B1:0:7}, locked)"
  cmp "$R/plugins/fake/skills/demo/SKILL.md" <(git -C "$T/up/up-a" show "$A1:skills/demo/SKILL.md")
  assert_eq "$(lock_sha fake-a)" "$A1" "lock sha after --locked"
  worktree_clean

  run_sync --only fake-a
  assert_status 0
  cmp "$R/plugins/fake/skills/demo/SKILL.md" "$T/up/up-a/skills/demo/SKILL.md"
  assert_eq "$(lock_sha fake-a)" "$A2" "lock sha after a normal sync"
}

@test "sync: --locked fails a source that has no lockfile entry" {
  run_sync --locked --only fake-a
  assert_status 1
  assert_line "error: fake-a missing from lockfile"
  assert_line "==> FAILED sources: fake-a"
  assert_not_exists "$R/plugins/fake/LICENSE"
}

@test "sync: a missing from path fails that source only; its paths go back to the last commit" {
  run_sync
  assert_status 0
  commit_root "vendor"
  # up-a: the skill changes and gains a file (copied first), then LICENSE disappears (copy 2 fails)
  put "$T/up/up-a/skills/demo/SKILL.md" $'---\nname: demo\ndescription: Demo skill. Use when testing sync.\n---\nbody v2, not wanted\n'
  put "$T/up/up-a/skills/demo/new.md" "new upstream file"
  rm "$T/up/up-a/LICENSE"
  commit_upstream up-a "A2: LICENSE removed" >/dev/null
  put "$T/up/up-b/NOTICE" "notice b, version 2"
  B2=$(commit_upstream up-b B2)

  run_sync
  assert_status 1
  assert_line "error: LICENSE not found in fake-a"
  assert_line "==> FAILED sources: fake-a"
  # fake-a: back to the committed state, lock entry untouched
  worktree_clean plugins/fake
  assert_not_exists "$R/plugins/fake/skills/demo/new.md"
  assert_eq "$(lock_sha fake-a)" "$A1" "fake-a lock sha"
  # fake-b still synced, and the catalog was still regenerated
  assert_file_content "$R/plugins/other/NOTICE" "notice b, version 2"
  assert_eq "$(lock_sha fake-b)" "$B2" "fake-b lock sha"
  assert_line "==> wrote SKILLS.md (2 plugins)"
}

# fail_after TOOL TEXT: $T/bin/TOOL runs the real TOOL, then exits 23 when its arguments contain TEXT
# (a copy that was partly written and then failed)
fail_after() {
  mkdir -p "$T/bin"
  printf '#!/bin/sh\n"%s" "$@" || exit\ncase "$*" in *%s*) echo "%s: simulated error" >&2; exit 23 ;; esac\n' \
    "$(command -v "$1")" "$2" "$1" > "$T/bin/$1"
  chmod +x "$T/bin/$1"
}

@test "sync: a file where a copy's directory goes fails that source; its paths stay as committed" {
  run_sync
  assert_status 0
  commit_root "vendor"
  rm -r "$R/plugins/fake/skills/demo"
  put "$R/plugins/fake/skills/demo" "a file, not the skill folder"
  commit_root "demo is a file now"
  put "$T/up/up-a/skills/demo/new.md" "new upstream file"
  commit_upstream up-a A2 >/dev/null
  put "$T/up/up-b/NOTICE" "notice b, version 2"
  B2=$(commit_upstream up-b B2)

  run_sync
  assert_status 1
  assert_line "error: fake-a: copying skills/demo to plugins/fake/skills/demo failed"
  refute_output_contains "    skills/demo -> plugins/fake/skills/demo"
  assert_line "==> FAILED sources: fake-a"
  worktree_clean plugins/fake
  assert_file_content "$R/plugins/fake/skills/demo" "a file, not the skill folder"
  assert_eq "$(lock_sha fake-a)" "$A1" "fake-a lock sha"
  assert_eq "$(lock_sha fake-b)" "$B2" "fake-b lock sha"
}

@test "sync: a file where the vendored copy has a folder (upstream turned it into a file) replaces the folder" {
  run_sync
  assert_status 0
  commit_root "vendor"
  rm -r "$T/up/up-a/skills/demo"
  put "$T/up/up-a/skills/demo" "demo is a file now"
  A2=$(commit_upstream up-a "A2: demo is a file")

  # a failed copy there fails the source and puts the folder back
  fail_after cp plugins/fake/skills/demo
  PATH="$T/bin:$PATH" run_sync --only fake-a
  assert_status 1
  assert_line "error: fake-a: copying skills/demo to plugins/fake/skills/demo failed"
  assert_line "==> FAILED sources: fake-a"
  worktree_clean plugins/fake
  assert_file_content "$R/plugins/fake/skills/demo/sub/keep.txt" "keep"
  assert_eq "$(lock_sha fake-a)" "$A1" "fake-a lock sha after the failed copy"

  run_sync --only fake-a
  assert_status 0
  assert_line "    skills/demo -> plugins/fake/skills/demo"
  assert_file_content "$R/plugins/fake/skills/demo" "demo is a file now"
  assert_eq "$(lock_sha fake-a)" "$A2" "fake-a lock sha"
}

@test "sync: a file copy removes no folder its to does not name exactly (a/, or empty: the root)" {
  run_sync
  assert_status 0
  commit_root "vendor"
  add_copy fake-a LICENSE plugins/fake/skills/
  run_sync --only fake-a
  assert_status 1
  assert_line "error: fake-a: copying LICENSE to plugins/fake/skills/ failed"
  worktree_clean plugins/fake
  assert_exists "$R/plugins/fake/skills/demo/SKILL.md"

  jq_edit "$R/sources.json" '.sources[0].copy[-1].to = ""'
  run_sync --only fake-a
  assert_status 1
  assert_line "error: fake-a: copying LICENSE to  failed"
  assert_exists "$R/scripts/sync.sh"
  worktree_clean plugins
}

@test "sync: an rsync or cp error fails that source; what it wrote goes back to the last commit" {
  run_sync
  assert_status 0
  commit_root "vendor"
  put "$T/up/up-a/skills/demo/SKILL.md" $'---\nname: demo\ndescription: Demo skill. Use when testing sync.\n---\nbody v2, not wanted\n'
  put "$T/up/up-a/skills/demo/new.md" "new upstream file"
  commit_upstream up-a A2 >/dev/null
  put "$T/up/up-b/skills/other/SKILL.md" $'---\nname: other\ndescription: Other skill. Use when testing trust tiers.\n---\nother v2, not wanted\n'
  put "$T/up/up-b/NOTICE" "notice b, version 2"
  commit_upstream up-b B2 >/dev/null
  fail_after rsync plugins/fake/        # fake-a's folder copy
  fail_after cp plugins/other/NOTICE    # fake-b's file copy, after its folder copy was written

  PATH="$T/bin:$PATH" run_sync
  assert_status 1
  assert_line "error: fake-a: copying skills/demo to plugins/fake/skills/demo failed"
  assert_line "error: fake-b: copying NOTICE to plugins/other/NOTICE failed"
  assert_line "==> FAILED sources: fake-a fake-b"
  worktree_clean plugins
  assert_not_exists "$R/plugins/fake/skills/demo/new.md"
  assert_eq "$(lock_sha fake-a)" "$A1" "fake-a lock sha"
  assert_eq "$(lock_sha fake-b)" "$B1" "fake-b lock sha"
}

@test "sync: a failing source that was never committed leaves no files behind" {
  add_copy fake-a no/such/path plugins/fake/missing
  run_sync --only fake-a
  assert_status 1
  assert_line "error: no/such/path not found in fake-a"
  assert_eq "$(find "$R/plugins/fake" -type f 2>/dev/null | wc -l | tr -d ' ')" "0" "files left under plugins/fake"
  worktree_clean plugins
}

@test "sync: a source without copy entries fails" {
  jq_edit "$R/sources.json" '.sources[0].copy = []'
  run_sync --only fake-a
  assert_status 1
  assert_line "error: fake-a has no copy entries"
}

@test "sync: the lockfile records repo, ref, sha and trust per source, sorted" {
  run_sync
  assert_status 0
  assert_line "==> wrote UPSTREAM.lock.json"
  expected=$(jq -nS --arg ra "$(upstream_url up-a)" --arg rb "$(upstream_url up-b)" --arg a "$A1" --arg b "$B1" '{
    "fake-a": {repo: $ra, ref: "main", sha: $a, trust: "low"},
    "fake-b": {repo: $rb, ref: "main", sha: $b, trust: "high"}}')
  assert_eq "$(cat "$R/UPSTREAM.lock.json")" "$expected" "UPSTREAM.lock.json"
  # jq -S layout: keys sorted at every level
  assert_eq "$(jq -r '.["fake-a"] | keys_unsorted | join(",")' "$R/UPSTREAM.lock.json")" "ref,repo,sha,trust" "entry key order"
}

# add_stale_lock_entry: a lock entry of a source that sources.json no longer has
add_stale_lock_entry() {
  jq_edit "$R/UPSTREAM.lock.json" \
    '. + {"zz-old": {repo: "x", ref: "main", sha: "0000000000000000000000000000000000000000", trust: "high"}}'
}

@test "sync: every run drops lock entries of sources not in sources.json, also with --only or --trust" {
  echo '{}' > "$R/UPSTREAM.lock.json"
  add_stale_lock_entry
  run_sync --only fake-a
  assert_status 0
  assert_line "==> dropped zz-old from the lockfile (not in sources.json)"
  assert_eq "$(jq -c 'keys' "$R/UPSTREAM.lock.json")" '["fake-a"]' "lock keys after --only fake-a"

  # the entry of a source the filter skips stays as it was, even when its upstream moved on
  put "$T/up/up-a/LICENSE" "license a, version 2"
  commit_upstream up-a A2 >/dev/null
  add_stale_lock_entry
  run_sync --trust high
  assert_status 0
  assert_line "==> dropped zz-old from the lockfile (not in sources.json)"
  assert_eq "$(jq -c 'keys' "$R/UPSTREAM.lock.json")" '["fake-a","fake-b"]' "lock keys after --trust high"
  assert_eq "$(lock_sha fake-a)" "$A1" "fake-a lock sha after --trust high"

  add_stale_lock_entry
  run_sync
  assert_status 0
  assert_line "==> dropped zz-old from the lockfile (not in sources.json)"
  assert_eq "$(jq -c 'keys' "$R/UPSTREAM.lock.json")" '["fake-a","fake-b"]' "lock keys after a run over every source"
}

@test "sync: a second run with nothing new upstream changes nothing" {
  run_sync
  assert_status 0
  commit_root "vendor"
  run_sync
  assert_status 0
  worktree_clean
}

@test "sync: regenerates SKILLS.md from the marketplace" {
  run_sync
  assert_status 0
  assert_line "==> wrote SKILLS.md (2 plugins)"
  grep -qxF '| [`demo`](plugins/fake/skills/demo/SKILL.md) | Demo skill. Use when testing sync. |' "$R/SKILLS.md"
  grep -qxF '| [`other`](plugins/other/skills/other/SKILL.md) | Other skill. Use when testing trust tiers. |' "$R/SKILLS.md"
}

@test "sync: an unknown option exits 2 before doing anything" {
  run_sync --bogus
  assert_status 2
  assert_line "unknown option: --bogus"
  assert_not_exists "$R/UPSTREAM.lock.json"
  assert_not_exists "$R/SKILLS.md"
}

@test "sync: --only with a name that no source has exits 2 before doing anything" {
  run_sync --only fake-aa
  assert_status 2
  assert_line "error: no source in sources.json matches --only fake-aa"
  # fake-a exists, but its trust is low
  run_sync --only fake-a --trust high
  assert_status 2
  assert_line "error: no source in sources.json matches --only fake-a --trust high"
  refute_output_contains "==>"
  assert_not_exists "$R/UPSTREAM.lock.json"
  assert_not_exists "$R/SKILLS.md"
  assert_not_exists "$R/plugins/fake"
}

@test "sync: --trust other than high or low exits 2 before doing anything" {
  run_sync --trust High
  assert_status 2
  assert_line "error: --trust must be high or low, not: High"
  refute_output_contains "==>"
  assert_not_exists "$R/UPSTREAM.lock.json"
  assert_not_exists "$R/plugins/other"
}

@test "sync: --only or --trust without a value, or with an empty one, exits 2" {
  run_sync --only
  assert_status 2
  assert_line "error: --only needs a value"
  run_sync --locked --trust
  assert_status 2
  assert_line "error: --trust needs a value"
  # an empty value (e.g. an unset variable in quotes) would be no filter at all: every source synced
  run_sync --only ""
  assert_status 2
  assert_line "error: --only needs a value"
  run_sync --trust "" --only fake-a
  assert_status 2
  assert_line "error: --trust needs a value"
  refute_output_contains "==>"
  assert_not_exists "$R/UPSTREAM.lock.json"
  assert_not_exists "$R/plugins/fake"
}

@test "sync: exits 1 naming a required tool that is missing (rsync)" {
  link_tools "$T/bin" bash dirname git jq python3
  run env PATH="$T/bin" "$BASH" "$R/scripts/sync.sh"
  assert_status 1
  assert_line "error: rsync required"
  assert_not_exists "$R/UPSTREAM.lock.json"
}

# --- symlinks ---------------------------------------------------------------------------------------

@test "sync: a symlink in a folder copy fails the source with its target named; nothing is copied or committed" {
  put "$T/secret.txt" "SECRET outside every plugin"
  ln -s SKILL.md "$T/up/up-a/skills/demo/inside-link.md"                  # resolves inside the plugin
  ln -s "$T/secret.txt" "$T/up/up-a/skills/demo/sub/abs-link.txt"         # absolute, outside it
  ln -s ../../../../../../secret.txt "$T/up/up-a/skills/demo/rel-link.txt" # relative, outside it
  ln -s sub "$T/up/up-a/skills/demo/dir-link"                             # to a folder
  ln -s nowhere "$T/up/up-a/skills/demo/dangling-link"                    # to nothing
  A2=$(commit_upstream up-a A2)
  put "$T/up/up-b/NOTICE" "notice b, version 2"
  B2=$(commit_upstream up-b B2)

  run_sync
  assert_status 1
  assert_line "error: fake-a: skills/demo/inside-link.md is a symlink (-> SKILL.md); vendored content holds none: add \"inside-link.md\" to that copy entry's \"exclude\" (see SECURITY.md)"
  assert_line "error: fake-a: skills/demo/rel-link.txt is a symlink (-> ../../../../../../secret.txt); vendored content holds none: add \"rel-link.txt\" to that copy entry's \"exclude\" (see SECURITY.md)"
  assert_line "error: fake-a: skills/demo/sub/abs-link.txt is a symlink (-> $T/secret.txt); vendored content holds none: add \"sub/abs-link.txt\" to that copy entry's \"exclude\" (see SECURITY.md)"
  assert_line "error: fake-a: skills/demo/dir-link is a symlink (-> sub); vendored content holds none: add \"dir-link\" to that copy entry's \"exclude\" (see SECURITY.md)"
  assert_line "error: fake-a: skills/demo/dangling-link is a symlink (-> nowhere); vendored content holds none: add \"dangling-link\" to that copy entry's \"exclude\" (see SECURITY.md)"
  assert_line "==> FAILED sources: fake-a"
  refute_output_contains "    skills/demo -> plugins/fake/skills/demo"
  # fake-a was never committed: no file or link of it is left; its lock entry was never written
  assert_eq "$(find "$R/plugins/fake" \( -type f -o -type l \) 2>/dev/null | wc -l | tr -d ' ')" "0" "files and links left under plugins/fake"
  assert_eq "$(lock_sha fake-a)" "" "fake-a lock sha"
  # the other source still synced
  assert_file_content "$R/plugins/other/NOTICE" "notice b, version 2"
  assert_eq "$(lock_sha fake-b)" "$B2" "fake-b lock sha"
}

@test "sync: at most 10 symlinks are listed, then a count" {
  local n
  for n in 1 2 3 4 5 6 7 8 9 10 11 12; do ln -s SKILL.md "$T/up/up-a/skills/demo/link-$n"; done
  commit_upstream up-a A2 >/dev/null
  run_sync --only fake-a
  assert_status 1
  assert_line "error: fake-a: skills/demo/link-1 is a symlink (-> SKILL.md); vendored content holds none: add \"link-1\" to that copy entry's \"exclude\" (see SECURITY.md)"
  # sorted as strings: link-1, link-10 ... link-12, link-2 ... link-7 are the first 10
  assert_line "error: fake-a: skills/demo/link-7 is a symlink (-> SKILL.md); vendored content holds none: add \"link-7\" to that copy entry's \"exclude\" (see SECURITY.md)"
  refute_output_contains "skills/demo/link-8 is a symlink"
  assert_line "error: fake-a: plus 2 more symlinks under skills/demo"
}

@test "sync: excluding the symlink's path lets the source sync again" {
  ln -s SKILL.md "$T/up/up-a/skills/demo/sub/link.md"
  commit_upstream up-a A2 >/dev/null
  run_sync --only fake-a
  assert_status 1

  jq_edit "$R/sources.json" '.sources[0].copy[0].exclude += ["sub/link.md"]'
  run_sync --only fake-a
  assert_status 0
  assert_not_exists "$R/plugins/fake/skills/demo/sub/link.md"
  [ ! -L "$R/plugins/fake/skills/demo/sub/link.md" ]
  assert_file_content "$R/plugins/fake/skills/demo/sub/keep.txt" "keep"
}

@test "sync: a single file whose from is a symlink fails the source and is not followed" {
  put "$T/secret.txt" "SECRET outside every plugin"
  rm "$T/up/up-a/LICENSE"
  ln -s "$T/secret.txt" "$T/up/up-a/LICENSE"
  commit_upstream up-a A2 >/dev/null

  run_sync --only fake-a
  assert_status 1
  assert_line "error: fake-a: LICENSE is a symlink (-> $T/secret.txt); vendored content holds none: point \"from\" at what it names (see SECURITY.md)"
  assert_line "==> FAILED sources: fake-a"
  refute grep -rqF SECRET "$R/plugins"
  assert_not_exists "$R/plugins/fake/LICENSE"
}

@test "sync: a folder whose from is a symlink fails the source; a dangling one too" {
  mkdir "$T/outside"
  put "$T/outside/secret.txt" "SECRET outside every plugin"
  rm -r "$T/up/up-a/skills/demo"
  ln -s "$T/outside" "$T/up/up-a/skills/demo"
  commit_upstream up-a A2 >/dev/null
  run_sync --only fake-a
  assert_status 1
  assert_line "error: fake-a: skills/demo is a symlink (-> $T/outside); vendored content holds none: point \"from\" at what it names (see SECURITY.md)"
  refute grep -rqF SECRET "$R/plugins"
  assert_not_exists "$R/plugins/fake"

  rm "$T/up/up-a/skills/demo"
  ln -s "$T/nowhere" "$T/up/up-a/skills/demo"
  commit_upstream up-a A3 >/dev/null
  run_sync --only fake-a
  assert_status 1
  assert_line "error: fake-a: skills/demo is a symlink (-> $T/nowhere); vendored content holds none: point \"from\" at what it names (see SECURITY.md)"
  refute_output_contains "not found in fake-a"
}

# A link below a from that another entry checks out (and excludes): a trailing slash on from, or a link in
# the middle of it, hides the link from a test of the last path component alone, and rsync follows it.
@test "sync: a from that is a symlink behind a trailing slash fails the source and is not followed" {
  mkdir "$T/outside"
  put "$T/outside/secret.txt" "SECRET outside every plugin"
  rm -r "$T/up/up-a/skills/demo"
  put "$T/up/up-a/skills/other/o.txt" "o"
  ln -s "$T/outside" "$T/up/up-a/skills/demo"
  commit_upstream up-a A2 >/dev/null
  jq_edit "$R/sources.json" '.sources[0].copy = [
      {from: "skills", to: "plugins/fake/skills", exclude: ["demo"]},
      {from: "skills/demo/", to: "plugins/fake/elsewhere"}]'
  run_sync --only fake-a
  assert_status 1
  assert_line "error: fake-a: skills/demo is a symlink (-> $T/outside); vendored content holds none: point \"from\" at what it names (see SECURITY.md)"
  refute grep -rqF SECRET "$R/plugins"
  # the first entry was written and is put back: no file of fake-a is left
  assert_eq "$(find "$R/plugins/fake" \( -type f -o -type l \) | wc -l | tr -d ' ')" "0" "files and links left under plugins/fake"
}

@test "sync: a from that passes through a symlink fails the source and is not followed; a dangling one too" {
  mkdir -p "$T/outside/sub"
  put "$T/outside/sub/secret.txt" "SECRET outside every plugin"
  rm -r "$T/up/up-a/skills/demo"
  put "$T/up/up-a/skills/other/o.txt" "o"
  ln -s "$T/outside" "$T/up/up-a/skills/lnk"
  commit_upstream up-a A2 >/dev/null
  jq_edit "$R/sources.json" '.sources[0].copy = [
      {from: "skills", to: "plugins/fake/skills", exclude: ["lnk"]},
      {from: "skills/lnk/sub", to: "plugins/fake/elsewhere"}]'
  run_sync --only fake-a
  assert_status 1
  assert_line "error: fake-a: skills/lnk is a symlink (-> $T/outside); vendored content holds none: point \"from\" at what it names (see SECURITY.md)"
  refute grep -rqF SECRET "$R/plugins"
  assert_eq "$(find "$R/plugins/fake" \( -type f -o -type l \) | wc -l | tr -d ' ')" "0" "files and links left under plugins/fake"

  rm "$T/up/up-a/skills/lnk"
  ln -s "$T/nowhere" "$T/up/up-a/skills/lnk"
  commit_upstream up-a A3 >/dev/null
  run_sync --only fake-a
  assert_status 1
  assert_line "error: fake-a: skills/lnk is a symlink (-> $T/nowhere); vendored content holds none: point \"from\" at what it names (see SECURITY.md)"
  refute_output_contains "not found in fake-a"
}

@test "sync: control characters in a symlink's name or target never reach the log" {
  local esc c1
  esc=$(printf '\033') c1=$(printf '\302\233')
  ln -s "tgt${esc}[31m-red${c1}" "$T/up/up-a/skills/demo/evil${esc}[2J${c1}name"
  commit_upstream up-a A2 >/dev/null
  run_sync --only fake-a
  assert_status 1
  refute grep -q "$esc" <<<"$output"
  refute grep -q "$c1" <<<"$output"
  assert_line "error: fake-a: skills/demo/evil[2Jname is a symlink (-> tgt[31m-red); vendored content holds none: add \"evil[2Jname\" to that copy entry's \"exclude\" (see SECURITY.md)"

  # the same for a from that is a link
  rm "$T/up/up-a/skills/demo/evil${esc}[2J${c1}name" "$T/up/up-a/LICENSE"
  ln -s "${esc}[31mto-here" "$T/up/up-a/LICENSE"
  commit_upstream up-a A3 >/dev/null
  run_sync --only fake-a
  assert_status 1
  refute grep -q "$esc" <<<"$output"
  assert_line "error: fake-a: LICENSE is a symlink (-> [31mto-here); vendored content holds none: point \"from\" at what it names (see SECURITY.md)"
}

@test "sync: a symlink whose name holds a newline is one error line, not several" {
  ln -s x "$T/up/up-a/skills/demo/$(printf 'a\nerror: fake-a: forged')"
  commit_upstream up-a A2 >/dev/null
  run_sync --only fake-a
  assert_status 1
  assert_eq "$(grep -c 'is a symlink' <<<"$output")" "1" "lines naming a symlink"
  assert_line "error: fake-a: skills/demo/aerror: fake-a: forged is a symlink (-> x); vendored content holds none: add \"aerror: fake-a: forged\" to that copy entry's \"exclude\" (see SECURITY.md)"
  refute grep -q '^error: fake-a: forged' <<<"$output"
}

@test "sync: a failed symlink check puts the last commit's files back" {
  run_sync
  assert_status 0
  commit_root "vendor"
  put "$T/up/up-a/skills/demo/SKILL.md" $'---\nname: demo\ndescription: Demo skill. Use when testing sync.\n---\nbody v2, not wanted\n'
  ln -s SKILL.md "$T/up/up-a/skills/demo/link.md"
  commit_upstream up-a A2 >/dev/null

  run_sync --only fake-a
  assert_status 1
  worktree_clean plugins/fake
  assert_not_exists "$R/plugins/fake/skills/demo/link.md"
  assert_eq "$(lock_sha fake-a)" "$A1" "fake-a lock sha"
}

# --- stamped versions ---------------------------------------------------------------------------------

# manifest NAME VERSION: a plugin manifest as upstream writes it: indented, an inline array, and a nested
# "version" key with a string before the real one (the stamp must change only the top-level key);
# VERSION "" leaves the top-level key out
manifest() {
  local v=""
  [ -z "$2" ] || v=$(printf '  "version": "%s",\n' "$2")
  printf '{\n  "name": "%s",\n  "metadata": {"version": "1.2.3"},\n%s  "description": "Plugin %s",\n  "skills": ["./skills/"]\n}\n' \
    "$1" "$v" "$1"
}

# pinned_upstream: up-v holds plugins/pinned (pinned 1.2.3; manifests for Claude Code, Copilot and Codex),
# plugins/still (pinned 0.5.0+build.7, never changes) and plugins/free (no version), vendored whole
# by the source fake-v
pinned_upstream() {
  new_upstream up-v
  local d="$T/up/up-v/plugins" s
  for s in pinned still; do
    put "$d/$s/skills/s/SKILL.md" $'---\nname: s\ndescription: Skill s. Use when testing stamps.\n---\nbody v1\n'
  done
  put "$d/free/skills/s/SKILL.md" $'---\nname: s\ndescription: Skill s. Use when testing stamps.\n---\nbody v1\n'
  put "$d/pinned/.claude-plugin/plugin.json" "$(manifest pinned 1.2.3)"
  put "$d/pinned/plugin.json" "$(manifest pinned 1.2.3)"
  put "$d/pinned/.codex-plugin/plugin.json" "$(manifest pinned 1.2.3)"
  put "$d/still/.claude-plugin/plugin.json" "$(manifest still 0.5.0+build.7)"
  put "$d/free/.claude-plugin/plugin.json" "$(manifest free "")"
  V1=$(commit_upstream up-v V1)
  add_source fake-v up-v low
  add_copy fake-v plugins/pinned plugins/pinned
  add_copy fake-v plugins/still plugins/still
  add_copy fake-v plugins/free plugins/free
  commit_root "source fake-v"
}

# stamp PLUGIN [MANIFEST]: the version string in the plugin's manifest
stamp() { jq -r .version "$R/plugins/$1/${2:-.claude-plugin/plugin.json}"; }

@test "sync: stamps <version>+<7 hex> into the vendored manifests that carry a version, and only those" {
  pinned_upstream
  run_sync --only fake-v
  assert_status 0
  v=$(stamp pinned)
  [[ "$v" =~ ^1\.2\.3\+[0-9a-f]{7}$ ]] || { echo "unexpected stamp: $v"; return 1; }
  assert_line "    version plugins/pinned/.claude-plugin/plugin.json: 1.2.3 -> $v"
  assert_line "    version plugins/pinned/plugin.json: 1.2.3 -> $v"
  assert_line "    version plugins/pinned/.codex-plugin/plugin.json: 1.2.3 -> $v"
  # Copilot's and Codex's manifests carry the same stamp. Only the version value differs from what
  # upstream wrote: the layout stays, and so does a nested "version" key
  assert_eq "$(stamp pinned plugin.json)" "$v" "root plugin.json"
  assert_eq "$(stamp pinned .codex-plugin/plugin.json)" "$v" "Codex plugin.json"
  cmp "$R/plugins/pinned/.claude-plugin/plugin.json" <(sed "/^  \"version\"/s/1\.2\.3/$v/" "$T/up/up-v/plugins/pinned/.claude-plugin/plugin.json")
  assert_eq "$(jq -r .metadata.version "$R/plugins/pinned/plugin.json")" "1.2.3" "nested version key"
  # existing build metadata is extended, not replaced
  [[ "$(stamp still)" =~ ^0\.5\.0\+build\.7\.[0-9a-f]{7}$ ]] || { echo "unexpected stamp: $(stamp still)"; return 1; }
  # no version upstream: the manifest is byte-identical, and no line names it
  cmp "$R/plugins/free/.claude-plugin/plugin.json" "$T/up/up-v/plugins/free/.claude-plugin/plugin.json"
  refute_output_contains "plugins/free/.claude-plugin/plugin.json:"
}

@test "sync: only a plugin whose files changed gets a new stamp; a version bump alone keeps the hash" {
  pinned_upstream
  run_sync --only fake-v
  assert_status 0
  commit_root "vendor"
  p1=$(stamp pinned); s1=$(stamp still)

  put "$T/up/up-v/plugins/pinned/skills/s/SKILL.md" $'---\nname: s\ndescription: Skill s. Use when testing stamps.\n---\nbody v2, longer\n'
  commit_upstream up-v V2 >/dev/null
  run_sync --only fake-v
  assert_status 0
  p2=$(stamp pinned)
  [ "$p2" != "$p1" ] || { echo "stamp did not change with the content: $p1"; return 1; }
  assert_eq "${p2%%+*}" "1.2.3" "upstream part of the new stamp"
  assert_eq "$(stamp pinned plugin.json)" "$p2" "root plugin.json"
  assert_eq "$(stamp still)" "$s1" "stamp of the plugin that did not change"
  assert_eq "$(git -C "$R" status --porcelain -- plugins/still plugins/free)" "" "unchanged plugins in git status"
  commit_root "vendor V2"

  # upstream bumps the version and nothing else: new upstream part, same hash
  put "$T/up/up-v/plugins/pinned/.claude-plugin/plugin.json" "$(manifest pinned 1.3.0)"
  put "$T/up/up-v/plugins/pinned/plugin.json" "$(manifest pinned 1.3.0)"
  put "$T/up/up-v/plugins/pinned/.codex-plugin/plugin.json" "$(manifest pinned 1.3.0)"
  commit_upstream up-v V3 >/dev/null
  run_sync --only fake-v
  assert_status 0
  assert_eq "$(stamp pinned)" "1.3.0+${p2#*+}" "stamp after a version-only bump"
}

@test "sync: a mode change alone, or a new file, changes the stamp" {
  pinned_upstream
  run_sync --only fake-v
  assert_status 0
  commit_root "vendor"
  p1=$(stamp pinned)

  chmod +x "$T/up/up-v/plugins/pinned/skills/s/SKILL.md"
  commit_upstream up-v "V2: executable" >/dev/null
  run_sync --only fake-v
  assert_status 0
  p2=$(stamp pinned)
  [ "$p2" != "$p1" ] || { echo "a mode change left the stamp at $p1"; return 1; }
  commit_root "vendor V2"

  put "$T/up/up-v/plugins/pinned/skills/s/extra.md" "new file"
  commit_upstream up-v "V3: new file" >/dev/null
  run_sync --only fake-v
  assert_status 0
  [ "$(stamp pinned)" != "$p2" ] || { echo "a new file left the stamp at $p2"; return 1; }
}

@test "sync: what the repo's .gitignore ignores does not change the stamp, a rule of this clone's own does not either" {
  pinned_upstream
  # two copies of one plugin: the folder holds files outside every copy's "to", which rsync leaves alone
  add_copy fake-v plugins/pinned/.claude-plugin plugins/mixed/.claude-plugin
  add_copy fake-v plugins/pinned/skills plugins/mixed/skills
  commit_root "mixed plugin"
  run_sync --only fake-v
  assert_status 0
  commit_root "vendor"
  m1=$(stamp mixed)

  put "$R/plugins/mixed/__pycache__/junk.pyc" "ignored by .gitignore"
  run_sync --only fake-v
  assert_status 0
  assert_exists "$R/plugins/mixed/__pycache__/junk.pyc"
  assert_eq "$(stamp mixed)" "$m1" "stamp with a file the repo's .gitignore ignores"

  # untracked and not ignored counts: CI sees the same file once it is committed. A rule that only this
  # clone has (.git/info/exclude, or a global ignore file) must not hide it, or a local run and CI differ.
  put "$R/plugins/mixed/local.dat" "a repo-owned file"
  run_sync --only fake-v
  assert_status 0
  m2=$(stamp mixed)
  [ "$m2" != "$m1" ] || { echo "a repo-owned file left the stamp at $m1"; return 1; }
  printf '*.dat\n' >> "$R/.git/info/exclude"
  run_sync --only fake-v
  assert_status 0
  assert_eq "$(stamp mixed)" "$m2" "stamp with a file that only .git/info/exclude ignores"
}

# The sync's result is uncommitted when the stamp is computed, and committed on the next run: git lists
# tracked files before untracked ones, so the two runs see the same files in a different order, and the
# stamp must not care.
@test "sync: the stamp is the same before and after the sync's own commit (a new file that sorts first, a deleted file)" {
  pinned_upstream
  put "$T/up/up-v/plugins/pinned/skills/s/b.md" "b"
  commit_upstream up-v "V1b: second file" >/dev/null
  run_sync --only fake-v
  assert_status 0
  commit_root "vendor"

  put "$T/up/up-v/plugins/pinned/skills/a-new.md" "new file, sorts before the tracked skills/s/*"
  commit_upstream up-v "V2: new file" >/dev/null
  run_sync --only fake-v
  assert_status 0
  uncommitted=$(stamp pinned)
  commit_root "vendor V2"
  run_sync --only fake-v
  assert_status 0
  assert_eq "$(stamp pinned)" "$uncommitted" "stamp after committing a new file"
  worktree_clean

  rm "$T/up/up-v/plugins/pinned/skills/s/b.md"
  commit_upstream up-v "V3: drop b.md" >/dev/null
  run_sync --only fake-v
  assert_status 0
  uncommitted=$(stamp pinned)
  commit_root "vendor V3"
  run_sync --only fake-v
  assert_status 0
  assert_eq "$(stamp pinned)" "$uncommitted" "stamp after committing a deleted file"
  worktree_clean
}

@test "sync: two runs and a --locked rebuild leave the same bytes" {
  pinned_upstream
  run_sync
  assert_status 0
  commit_root "vendor"
  p1=$(stamp pinned)
  [[ "$p1" =~ ^1\.2\.3\+[0-9a-f]{7}$ ]] || { echo "unexpected stamp: $p1"; return 1; }
  run_sync
  assert_status 0
  worktree_clean
  assert_eq "$(stamp pinned)" "$p1" "stamp after the second run"

  put "$T/up/up-v/plugins/pinned/skills/s/SKILL.md" $'---\nname: s\ndescription: Skill s. Use when testing stamps.\n---\nbody v2, longer\n'
  commit_upstream up-v V2 >/dev/null
  run_sync --locked
  assert_status 0
  worktree_clean
  assert_eq "$(lock_sha fake-v)" "$V1" "lock sha after --locked"

  # a source that --only or --trust skips keeps its stamped files as they are
  run_sync --only fake-a
  assert_status 0
  worktree_clean
}

@test "sync: a manifest the repo owns is never stamped, even when it has a version" {
  pinned_upstream
  put "$R/plugins/owned/.claude-plugin/plugin.json" "$(manifest owned 9.9.9)"
  add_copy fake-v plugins/pinned/skills plugins/owned/skills
  commit_root "repo-owned manifest next to a vendored skills folder"
  run_sync --only fake-v
  assert_status 0
  # the manifests this source vendored are stamped, the one the repo owns is not
  [[ "$(stamp pinned)" =~ ^1\.2\.3\+[0-9a-f]{7}$ ]]
  assert_file_content "$R/plugins/owned/.claude-plugin/plugin.json" "$(manifest owned 9.9.9)"
  refute_output_contains "    version plugins/owned/"
  assert_exists "$R/plugins/owned/skills/s/SKILL.md"
}

@test "sync: the stamp covers the whole plugin folder, the files the repo owns in it too" {
  pinned_upstream
  # the manifest and the skills are two copies of one plugin, with a repo-owned file between them
  add_copy fake-v plugins/pinned/.claude-plugin plugins/mixed/.claude-plugin
  add_copy fake-v plugins/pinned/skills plugins/mixed/skills
  commit_root "mixed plugin"
  run_sync --only fake-v
  assert_status 0
  m1=$(stamp mixed)
  [[ "$m1" =~ ^1\.2\.3\+[0-9a-f]{7}$ ]] || { echo "unexpected stamp: $m1"; return 1; }
  commit_root "vendor"

  put "$R/plugins/mixed/NOTES.md" "repo-owned note"
  run_sync --only fake-v
  assert_status 0
  [ "$(stamp mixed)" != "$m1" ] || { echo "a repo-owned file left the stamp at $m1"; return 1; }
  assert_file_content "$R/plugins/mixed/NOTES.md" "repo-owned note"
}

@test "sync: a plugin folder that two sources write to is not stamped; a warning says so" {
  pinned_upstream
  new_upstream up-w
  put "$T/up/up-w/skills/w/SKILL.md" $'---\nname: w\ndescription: Skill w. Use when testing stamps.\n---\nw v1\n'
  commit_upstream up-w W1 >/dev/null
  add_source fake-w up-w low
  add_copy fake-w skills/w plugins/pinned/skills/w
  run_sync --only fake-v
  assert_status 0
  assert_line "warning: fake-v: plugins/pinned also receives files from another source; its version is not stamped"
  assert_eq "$(stamp pinned)" "1.2.3" "unstamped version"
  [[ "$(stamp still)" =~ ^0\.5\.0\+build\.7\.[0-9a-f]{7}$ ]]
}

@test "sync: a vendored manifest that is not a JSON object gets a warning and no stamp; the source still syncs" {
  pinned_upstream
  put "$T/up/up-v/plugins/pinned/plugin.json" '{"name": "pinned", "version": "1.2.3",'
  commit_upstream up-v V2 >/dev/null
  run_sync --only fake-v
  assert_status 0
  assert_line "warning: fake-v: plugins/pinned/plugin.json is not a JSON object; its version is not stamped"
  assert_eq "$(stamp pinned plugin.json 2>/dev/null)" "" "broken manifest"
  [[ "$(stamp pinned)" =~ ^1\.2\.3\+[0-9a-f]{7}$ ]]
  assert_eq "$(lock_sha fake-v)" "$(git -C "$T/up/up-v" rev-parse HEAD)" "lock sha"
}

@test "sync: a version with newlines or control characters cannot forge log lines" {
  pinned_upstream
  # the sync log is read as workflow commands ("::...") and its "error:" lines go into the PR body
  jq -n --arg v $'1.0\n::add-mask::topsecret\nerror: forged line\n::stop-commands::abc\033[2J' '{name: "pinned", version: $v}' \
    > "$T/up/up-v/plugins/pinned/plugin.json"
  commit_upstream up-v V2 >/dev/null
  run_sync --only fake-v
  assert_status 0
  refute grep -q '^::' <<<"$output"
  refute grep -q '^error:' <<<"$output"
  refute grep -q "$(printf '\033')" <<<"$output"
  assert_eq "$(grep -c '^    version plugins/pinned/plugin.json: ' <<<"$output")" "1" "progress lines of that manifest"
  # the manifest itself keeps upstream's text in front of the stamp
  [[ "$(jq -r .version "$R/plugins/pinned/plugin.json")" == $'1.0\n::add-mask::topsecret\nerror: forged line\n::stop-commands::abc\033[2J+'* ]]
}

@test "sync: a manifest whose top-level version cannot be rewritten fails the source and puts its files back" {
  pinned_upstream
  run_sync --only fake-v
  assert_status 0
  commit_root "vendor"
  p1=$(stamp pinned)

  # parsed as "version", but written with an escape: there is no literal key to rewrite. The Claude Code
  # manifest is stamped first and must go back to the committed one with everything else.
  put "$T/up/up-v/plugins/pinned/plugin.json" $'{"name": "pinned", "vers\\u0069on": "1.2.3"}'
  put "$T/up/up-v/plugins/pinned/skills/s/SKILL.md" $'---\nname: s\ndescription: Skill s. Use when testing stamps.\n---\nbody v2, longer\n'
  commit_upstream up-v V2 >/dev/null
  run_sync --only fake-v
  assert_status 1
  assert_line "error: fake-v: cannot rewrite the version in plugins/pinned/plugin.json"
  assert_line "==> FAILED sources: fake-v"
  worktree_clean plugins
  assert_eq "$(stamp pinned)" "$p1" "stamp after the failed sync"
  assert_eq "$(lock_sha fake-v)" "$V1" "lock sha"
}

@test "sync: a failing git ls-files fails the source instead of stamping from a partial list" {
  pinned_upstream
  mkdir "$T/shim"
  printf '#!/bin/sh\ncase " $* " in *" ls-files -z "*) exit 128 ;; esac\nexec "%s" "$@"\n' "$(command -v git)" > "$T/shim/git"
  chmod +x "$T/shim/git"
  PATH="$T/shim:$PATH" run_sync --only fake-v
  assert_status 1
  assert_line "error: fake-v: git ls-files failed under plugins/pinned; cannot stamp its version"
  assert_line "==> FAILED sources: fake-v"
  assert_not_exists "$R/plugins/pinned"
}

@test "sync: a manifest nested too deep to parse gets a warning and no stamp; the source still syncs" {
  pinned_upstream
  local deep
  deep=$(python3 -c 'print("[" * 100000 + "]" * 100000)')
  put "$T/up/up-v/plugins/pinned/plugin.json" "{\"name\": \"pinned\", \"version\": \"1.2.3\", \"x\": $deep}"
  commit_upstream up-v V2 >/dev/null
  run_sync --only fake-v
  assert_status 0
  assert_line "warning: fake-v: plugins/pinned/plugin.json is not a JSON object; its version is not stamped"
  cmp "$R/plugins/pinned/plugin.json" "$T/up/up-v/plugins/pinned/plugin.json"
  [[ "$(stamp pinned)" =~ ^1\.2\.3\+[0-9a-f]{7}$ ]]
  assert_eq "$(lock_sha fake-v)" "$(git -C "$T/up/up-v" rev-parse HEAD)" "lock sha"
}

@test "sync: thousands of nested version keys before the real one do not stall the stamp" {
  pinned_upstream
  python3 - "$T/up/up-v/plugins/pinned/plugin.json" <<'PY'
import sys
decoys = ", ".join('{"version": "1"}' for _ in range(20000))
with open(sys.argv[1], "w") as f:
    f.write('{"name": "pinned", "x": [%s], "version": "1.2.3"}\n' % decoys)
PY
  commit_upstream up-v V2 >/dev/null
  local t0=$SECONDS
  run_sync --only fake-v
  assert_status 0
  [ $((SECONDS - t0)) -lt 20 ] || { echo "the sync took $((SECONDS - t0)) s"; return 1; }
  [[ "$(stamp pinned plugin.json)" =~ ^1\.2\.3\+[0-9a-f]{7}$ ]]
  assert_eq "$(jq -r '.x[0].version' "$R/plugins/pinned/plugin.json")" "1" "a nested version key"
}

@test "sync: a manifest that repeats its version key has the one that counts (the last) stamped" {
  pinned_upstream
  put "$T/up/up-v/plugins/pinned/plugin.json" '{"name": "pinned", "version": "0.0.1", "version": "1.2.3"}'
  commit_upstream up-v V2 >/dev/null
  run_sync --only fake-v
  assert_status 0
  [[ "$(stamp pinned plugin.json)" =~ ^1\.2\.3\+[0-9a-f]{7}$ ]]
  grep -qF '"version": "0.0.1",' "$R/plugins/pinned/plugin.json"
}

@test "sync: a to that spells its path with ./ or // still gets its manifest stamped" {
  pinned_upstream
  add_copy fake-v plugins/pinned/.claude-plugin/plugin.json ./plugins/solo//.claude-plugin/plugin.json
  add_copy fake-v plugins/pinned/skills/s/SKILL.md plugins/solo/skills/s/SKILL.md
  commit_root "two file copies"
  run_sync --only fake-v
  assert_status 0
  [[ "$(stamp solo)" =~ ^1\.2\.3\+[0-9a-f]{7}$ ]] || { echo "unexpected stamp: $(stamp solo)"; return 1; }
}
