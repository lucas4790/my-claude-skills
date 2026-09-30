#!/usr/bin/env bats
# scripts/adopt-branch.sh on a clone of a bare origin in the test's temp dir (never this checkout):
# a cloud branch whose commit has the vendor committer and an attribution trailer. HOME is a temp dir
# and the system config is off, so no global git config or hook takes part.

setup() {
  load helpers
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home" XDG_CONFIG_HOME="$T/config" GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME"
  O="$T/origin.git" W="$T/work"
  git init -q --bare -b main "$O"
  git init -q -b main "$W"
  cd "$W" || return 1
  git remote add origin "file://$O"
  put f $'base\n'
  git add f
  git commit -qm "Base"
  git push -q origin main
  git switch -q -c claude/x
  put f $'cloud change\n'
  GIT_AUTHOR_NAME=Claude GIT_AUTHOR_EMAIL=noreply@anthropic.com \
    GIT_COMMITTER_NAME=Claude GIT_COMMITTER_EMAIL=noreply@anthropic.com \
    git commit -qam $'Change f\n\nCo-Authored-By: Claude <noreply@anthropic.com>'
  git push -q origin claude/x
  git switch -q main
  # from here on, commits use the owner identity in the repository's config
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  git config user.name Owner
  git config user.email owner@example.com
}

# adopt ARGS...: runs the script in $W; stdin is empty, so the "delete the cloud branch?" answer is no
adopt() { run bash "$REPO_ROOT/scripts/adopt-branch.sh" "$@" </dev/null; }

# cloud_commit FILE TEXT SUBJECT: the cloud session commits FILE (vendor identity, attribution
# trailer) on claude/x and pushes it; the current branch stays checked out
cloud_commit() {
  local here
  here=$(git symbolic-ref --short HEAD)
  git switch -q claude/x
  put "$1" "$2"
  git add "$1"
  GIT_AUTHOR_NAME=Claude GIT_AUTHOR_EMAIL=noreply@anthropic.com \
    GIT_COMMITTER_NAME=Claude GIT_COMMITTER_EMAIL=noreply@anthropic.com \
    git commit -qm "$3"$'\n\nCo-Authored-By: Claude <noreply@anthropic.com>'
  git push -q origin claude/x
  git switch -q "$here"
}

# assert_pushed_as_owner [SUBJECT]: x's last commit is SUBJECT (default: Change f) as the owner, pushed,
# and the adopted cloud commit is recorded
assert_pushed_as_owner() {
  assert_eq "$(git -C "$O" rev-parse refs/heads/x)" "$(git rev-parse HEAD)" "origin/x"
  assert_eq "$(git log -1 --format='%an <%ae>, %cn <%ce>' x)" "Owner <owner@example.com>, Owner <owner@example.com>" "author, committer"
  assert_eq "$(git log -1 --format=%B x | sed '/^$/d')" "${1:-Change f}" "message"
  assert_eq "$(git config branch.x.adoptedCommit)" "$(git rev-parse claude/x)" "recorded cloud commit"
  assert_output_contains "kept origin/claude/x"
  assert_not_exists "$W/.git/adopt-branch"
}

@test "adopt-branch: re-commits the cloud branch as the owner without attribution and pushes it" {
  adopt claude/x x main
  assert_status 0
  assert_line "==> open the PR yourself from branch x into main"
  assert_eq "$(git show x:f)" "cloud change" "f"
  assert_pushed_as_owner
}

@test "adopt-branch: after a stopped rebase and git rebase --continue, a second run checks and pushes" {
  put f $'main change\n'
  git commit -qam "Main moves on"
  git push -q origin main
  # started from a branch other than the base, so the undo hint cannot be the base by chance
  git switch -q -c work
  adopt claude/x x main
  assert_status 1
  assert_output_contains "git rebase --continue"
  assert_output_contains "git switch work; git branch -D x;"

  # while the rebase is stopped, a run says so (and not "commit or stash your changes first")
  adopt claude/x x main
  assert_status 1
  assert_line "a rebase is in progress: finish it (git rebase --continue) or abort it (git rebase --abort) first"

  put f $'resolved\n'
  git add f
  GIT_EDITOR=true git rebase --continue >/dev/null
  # attribution put back by hand: the checks stop the push, and the undo hint still names the
  # branch the first run started from (not x, which git would refuse to delete)
  git commit -q --amend -m $'Change f\n\nCo-Authored-By: Claude <noreply@anthropic.com>'
  adopt claude/x x main
  assert_status 1
  assert_line "attribution left in a commit message"
  assert_output_contains "git switch work; git branch -D x;"
  refute git -C "$O" rev-parse -q --verify refs/heads/x

  # a run for other arguments leaves the stopped run's state alone
  adopt claude/x y main
  assert_status 1
  assert_output_contains "an earlier run (adopt-branch.sh claude/x x main) stopped part-way"
  refute git rev-parse -q --verify refs/heads/y

  git commit -q --amend -m "Change f"
  adopt claude/x x main
  assert_status 0
  assert_line "==> x is checked out and no rebase is in progress: resuming at the checks"
  assert_eq "$(git show x:f)" "resolved" "f"
  assert_eq "$(git rev-parse x~1)" "$(git rev-parse origin/main)" "parent"
  assert_pushed_as_owner
}

