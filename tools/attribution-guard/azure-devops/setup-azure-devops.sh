#!/usr/bin/env bash
# One-time setup of the attribution guard for an Azure DevOps Services work repository.
# Run by an administrator of the work project (and of the guard project for layer 2):
#   az login && az extension add --name azure-devops
#   ORG_NAME=contoso WORK_PROJECT='Work Project' WORK_REPO=work-repo \
#   AUTHOR_EMAIL_PATTERNS='*@contoso.com' REVIEWER=you@contoso.com \
#   [GUARD_PROJECT=Guard GUARD_REPO=attribution-guard] [DRY_RUN=1] \
#   bash tools/attribution-guard/azure-devops/setup-azure-devops.sh
# DRY_RUN=1 prints every change instead of making it (reads still run). Re-running updates what
# exists instead of adding duplicates. Not tested against a live organization: review it with
# DRY_RUN=1 first. Before running, commit pipelines/attribution-guard.yml and
# pipelines/attribution-audit.yml to the work repository as .azure-pipelines/*.yml.
#
# Layer 0  repository policy "Commit author email validation": pushes whose commit AUTHOR does not
#          match AUTHOR_EMAIL_PATTERNS are rejected (the vendor address never matches a company domain).
# Layer 1  squash-only merges; required build validation (PR title, description, merge message,
#          commits, comments); a required reviewer for changes to the guard files; a push audit on BRANCH.
# Layer 2  (GUARD_PROJECT set) a required PR status posted only by the guard project's build service,
#          re-checked on every PR created/updated/commented event and by a sweep every 30 minutes.
set -euo pipefail

: "${ORG_NAME:?dev.azure.com/<ORG_NAME>}" "${WORK_PROJECT:?}" "${WORK_REPO:?}" "${REVIEWER:?e-mail of who approves guard changes}"
: "${AUTHOR_EMAIL_PATTERNS:?e.g. *@contoso.com (use ; between patterns)}"
BRANCH=${BRANCH:-main}
GUARD_PROJECT=${GUARD_PROJECT:-}
GUARD_REPO=${GUARD_REPO:-attribution-guard}
DRY_RUN=${DRY_RUN:-0}
ORG="https://dev.azure.com/$ORG_NAME"
case $AUTHOR_EMAIL_PATTERNS in
  *anthropic.com* | *noreply@dev.azure.com*) echo "AUTHOR_EMAIL_PATTERNS must not allow vendor or service addresses" >&2; exit 1 ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mut() { # a change: run it, or print it with DRY_RUN=1
  if [ "$DRY_RUN" = 1 ]; then printf 'DRY RUN:' >&2; printf ' %q' "$@" >&2; echo >&2; echo dry-run-id
  else "$@"; fi
}
section() { printf '\n==> %s\n' "$*"; }

az devops configure --defaults organization="$ORG"
PROJECT_ID=$(az devops project show --project "$WORK_PROJECT" --query id -o tsv)
REPO_ID=$(az repos show --project "$WORK_PROJECT" --repository "$WORK_REPO" --query id -o tsv)
az repos policy list --project "$WORK_PROJECT" --repository-id "$REPO_ID" -o json >"$tmp/policies.json"
find_policy() { # $1 = policy type display name, $2 = extra jq condition on .settings
  jq -r --arg n "$1" "[.[] | select(.type.displayName == \$n) | select(.settings | ${2:-true})][0].id // empty" "$tmp/policies.json"
}
pipeline_id() { # $1 project, $2 name
  az pipelines list --project "$1" --name "$2" --query '[0].id' -o tsv 2>/dev/null || true
}

# --- Layer 0: commit author e-mail validation ------------------------------------------------------
section "author e-mail validation on $WORK_REPO: $AUTHOR_EMAIL_PATTERNS"
IFS=';' read -r -a patterns <<<"$AUTHOR_EMAIL_PATTERNS"
jq -n --arg r "$REPO_ID" '$ARGS.positional as $p | {isEnabled: true, isBlocking: true,
    type: {id: "77ed4bd3-b063-4689-934a-175e4d0a78d7"},
    settings: {authorEmailPatterns: $p, scope: [{repositoryId: $r}]}}' --args "${patterns[@]}" >"$tmp/author.json"
id=$(find_policy 'Commit author email validation')
if [ -n "$id" ]; then
  mut az repos policy update --project "$WORK_PROJECT" --id "$id" --config "$tmp/author.json" --query id -o tsv
else
  mut az repos policy create --project "$WORK_PROJECT" --config "$tmp/author.json" --query id -o tsv
