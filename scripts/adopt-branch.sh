#!/usr/bin/env bash
# Take over a branch that a Claude Code cloud session pushed, BEFORE opening a PR for it.
# Cloud sessions commit as the vendor identity (committer, and author unless the SessionStart hook
# fixed it) on a claude/ branch. This re-commits every commit on a branch of your own, with you as
# author and committer and attribution lines stripped, pushes it, and offers to delete the old one.
# Run it on your own machine, from a checkout that has this script (e.g. the cloud branch itself):
#   bash scripts/adopt-branch.sh <cloud-branch> [new-branch] [base]
#   bash scripts/adopt-branch.sh claude/setup-analyse-optimalisatie-1gy14n setup-analyse main
# Then open the PR from the new branch (compare link printed at the end). GitHub may keep the old
# commits reachable by SHA for a while; GitHub Support can purge them.
# When the cloud branch gets more commits later, run it again with the same arguments: it re-commits
# only those, on top of the new branch (git config branch.<new-branch>.adoptedCommit holds the last
# cloud commit adopted), and pushes them.
set -euo pipefail
src=${1:?usage: adopt-branch.sh <cloud-branch> [new-branch] [base]}
new=${2:-${src#claude/}}
base=${3:-main}
[ "$new" != "$src" ] || { echo "pick a new branch name that differs from $src" >&2; exit 1; }
case $new in claude/*) echo "pick a branch name without the claude/ prefix" >&2; exit 1 ;; esac

me_name=$(git config user.name || true)
me_mail=$(git config user.email || true)
[ -n "$me_name" ] && [ -n "$me_mail" ] || { echo "set git user.name and user.email first" >&2; exit 1; }
case $me_mail in *@anthropic.com) echo "user.email is the vendor identity; set your own first" >&2; exit 1 ;; esac
if [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
  echo "a rebase is in progress: finish it (git rebase --continue) or abort it (git rebase --abort) first" >&2; exit 1
fi
if ! git diff --quiet || ! git diff --cached --quiet; then echo "commit or stash your changes first" >&2; exit 1; fi
start=$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)
# A run that stopped after it began re-committing (a rebase conflict, a failed check or push) leaves
# its state in $tmp: "run" (its arguments), "tip" (the cloud commit it adopts) and "undo". Only such a
# run resumes, at the checks (e.g. after 'git rebase --continue'); a successful run removes it.
tmp="$(cd "$(git rev-parse --git-dir)" && pwd)/adopt-branch"
stopped=$(cat "$tmp/run" 2>/dev/null || true)
if [ -n "$stopped" ] && [ "$stopped" != "$src $new $base" ]; then
  echo "an earlier run (adopt-branch.sh $stopped) stopped part-way: finish it by running it again with those arguments, or undo it with the commands it printed (they end with rm -rf \"$tmp\")" >&2
  exit 1
fi
adopted=$(git config "branch.$new.adoptedCommit" || true)
resume=0 prev=
if git show-ref --verify --quiet "refs/heads/$new"; then
  if [ -n "$stopped" ]; then
    [ "$start" = "$new" ] || {
      echo "branch $new already exists: to finish the run that stopped, switch to it and run this again" >&2
      exit 1
    }
    resume=1
  elif [ -n "$adopted" ]; then
    prev=$(git rev-parse "refs/heads/$new")  # adopted before: only the newer cloud commits follow
  else
    cat >&2 <<EOF
branch $new already exists, but no adoption into it is recorded: delete it or pick another new-branch name.
(If it holds $src up to some commit, record that commit to adopt only the later ones:
  git config branch.$new.adoptedCommit <sha>)
EOF
    exit 1
  fi
fi

if [ "$resume" = 0 ]; then
  git fetch origin "$src" "$base"
  tip=$(git rev-parse "origin/$src")
  if [ -n "$prev" ]; then
    if [ "$tip" = "$adopted" ]; then
      echo "==> $new already has every commit of origin/$src; to delete that branch: git push origin --delete $src"
      exit 0
    fi
    git merge-base --is-ancestor "$adopted" "$tip" || {
      echo "origin/$src no longer contains ${adopted:0:7}, the commit adopted into $new last (was it rewritten?): adopt it into another new-branch name" >&2
      exit 1
    }
  fi
fi

# The guard from this checkout, copied into the git directory: older commits on the branch may not
# contain it, and a rebase that stops half-way still needs it for 'git rebase --continue'.
here=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
[ "$resume" = 1 ] || rm -rf "$tmp"  # anything left here belongs to no run that can resume
mkdir -p "$tmp"
cp "$here/tools/attribution-guard/attribution-guard.sh" "$here/tools/attribution-guard/patterns.ere" "$tmp/"
undo=
[ "$resume" = 0 ] || { tip=$(cat "$tmp/tip"); undo=$(cat "$tmp/undo"); }
done_ok=0
on_exit() {
  [ "$done_ok" != 1 ] || return 0
  if [ -f "$tmp/run" ]; then
    cat >&2 <<EOF
adopt-branch stopped. To continue: fix the problem (a stopped rebase: resolve it and run
'git rebase --continue' until it finishes), then run this script again with the same arguments;
it resumes at the checks while $new is checked out. To undo everything:
  git rebase --abort 2>/dev/null; $undo; rm -rf "$tmp"
EOF
  else
    rm -rf "$tmp"  # stopped before it changed anything
  fi
}
trap on_exit EXIT

if [ "$resume" = 1 ]; then
  echo "==> $new is checked out and no rebase is in progress: resuming at the checks"
else
  if [ -n "$prev" ]; then
    echo "==> $new has origin/$src up to ${adopted:0:7}: re-committing the commits after it on top of $new"
    undo="git switch $new; git reset --hard $prev"
    [ "$start" = "$new" ] || undo="$undo; git switch $start"
    onto=$prev upstream=$adopted
  else
    undo="git switch $start; git branch -D $new"
    onto="origin/$base" upstream="origin/$base"
  fi
  git switch --no-track -C "$new" "origin/$src"
  printf '%s\n' "$tip" >"$tmp/tip"
  printf '%s\n' "$undo" >"$tmp/undo"
  printf '%s\n' "$src $new $base" >"$tmp/run"
  # Each commit: strip attribution lines from its message, then re-commit it as you (author and
  # committer). --allow-empty keeps commits that were empty on purpose (e.g. to trigger CI).
  clean="m=\$(mktemp) && git log -1 --format=%B >\"\$m\" && ATTRIBUTION_GUARD_MODE=strip sh '$tmp/attribution-guard.sh' commit-msg \"\$m\" && git commit -q --amend --allow-empty --reset-author --cleanup=whitespace -F \"\$m\"; rc=\$?; rm -f \"\$m\"; exit \$rc"
  GIT_COMMITTER_NAME=$me_name GIT_COMMITTER_EMAIL=$me_mail git rebase -r --exec "$clean" --onto "$onto" "$upstream"
fi

echo "==> checking the result"
bad=0
if git log --format=%B "origin/$base..HEAD" | sh "$tmp/attribution-guard.sh" check >/dev/null; then :; else
  echo "attribution left in a commit message" >&2; bad=1
fi
if git log --format='%ae %ce' "origin/$base..HEAD" | grep -Eiq '@anthropic\.com'; then
  echo "a commit still has the vendor identity" >&2; bad=1
fi
[ "$bad" = 0 ] || { echo "fix the listed problems on branch $new before pushing" >&2; exit 1; }

git push -u origin "$new"
git config "branch.$new.adoptedCommit" "$tip"
done_ok=1
rm -rf "$tmp"
remote_url=$(git remote get-url origin)
slug=$(printf '%s\n' "$remote_url" | sed -nE 's#^(https?://([^@/]*@)?github\.com/|ssh://git@github\.com/|git@github\.com:)##p' | sed -E 's#/$##; s#\.git$##')
if [ -n "$slug" ]; then
  echo "==> open the PR yourself: https://github.com/$slug/compare/$base...$new"
else
  echo "==> open the PR yourself from branch $new into $base"
fi
printf 'Delete the cloud branch origin/%s now? [y/N] ' "$src"
read -r answer || answer=
case $answer in y | Y | yes) git push origin --delete "$src" ;; *) echo "kept origin/$src" ;; esac
