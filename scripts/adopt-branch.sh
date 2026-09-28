#!/usr/bin/env bash
# Take over a branch that a Claude Code cloud session pushed, BEFORE opening a PR for it.
# Cloud sessions commit as the vendor identity (committer, and author unless the SessionStart hook
# fixed it) on a claude/ branch. This re-commits every commit on a branch of your own, with you as
# author and committer and attribution lines stripped, pushes it, and offers to delete the old one.
# Run it on your own machine:
#   bash scripts/adopt-branch.sh <cloud-branch> [new-branch] [base]
#   bash scripts/adopt-branch.sh claude/setup-analyse-optimalisatie-1gy14n setup-analyse main
# Then open the PR from the new branch (compare link printed at the end). GitHub may keep the old
# commits reachable by SHA for a while; GitHub Support can purge them.
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

# The guard from this checkout, copied out: older commits on the branch may not contain it.
here=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$here/tools/attribution-guard/attribution-guard.sh" "$here/tools/attribution-guard/patterns.ere" "$tmp/"

git fetch origin "$src" "$base"
git switch -c "$new" "origin/$src"
# Each commit: strip attribution lines from its message, then re-commit it as you (author and committer).
clean="m=\$(mktemp) && git log -1 --format=%B >\"\$m\" && ATTRIBUTION_GUARD_MODE=strip sh '$tmp/attribution-guard.sh' commit-msg \"\$m\" && git commit -q --amend --reset-author --cleanup=strip -F \"\$m\"; rc=\$?; rm -f \"\$m\"; exit \$rc"
GIT_COMMITTER_NAME=$me_name GIT_COMMITTER_EMAIL=$me_mail git rebase -r --exec "$clean" "origin/$base"

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
remote_url=$(git remote get-url origin)
slug=$(printf '%s\n' "$remote_url" | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')
echo "==> open the PR yourself: https://github.com/$slug/compare/$base...$new"
printf 'Delete the cloud branch origin/%s now? [y/N] ' "$src"
read -r answer
case $answer in y | Y | yes) git push origin --delete "$src" ;; *) echo "kept origin/$src" ;; esac
