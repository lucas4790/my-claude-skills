#!/usr/bin/env bash
# One-time GitHub settings that keep AI attribution out of main. Needs an admin token:
#   gh auth login    (then)    bash scripts/github-hardening.sh [owner/repo]
# Run it AFTER the PR that adds .github/workflows/attribution-guard.yml is merged (see
# docs/ATTRIBUTION.md, "One-time steps"). Idempotent; prints what it changes. Agents cannot run
# this: cloud tokens lack Administration, and this repository's hooks deny gh api writes.
set -euo pipefail
R=${1:-lucas4790/my-claude-skills}
command -v gh >/dev/null || { echo "gh (GitHub CLI) is required: https://cli.github.com" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

# The check below is only ever reported by .github/workflows/attribution-guard.yml ON THE DEFAULT
# BRANCH (pull_request_target). Requiring it earlier leaves every open PR waiting forever.
if ! gh api "repos/$R/contents/.github/workflows/attribution-guard.yml" --silent 2>/dev/null; then
  echo "attribution-guard.yml is not on the default branch of $R yet: merge that PR first, then run this." >&2
  exit 1
fi

echo "==> $R: squash-only merges; squash commit = PR title, empty body; no auto-merge; delete merged branches"
# PR descriptions (where footers live) and branch commit messages then never reach main.
gh api -X PATCH "repos/$R" --silent \
  -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=BLANK \
  -F allow_auto_merge=false -F delete_branch_on_merge=true

echo "==> require the attribution-guard status check on main (next to validate-pr)"
if gh api "repos/$R/branches/main/protection/required_status_checks" >/dev/null 2>&1; then
  gh api -X POST "repos/$R/branches/main/protection/required_status_checks/contexts" --silent \
    --input - <<<'{"contexts": ["attribution-guard"]}'
else
  echo "    main has no classic protection with required checks; adding attribution-guard via the ruleset below"
  extra_check=1
fi

echo "==> ruleset 'Default' on the default branch: no deletion, no force-push, PRs squash-only"
# Only these rules are set; every other rule, the bypass list and other branch conditions of an
# existing 'Default' ruleset are kept.
ours=$(jq -n --argjson extra "${extra_check:-0}" '
  [{type: "deletion"}, {type: "non_fast_forward"},
   {type: "pull_request", parameters: {allowed_merge_methods: ["squash"], dismiss_stale_reviews_on_push: false,
     require_code_owner_review: false, require_last_push_approval: false, required_approving_review_count: 0,
     required_review_thread_resolution: false}}]
  + (if $extra == 1 then [{type: "required_status_checks", parameters: {strict_required_status_checks_policy: false,
       required_status_checks: [{context: "attribution-guard"}, {context: "validate-pr"}]}}] else [] end)')
rid=$(gh api "repos/$R/rulesets" --jq '.[] | select(.name == "Default") | .id' | head -n 1)
if [ -n "$rid" ]; then existing=$(gh api "repos/$R/rulesets/$rid")
else existing='{"name": "Default"}'; fi
body=$(jq --argjson ours "$ours" '
  def by_type(t): [.[] | select(.type == t)][0];
  . as $e | ($e.rules // []) as $r
  | ($ours | by_type("required_status_checks")) as $orsc | ($r | by_type("required_status_checks")) as $rsc
  | {name: "Default", target: "branch", enforcement: "active", bypass_actors: ($e.bypass_actors // []),
     conditions: {ref_name: {include: ((($e.conditions.ref_name.include // []) + ["~DEFAULT_BRANCH"]) | unique),
                             exclude: ($e.conditions.ref_name.exclude // [])}},
     rules: ([$r[] | select(.type as $t | ["deletion", "non_fast_forward", "pull_request", "required_status_checks"] | index($t) | not)]
       + [{type: "deletion"}, {type: "non_fast_forward"},
          {type: "pull_request", parameters: ((($r | by_type("pull_request")).parameters // ($ours | by_type("pull_request")).parameters)
                                              + {allowed_merge_methods: ["squash"]})}]
       + (if $rsc == null and $orsc == null then []
          else [{type: "required_status_checks", parameters: (($rsc.parameters // $orsc.parameters)
                 | .required_status_checks = (((.required_status_checks // []) + ($orsc.parameters.required_status_checks // [])) | unique_by(.context)))}]
          end))}' <<<"$existing")
echo "    rules before: $(jq -c '[(.rules // [])[].type]' <<<"$existing"); after: $(jq -c '[.rules[].type]' <<<"$body")"
echo "    bypass actors kept: $(jq -c '.bypass_actors' <<<"$body")"
if [ -n "$rid" ]; then
  gh api -X PUT "repos/$R/rulesets/$rid" --silent --input - <<<"$body"
else
  gh api -X POST "repos/$R/rulesets" --silent --input - <<<"$body"
fi

echo "==> current merge settings:"
gh api "repos/$R" --jq '{allow_squash_merge, allow_merge_commit, allow_rebase_merge, allow_auto_merge, squash_merge_commit_title, squash_merge_commit_message, delete_branch_on_merge}'
cat <<EOF
Done. Not available on personal repos (GitHub Enterprise only): commit-message and author-email metadata rules.
If a PR can never get the attribution-guard check, drop the requirement, merge, and run this again:
  gh api -X DELETE repos/$R/branches/main/protection/required_status_checks/contexts --input - <<<'{"contexts":["attribution-guard"]}'
Rewriting main later needs the 'Default' ruleset disabled (and force-pushes allowed) first; run this again afterwards.
EOF