fi

# --- Layer 1 ----------------------------------------------------------------------------------------
section "squash-only merges into $BRANCH"
id=$(find_policy 'Require a merge strategy')
merge_args=(--blocking true --enabled true --allow-squash true --allow-no-fast-forward false --allow-rebase false --allow-rebase-merge false)
if [ -n "$id" ]; then
  mut az repos policy merge-strategy update --project "$WORK_PROJECT" --id "$id" "${merge_args[@]}" --query id -o tsv
else
  mut az repos policy merge-strategy create --project "$WORK_PROJECT" --repository-id "$REPO_ID" --branch "$BRANCH" "${merge_args[@]}" --query id -o tsv
fi

section "pipelines attribution-guard (build validation) and attribution-audit (push audit)"
BV_ID=$(pipeline_id "$WORK_PROJECT" attribution-guard)
[ -n "$BV_ID" ] || BV_ID=$(mut az pipelines create --project "$WORK_PROJECT" --name attribution-guard \
  --repository "$WORK_REPO" --repository-type tfsgit --branch "$BRANCH" \
  --yml-path .azure-pipelines/attribution-guard.yml --skip-first-run true --query id -o tsv)
[ -n "$(pipeline_id "$WORK_PROJECT" attribution-audit)" ] || mut az pipelines create --project "$WORK_PROJECT" \
  --name attribution-audit --repository "$WORK_REPO" --repository-type tfsgit --branch "$BRANCH" \
  --yml-path .azure-pipelines/attribution-audit.yml --skip-first-run true --query id -o tsv

section "required build validation (re-queued when $BRANCH moves)"
# queue-on-source-update-only=false requires valid-duration 0.
bv_args=(--blocking true --enabled true --manual-queue-only false --queue-on-source-update-only false
  --valid-duration 0 --display-name attribution-guard --build-definition-id "$BV_ID")
id=$(find_policy 'Build' ".buildDefinitionId == ${BV_ID//[!0-9]/0}")
if [ -n "$id" ]; then
  mut az repos policy build update --project "$WORK_PROJECT" --id "$id" "${bv_args[@]}" --query id -o tsv
else
  mut az repos policy build create --project "$WORK_PROJECT" --repository-id "$REPO_ID" --branch "$BRANCH" "${bv_args[@]}" --query id -o tsv
fi

section "a PR that changes the guard files needs $REVIEWER"
paths='/.azure-pipelines/attribution-guard.yml;/.azure-pipelines/attribution-audit.yml;/tools/attribution-guard/*'
id=$(find_policy 'Required reviewers' '(.filenamePatterns // [] | index("/tools/attribution-guard/*")) != null')
if [ -z "$id" ]; then
  mut az repos policy required-reviewer create --project "$WORK_PROJECT" --repository-id "$REPO_ID" \
    --branch "$BRANCH" --blocking true --enabled true --path-filter "$paths" \
    --message 'Changes the attribution guard' --required-reviewer-ids "$REVIEWER" --query id -o tsv
fi

section "pipeline settings: job tokens limited to their own project and to referenced repositories"
jq -n '{enforceJobAuthScope: true, enforceJobAuthScopeForReleases: true, enforceReferencedRepoScopedToken: true}' >"$tmp/general.json"
for p in "$WORK_PROJECT" ${GUARD_PROJECT:+"$GUARD_PROJECT"}; do
  mut az devops invoke --area build --resource generalsettings --route-parameters project="$p" \
    --http-method PATCH --api-version 7.1 --in-file "$tmp/general.json" -o none \
    || echo "    could not update the pipeline settings of '$p'; set them under Project settings > Pipelines > Settings" >&2
done

# --- Layer 2: status pipelines in the protected guard project ----------------------------------------
if [ -n "$GUARD_PROJECT" ]; then
  section "layer 2 in $GUARD_PROJECT/$GUARD_REPO"
  cat <<EOF
Manual prerequisites (portal), before this part works:
 a) $GUARD_PROJECT > Project settings > Service connections > New > Incoming WebHook:
    WebHook Name 'attribution-guard', Service connection name 'attribution-guard-hook'.
 b) In $GUARD_REPO (an import of my-claude-skills), edit tools/attribution-guard/azure-devops/pipelines/
    attribution-guard-status.yml and -sweep.yml: repository resource 'WorkProject/WorkRepo' -> '$WORK_PROJECT/$WORK_REPO'
    and GUARD_REPOS -> '$PROJECT_ID/$REPO_ID'; commit to main.
 c) $WORK_REPO > Security > '$GUARD_PROJECT Build Service ($ORG_NAME)': Read = Allow,
    Contribute to pull requests = Allow (status posting and description sanitizing need it).
