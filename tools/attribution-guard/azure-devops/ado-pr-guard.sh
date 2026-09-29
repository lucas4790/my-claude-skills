#!/usr/bin/env bash
# ado-pr-guard.sh - fail when an Azure DevOps pull request carries AI attribution or a chat/session link.
# Checks: PR title, PR description, auto-complete merge commit message, every commit message, commit
# author and committer (an @anthropic.com address), every non-system PR comment (all threads, all replies).
# Strict: text inside `code` or fenced blocks counts too. Logs name only the location and line,
# never the matched text, so the guard does not republish what it blocks.
# Bash 4+, curl >= 7.76, jq, awk, sed, sha256sum; git only when GUARD_GIT_RANGE is set.
#
# Required env: COLLECTION_URI (System.CollectionUri), PROJECT_ID (GUID), REPO_ID (GUID of the PR's
#   target repository), PR_ID (number), SYSTEM_ACCESSTOKEN (bearer token; mapped explicitly in YAML).
# Pattern: ATTRIB_RE (one ERE line), or PATTERN_FILE (first line is used). Never taken from the PR.
# Options:
#   GUARD_GIT_RANGE=HEAD^1..HEAD^2  read commits from the local merge-commit checkout (full messages)
#                                   instead of the REST API (build validation runs on the PR merge commit)
#   GUARD_SANITIZE=1                remove attribution lines from the description (PATCH), then re-check
#   GUARD_STATUS=1                  post PR status attribution-guard/no-ai-attribution (pending -> result)
#   GUARD_TARGET_URL=<url>          link shown on that status (the pipeline run)
#   GUARD_ALLOW_VENDOR_COMMITTER=1  a vendor COMMITTER is a warning instead of an error
# Exit: 0 clean, 1 attribution found, 2 could not check (fails closed).
set -euo pipefail
export LC_ALL=C

# Untrusted text must never reach stdout as an agent logging command ("##vso[", "##[").
neutral() { sed -e 's/##/#-#/g' -e 's/\r//g' | tr '\n' ' '; }
die() { printf '##vso[task.logissue type=error]attribution-guard: %s\n' "$(printf '%s' "$1" | neutral)"; exit 2; }