@test "adopt-branch: an existing new branch without a stopped or earlier adoption stops before anything changes" {
  git branch x main
  adopt claude/x x main
  assert_status 1
  assert_output_contains "branch x already exists"
  assert_eq "$(git symbolic-ref --short HEAD)" "main" "current branch"
  # checked out, it is still not taken for a stopped run: no resume, nothing pushed
  git switch -q x
  adopt claude/x x main
  assert_status 1
  assert_output_contains "branch x already exists, but no adoption into it is recorded"
  refute_output_contains "resuming"
  assert_eq "$(git rev-parse x)" "$(git rev-parse main)" "x"
  refute git -C "$O" rev-parse -q --verify refs/heads/x
  assert_not_exists "$W/.git/adopt-branch"
}

@test "adopt-branch: after new cloud commits, a run re-commits only those on top of the adopted branch" {
  adopt claude/x x main
  assert_status 0
  first=$(git rev-parse x)
  cloud_commit g $'g\n' "Add g"

  adopt claude/x x main
  assert_status 0
  refute_output_contains "resuming"
  assert_eq "$(git rev-parse x~1)" "$first" "x~1 (the earlier adoption, kept as pushed)"
  assert_eq "$(git show x:g)" "g" "g"
  assert_pushed_as_owner "Add g"

  # nothing new: says so and changes nothing (no push, no delete prompt)
  run bash "$REPO_ROOT/scripts/adopt-branch.sh" claude/x x main <<<y
  assert_status 0
  assert_line "==> x already has every commit of origin/claude/x; to delete that branch: git push origin --delete claude/x"
  refute_output_contains "Delete the cloud branch"
  assert_eq "$(git -C "$O" rev-parse refs/heads/x)" "$(git rev-parse x)" "origin/x"
  git -C "$O" rev-parse -q --verify refs/heads/claude/x >/dev/null

  # the cloud branch deleted only once everything on it is adopted
  cloud_commit h $'h\n' "Add h"
  run bash "$REPO_ROOT/scripts/adopt-branch.sh" claude/x x main <<<y
  assert_status 0
  assert_eq "$(git -C "$O" show x:h)" "h" "h on origin/x"
  refute git -C "$O" rev-parse -q --verify refs/heads/claude/x
}

@test "adopt-branch: a re-adoption that stops resumes like a first one; its undo hint resets the branch" {
  adopt claude/x x main
  assert_status 0
  put f $'owner fix\n'
  git commit -qam "Owner fix"
  git push -q origin x
  before=$(git rev-parse x)
  cloud_commit f $'cloud fix\n' "Cloud fix"
  git switch -q main

  adopt claude/x x main
  assert_status 1
  assert_output_contains "git rebase --continue"
  assert_output_contains "git switch x; git reset --hard $before; git switch main;"

  put f $'both fixes\n'
  git add f
  GIT_EDITOR=true git rebase --continue >/dev/null
  adopt claude/x x main
  assert_status 0
  assert_line "==> x is checked out and no rebase is in progress: resuming at the checks"
  assert_eq "$(git rev-parse x~1)" "$before" "x~1 (the owner's commit)"
  assert_eq "$(git show x:f)" "both fixes" "f"
  assert_pushed_as_owner "Cloud fix"
}

@test "adopt-branch: a cloud branch rewritten since its adoption stops before anything changes" {
  adopt claude/x x main
  assert_status 0
  adopted=$(git rev-parse x)
  git switch -q claude/x
  GIT_COMMITTER_NAME=Claude GIT_COMMITTER_EMAIL=noreply@anthropic.com git commit -q --amend -m "Change f, rewritten"
  git push -q -f origin claude/x
  git switch -q x

  adopt claude/x x main
  assert_status 1
  assert_output_contains "origin/claude/x no longer contains"
  assert_eq "$(git rev-parse x)" "$adopted" "x"
  assert_eq "$(git -C "$O" rev-parse refs/heads/x)" "$adopted" "origin/x"
  git -C "$O" rev-parse -q --verify refs/heads/claude/x >/dev/null
  assert_not_exists "$W/.git/adopt-branch"
}