EOF
  for n in status sweep; do
    [ -n "$(pipeline_id "$GUARD_PROJECT" "attribution-guard-$n")" ] || mut az pipelines create --project "$GUARD_PROJECT" \
      --name "attribution-guard-$n" --repository "$GUARD_REPO" --repository-type tfsgit --branch main \
      --yml-path "tools/attribution-guard/azure-devops/pipelines/attribution-guard-$n.yml" --skip-first-run true --query id -o tsv
  done

  section "service hooks in $WORK_PROJECT -> incoming webhook -> attribution-guard-status"
  HOOK_URL="$ORG/_apis/public/distributedtask/webhooks/attribution-guard?api-version=6.0-preview"
  az devops invoke --area hooks --resource subscriptions --api-version 7.1 -o json >"$tmp/subs.json" 2>/dev/null || echo '{"value":[]}' >"$tmp/subs.json"
  for event in git.pullrequest.created git.pullrequest.updated ms.vss-code.git-pullrequest-comment-event; do
    if jq -e --arg e "$event" --arg u "$HOOK_URL" --arg r "$REPO_ID" \
        '.value[]? | select(.eventType == $e and .consumerInputs.url == $u and .publisherInputs.repository == $r)' "$tmp/subs.json" >/dev/null; then
      echo "    $event: already subscribed"; continue
    fi
    jq -n --arg e "$event" --arg p "$PROJECT_ID" --arg r "$REPO_ID" --arg u "$HOOK_URL" '{
        publisherId: "tfs", eventType: $e, resourceVersion: "1.0",
        consumerId: "webHooks", consumerActionId: "httpRequest",
        publisherInputs: {projectId: $p, repository: $r},
        consumerInputs: {url: $u}}' >"$tmp/sub.json"
    mut az devops invoke --area hooks --resource subscriptions --http-method POST \
      --api-version 7.1 --in-file "$tmp/sub.json" --query id -o tsv
  done

  section "required status attribution-guard/no-ai-attribution, only from the guard project's build service"
  AUTHOR_ID=$(az rest --method get --resource 499b84ac-1321-427f-aa17-267ca6975798 \
    --url "https://vssps.dev.azure.com/$ORG_NAME/_apis/identities?searchFilter=General&filterValue=$(jq -rn --arg s "$GUARD_PROJECT Build Service ($ORG_NAME)" '$s|@uri')&api-version=7.1" \
    --query 'value[0].id' -o tsv)
  [ -n "$AUTHOR_ID" ] || { echo "identity '$GUARD_PROJECT Build Service ($ORG_NAME)' not found" >&2; exit 1; }
  jq -n --arg r "$REPO_ID" --arg b "refs/heads/$BRANCH" --arg a "$AUTHOR_ID" '{
      isEnabled: true, isBlocking: true,
      type: {id: "cbdc66da-9728-4af8-aada-9a5a32e4a226"},
      settings: {
        statusGenre: "attribution-guard", statusName: "no-ai-attribution",
        authorId: $a, invalidateOnSourceUpdate: true, policyApplicability: null,
        defaultDisplayName: "attribution-guard (PR text)",
        scope: [{repositoryId: $r, refName: $b, matchKind: "Exact"}]}}' >"$tmp/status-policy.json"
  id=$(find_policy 'Status' '.statusGenre == "attribution-guard"')
  if [ -n "$id" ]; then
    mut az repos policy update --project "$WORK_PROJECT" --id "$id" --config "$tmp/status-policy.json" --query id -o tsv
  else
    mut az repos policy create --project "$WORK_PROJECT" --config "$tmp/status-policy.json" --query id -o tsv
  fi
fi

cat <<EOF

Done. Settings this script cannot make; check them by hand (docs/ATTRIBUTION.md, "Azure DevOps"):
 - $WORK_REPO > Settings: Forks = Off.
 - $WORK_REPO > Security: nobody but admins has "Bypass policies when completing pull requests" or
   "Bypass policies when pushing"; contributors have Deny on "Create tag" and "Manage notes".
 - Agents (Azure DevOps MCP server, az, PATs): Code (Read) and Work Items (Read) only, so an agent
   cannot push, open or complete pull requests or write comments; you do that yourself.
 - Nobody sets auto-complete with a prepared merge message; the completion dialog text is only
   checked afterwards by attribution-audit.
EOF
