#!/usr/bin/env bash
# One-time GitHub settings that keep AI attribution out of main. Needs an admin token:
#   gh auth login    (then)    bash scripts/github-hardening.sh [owner/repo]
# Idempotent; prints what it changes. Agents cannot run this: cloud tokens lack Administration.
set -euo pipefail
R=${1:-lucas4790/my-claude-skills}
command -v gh >/dev/null || { echo "gh (GitHub CLI) is required: https://cli.github.com" >&2; exit 1; }

echo "==> $R: squash-only merges; squash commit = PR title, empty body; delete merged branches"
# PR descriptions (where footers live) and branch commit messages then never reach main.
gh api -X PATCH "repos/$R" --silent \
  -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=BLANK \
  -F delete_branch_on_merge=true

echo "==> require the attribution-guard status check on main (next to validate-pr)"
if gh api "repos/$R/branches/main/protection/required_status_checks" >/dev/null 2>&1; then
  gh api -X POST "repos/$R/branches/main/protection/required_status_checks/contexts" --silent \
    --input - <<<'{"contexts": ["attribution-guard"]}'
else
  echo "    main has no classic protection with required checks; adding attribution-guard via the ruleset below"
  extra_check=1
fi

echo "==> ruleset 'Default' on the default branch: no deletion, no force-push, PRs squash-only"
rid=$(gh api "repos/$R/rulesets" --jq '.[] | select(.name == "Default") | .id' | head -n 1)
rules='[{"type":"deletion"},{"type":"non_fast_forward"},
  {"type":"pull_request","parameters":{"allowed_merge_methods":["squash"],"dismiss_stale_reviews_on_push":false,
   "require_code_owner_review":false,"require_last_push_approval":false,"required_approving_review_count":0,
   "required_review_thread_resolution":false}}'
if [ "${extra_check:-0}" = 1 ]; then
  rules="$rules"',{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,
   "required_status_checks":[{"context":"attribution-guard"},{"context":"validate-pr"}]}}'
fi
body=$(printf '{"name":"Default","target":"branch","enforcement":"active","bypass_actors":[],
  "conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":%s]}' "$rules")
if [ -n "$rid" ]; then
  gh api -X PUT "repos/$R/rulesets/$rid" --silent --input - <<<"$body"
else
  gh api -X POST "repos/$R/rulesets" --silent --input - <<<"$body"
fi

echo "==> current merge settings:"
gh api "repos/$R" --jq '{allow_squash_merge, allow_merge_commit, allow_rebase_merge, squash_merge_commit_title, squash_merge_commit_message, delete_branch_on_merge}'
echo "Done. Not available on personal repos (GitHub Enterprise only): commit-message and author-email metadata rules."