: "${COLLECTION_URI:?}" "${PROJECT_ID:?}" "${REPO_ID:?}" "${PR_ID:?}" "${SYSTEM_ACCESSTOKEN:?}"
guid='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
[[ $PR_ID =~ ^[1-9][0-9]{0,9}$ ]] || die "PR_ID is not a pull request id (run this as build validation)."
[[ $PROJECT_ID =~ $guid ]] || die "PROJECT_ID is not a GUID."
[[ $REPO_ID =~ $guid ]] || die "REPO_ID is not a GUID."
[[ $COLLECTION_URI =~ ^https?://[^[:space:]]+$ ]] || die "COLLECTION_URI is not a URL."
[[ $COLLECTION_URI == */ ]] || COLLECTION_URI="$COLLECTION_URI/"

if [[ -z ${ATTRIB_RE:-} ]]; then
  [[ -r ${PATTERN_FILE:-} ]] || die "no ATTRIB_RE and no readable PATTERN_FILE."
  ATTRIB_RE=$(sed -n '1p' "$PATTERN_FILE")
fi
[[ -n $ATTRIB_RE ]] || die "empty attribution pattern."
IDENT_RE=${IDENT_RE:-'@anthropic\.com$'}   # matched against e-mail addresses only
export ATTRIB_RE IDENT_RE

API=7.1
PR_URL="${COLLECTION_URI}${PROJECT_ID}/_apis/git/repositories/${REPO_ID}/pullRequests/${PR_ID}"
REPO_URL="${COLLECTION_URI}${PROJECT_ID}/_apis/git/repositories/${REPO_ID}"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# api METHOD URL [extra curl args...]: body on stdout; exits non-zero on HTTP >= 400.
api() {
  local m=$1 u=$2; shift 2
  curl -sS --fail-with-body --retry 3 --retry-all-errors --max-time 60 \
    -H "Authorization: Bearer ${SYSTEM_ACCESSTOKEN}" -H 'Accept: application/json' \
    -X "$m" "$@" "$u"
}

# The matcher of the GitHub workflows too (tools/attribution-guard/match.awk, one directory up;
# gen.py embeds it in the generated pipeline). mode=report prints the line number of each hit;
# mode=strip prints the text without hit lines. Every mode fails (exit 2) when the pattern does not
# compile or fails its self-test (ATTRIB_CANARY replaces the known trailer it must match).
ATTRIB_AWK=$(cat "$(dirname "${BASH_SOURCE[0]}")/../match.awk") || die "tools/attribution-guard/match.awk is missing."
# A pattern that does not compile would make every check pass: refuse instead (fail closed).
awk -v mode=selftest "$ATTRIB_AWK" </dev/null 2>/dev/null \
  || die "the attribution pattern does not compile or fails its self-test."

fail=0
scan() { # $1 = where, $2 = file
  local ln
  awk -v mode=report "$ATTRIB_AWK" "$2" > "$T/hits" 2>/dev/null || die "could not scan the $1."
  while IFS= read -r ln; do
    [[ -n $ln ]] || continue
    printf '##vso[task.logissue type=error]AI attribution in %s, line %s\n' "$1" "$ln"
    fail=1
  done < "$T/hits"
}

# --- PR status (optional) -----------------------------------------------------------------------
status_iter=
post_status() { # $1 = state, $2 = description
  [[ ${GUARD_STATUS:-0} == 1 ]] || return 0
  jq -n --arg s "$1" --arg d "$2" --arg u "${GUARD_TARGET_URL:-}" --argjson it "${status_iter:-null}" '
    {state: $s, description: $d, context: {genre: "attribution-guard", name: "no-ai-attribution"}}
    + (if $u != "" then {targetUrl: $u} else {} end)
    + (if $it != null then {iterationId: $it} else {} end)' > "$T/status.json"
  api POST "$PR_URL/statuses?api-version=$API" -H 'Content-Type: application/json' \
    --data-binary "@$T/status.json" > /dev/null
}
if [[ ${GUARD_STATUS:-0} == 1 ]]; then
  # Post on the latest iteration so "Reset status whenever there are new changes" invalidates it on push.
  status_iter=$(api GET "$PR_URL/iterations?api-version=$API" | jq '[.value[].id] | max // empty')
  [[ -n ${GUARD_RERUN:-} ]] || post_status pending "Checking for AI attribution"
  on_exit() { # exit 1 = findings (status already posted); >= 2 = could not check
    local rc=$?
    if [[ $rc -ge 2 ]]; then post_status error "attribution-guard could not complete" || true; fi
    rm -rf "$T"
  }
  trap on_exit EXIT
fi

# Everything the verdict depends on, for the "changed while checking" test at the end. Called as
# `fingerprint now`: without an argument, Azure Pipelines would expand the command substitution
# as a macro in the generated pipeline (gen.py refuses to generate one).
fingerprint() {
  { api GET "$PR_URL?api-version=$API" \
      | jq -S '{title, description, m: .completionOptions.mergeCommitMessage, h: .lastMergeSourceCommit.commitId}'
    api GET "$PR_URL/threads?api-version=$API" \
      | jq -S '[.value[] | select(.isDeleted != true) | .comments[]? | select(.isDeleted != true) | [.id, .content]]'
  } | sha256sum | cut -d' ' -f1
}
before=$(fingerprint now)

# --- Pull request: title, description, merge commit message ------------------------------------
get_pr() { api GET "$PR_URL?api-version=$API" > "$T/pr.json"; }
get_pr
jq -e --argjson id "$PR_ID" --arg repo "$REPO_ID" \
  '.pullRequestId == $id and (.repository.id | ascii_downcase) == ($repo | ascii_downcase)' \
  "$T/pr.json" > /dev/null || die "the PR does not belong to the configured repository."

jq -j '.description // ""' "$T/pr.json" > "$T/body.md"
if [[ ${GUARD_SANITIZE:-0} == 1 ]] && [[ -n $(awk -v mode=report "$ATTRIB_AWK" "$T/body.md") ]]; then
  awk -v mode=strip "$ATTRIB_AWK" "$T/body.md" > "$T/clean.md"
  jq -n --rawfile d "$T/clean.md" '{description: $d}' > "$T/patch.json"
  if api PATCH "$PR_URL?api-version=$API" -H 'Content-Type: application/json' \
      --data-binary "@$T/patch.json" > /dev/null; then
    echo "Removed attribution lines from the PR description."
    get_pr  # re-check what is actually stored now
    jq -j '.description // ""' "$T/pr.json" > "$T/body.md"
    before=$(fingerprint now)
  else
    echo "##vso[task.logissue type=warning]Could not edit the description (needs 'Contribute to pull requests')."
  fi
fi

jq -j '.title // ""' "$T/pr.json" > "$T/title.txt"
scan "PR title" "$T/title.txt"
scan "PR description" "$T/body.md"
jq -j '.completionOptions.mergeCommitMessage // ""' "$T/pr.json" > "$T/mcm.txt"
scan "auto-complete merge commit message" "$T/mcm.txt"

case $(jq -r '.sourceRefName // ""' "$T/pr.json") in
  refs/heads/claude/*) echo "##vso[task.logissue type=warning]The source branch carries the vendor prefix; rename it before opening the PR." ;;
esac

# --- Commits ------------------------------------------------------------------------------------
check_commit() { # $1 = short id, $2 = author email, $3 = committer email, $4 = message file
  scan "commit $1" "$4"
  if printf '%s\n' "$2" | grep -Eiq -e "$IDENT_RE"; then
    printf '##vso[task.logissue type=error]AI attribution in commit %s: authored by the vendor identity\n' "$1"
    fail=1
  fi
  if printf '%s\n' "$3" | grep -Eiq -e "$IDENT_RE"; then
    if [[ ${GUARD_ALLOW_VENDOR_COMMITTER:-0} == 1 ]]; then
      printf '##vso[task.logissue type=warning]commit %s is committed by the vendor identity (allowed by GUARD_ALLOW_VENDOR_COMMITTER).\n' "$1"
    else
      printf '##vso[task.logissue type=error]AI attribution in commit %s: committed by the vendor identity\n' "$1"
      fail=1
    fi
  fi
}

ncommits=0
if [[ -n ${GUARD_GIT_RANGE:-} ]]; then
  # Build validation checks out the PR merge commit: HEAD^1 = target, HEAD^2 = PR source head.
  [[ $(git rev-list --parents -n 1 HEAD | wc -w) -eq 3 ]] || die "HEAD is not the PR merge commit (set checkout fetchDepth: 0)."
  while IFS= read -r c; do
    git log -1 --format=%B "$c" > "$T/msg.txt"
    check_commit "${c:0:8}" "$(git log -1 --format=%ae "$c")" "$(git log -1 --format=%ce "$c")" "$T/msg.txt"
    ncommits=$((ncommits + 1))
  done < <(git rev-list "$GUARD_GIT_RANGE")
else
  token=
  : > "$T/commits.jsonl"
  while :; do
    q="\$top=500&api-version=$API"
    [[ -z $token ]] || q="continuationToken=$(jq -rn --arg t "$token" '$t|@uri')&$q"
    api GET "$PR_URL/commits?$q" -D "$T/h.txt" | jq -c '.value[]' >> "$T/commits.jsonl"
    token=$(awk 'tolower($0) ~ /^x-ms-continuationtoken:/ { sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); t = $0 } END { print t }' "$T/h.txt")
    [[ -n $token ]] || break
  done
  while IFS= read -r line; do
    printf '%s' "$line" > "$T/c.json"
    id=$(jq -r '.commitId' "$T/c.json")
    [[ $id =~ ^[0-9a-f]{40}$ ]] || die "unexpected commit id."
    if [[ $(jq -r '.commentTruncated // false' "$T/c.json") == true ]]; then
      api GET "$REPO_URL/commits/$id?api-version=$API" > "$T/c.json"
      [[ $(jq -r '.commentTruncated // false' "$T/c.json") != true ]] || die "commit ${id:0:8}: API returns a truncated message; cannot verify it."
    fi
    jq -j '.comment // ""' "$T/c.json" > "$T/msg.txt"
    check_commit "${id:0:8}" "$(jq -r '.author.email // ""' "$T/c.json")" \
      "$(jq -r '.committer.email // ""' "$T/c.json")" "$T/msg.txt"
    ncommits=$((ncommits + 1))
  done < "$T/commits.jsonl"
fi

# --- Comment threads (every non-system comment, including replies and edits) --------------------
api GET "$PR_URL/threads?api-version=$API" > "$T/threads.json"
jq -c '.value[] | select(.isDeleted != true) | .id as $t | .comments[]?
       | select(.isDeleted != true and .commentType != "system")
       | {t: $t, c: .id, content: (.content // "")}' "$T/threads.json" > "$T/comments.jsonl"
ncomments=0
while IFS= read -r line; do
  printf '%s' "$line" | jq -j '.content' > "$T/comment.md"
  scan "comment $(printf '%s' "$line" | jq -r '"\(.t)/\(.c)"')" "$T/comment.md"
  ncomments=$((ncomments + 1))
done < "$T/comments.jsonl"

# The PR (text, head commit or comments) changed while it was being checked: check it again, so a
# verdict about an older state never becomes the last status posted.
if [[ $(fingerprint now) != "$before" ]]; then
  n=${GUARD_RERUN:-0}
  [[ $n -lt 3 ]] || die "the pull request keeps changing while it is being checked; re-run later."
  echo "The pull request changed while it was being checked; checking it again."
  trap - EXIT; rm -rf "$T"
  GUARD_RERUN=$((n + 1)) exec bash "$0"
fi

echo "Checked PR $PR_ID: title, description, merge message, $ncommits commit(s), $ncomments comment(s)."
if [[ $fail -ne 0 ]]; then
  post_status failed "AI attribution found; see the run log"
  cat <<'EOF'
Fix: edit the PR title/description, delete or edit the flagged comments, and rewrite the flagged
commits as yourself (author and committer):
  git rebase -r --exec 'git commit --amend --no-edit --reset-author' origin/<target>
with the attribution-guard commit-msg hook installed (strip mode), then force-push the branch.
EOF
  exit 1
fi
post_status succeeded "No AI attribution found"
echo "No AI attribution found."
