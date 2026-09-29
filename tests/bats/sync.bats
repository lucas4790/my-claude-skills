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

@test "sync: files deleted upstream and local additions are removed (rsync --delete)" {
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
  # rsync never deletes excluded paths on the receiving side (no --delete-excluded)
  assert_file_content "$R/plugins/fake/skills/demo/sub/ignored.txt" "local file at an excluded path"
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

@test "sync: a run over every source drops lock entries of sources not in sources.json; --only and --trust keep them" {
  echo '{"zz-old": {"repo": "x", "ref": "main", "sha": "0000000000000000000000000000000000000000", "trust": "low"}}' \
    > "$R/UPSTREAM.lock.json"
  run_sync --only fake-a
  assert_status 0
  refute_output_contains "dropped"
  run_sync --trust high
  assert_status 0
  refute_output_contains "dropped"
  assert_eq "$(jq -c 'keys' "$R/UPSTREAM.lock.json")" '["fake-a","fake-b","zz-old"]' "lock keys after --only and --trust"

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

@test "sync: --only or --trust without a value exits 2" {
  run_sync --only
  assert_status 2
  assert_line "error: --only needs a value"
  run_sync --locked --trust
  assert_status 2
  assert_line "error: --trust needs a value"
  assert_not_exists "$R/UPSTREAM.lock.json"
}

@test "sync: exits 1 naming a required tool that is missing (rsync)" {
  link_tools "$T/bin" bash dirname git jq python3
  run env PATH="$T/bin" "$BASH" "$R/scripts/sync.sh"
  assert_status 1
  assert_line "error: rsync required"
  assert_not_exists "$R/UPSTREAM.lock.json"
}
