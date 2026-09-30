#!/usr/bin/env bash
# Runs the bash steps of the generated pipelines (gen.py --extract) against mockado.py, with the
# environment the agent would provide. Needs bash 4+, curl, jq, python3, git.
# ok/ko never fail, so `test && ok || ko` is a safe if/else here.
# shellcheck disable=SC2015,SC2016
set -u
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH='' cd -- "$here/../../../.." && pwd)
work=$(mktemp -d)
cleanup() { for f in "$work"/pid-*; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done; rm -rf "$work"; }
trap cleanup EXIT
ex="$work/extract"
python3 "$here/../gen.py" --extract "$ex" >/dev/null || { echo "gen.py --extract failed"; exit 1; }
pass=0 failn=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
ko() { echo "FAIL $1"; failn=$((failn + 1)); }
start() {
  : >"$work/req-$1.log"
  SCENARIO=$1 MOCK_LOG="$work/req-$1.log" python3 "$here/mockado.py" "$2" &
  echo $! >"$work/pid-$1"
  for _ in $(seq 50); do curl -s "http://127.0.0.1:$2/" >/dev/null 2>&1 && break; sleep 0.1; done
}
stop() { kill "$(cat "$work/pid-$1")" 2>/dev/null; wait "$(cat "$work/pid-$1")" 2>/dev/null; rm -f "$work/pid-$1"; }
P=11111111-2222-3333-4444-555555555555; R=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
agent_env() { # $1 port; the guard repository checkout is this repository
  export SYSTEM_ACCESSTOKEN=test-token COLLECTION_URI="http://127.0.0.1:$1/org/" SYSTEM_COLLECTIONURI="http://127.0.0.1:$1/org/" \
    SYSTEM_TEAMPROJECTID=99999999-9999-9999-9999-999999999999 BUILD_BUILDID=42 \
    BUILD_SOURCESDIRECTORY="$root" PATTERN_FILE="$root/tools/attribution-guard/patterns.ere" \
    GUARD_STATUS=1 GUARD_SANITIZE=1 GUARD_REPOS="${P^^}/${R^^} 00000000-0000-0000-0000-000000000000/00000000-0000-0000-0000-000000000001"
  export HOOK_PR_ID='' HOOK_PR_ID2='' HOOK_REPO_ID='' HOOK_REPO_ID2='' HOOK_PROJECT_ID='' HOOK_PROJECT_ID2=''
}
status_step="$ex/attribution-guard-status.yml.step1.sh"
sweep_step="$ex/attribution-guard-sweep.yml.step1.sh"

# a) "Pull request updated" payload shape (resource.pullRequestId, resource.repository.id)
start clean 18091; agent_env 18091
out=$(HOOK_PR_ID=7 HOOK_REPO_ID=$R HOOK_PROJECT_ID=$P bash "$status_step" 2>&1); rc=$?
[ $rc -eq 0 ] && grep '"POST"' "$work/req-clean.log" | jq -r .body | grep -q '"state": "succeeded"' \
  && ok "PR-updated event -> guard ran, status succeeded" || { ko "hook a rc=$rc"; echo "$out"; }
grep '"POST"' "$work/req-clean.log" | jq -r '.body|fromjson|.targetUrl' | tail -1 | grep -q '/_build/results?buildId=42' && ok "status links to the run" || ko "targetUrl"
stop clean

# b) "Pull request commented on" payload shape (resource.pullRequest.*), dirty PR
start dirty 18092; agent_env 18092
out=$(HOOK_PR_ID2=7 HOOK_REPO_ID2=$R HOOK_PROJECT_ID2=$P bash "$status_step" 2>&1); rc=$?
[ $rc -eq 1 ] && [ "$(grep '"POST"' "$work/req-dirty.log" | tail -1 | jq -r '.body|fromjson|.state')" = failed ] \
  && ok "comment event -> status failed" || { ko "hook b rc=$rc"; echo "$out"; }
stop dirty

# c) repository not allow-listed -> no API call at all
start clean 18093; agent_env 18093
out=$(HOOK_PR_ID=7 HOOK_REPO_ID=bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee HOOK_PROJECT_ID=$P bash "$status_step" 2>&1); rc=$?
[ $rc -eq 0 ] && ! grep -q '_apis' "$work/req-clean.log" && ok "foreign repo ignored without API calls" || { ko "hook c rc=$rc"; echo "$out"; }
# d) forged payload with an injection attempt in the id -> rejected before any API call (rc 2)
out=$(HOOK_PR_ID='7; curl evil' HOOK_REPO_ID=$R HOOK_PROJECT_ID=$P bash "$status_step" 2>&1); rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q 'without a valid pull request id' && ok "non-numeric PR id rejected" || { ko "hook d rc=$rc"; echo "$out"; }
stop clean

# e) sweep: lists active PRs of each allow-listed repo and checks each
start dirty 18095; agent_env 18095
out=$(GUARD_REPOS="$P/$R" bash "$sweep_step" 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "== $P/$R PR 7" && ok "sweep checks active PR 7 and fails the run" || { ko "sweep rc=$rc"; echo "$out"; }
grep -q 'pullrequests?searchCriteria.status=active&$top=1000&api-version=7.1' "$work/req-dirty.log" && ok "sweep list URL" || ko "sweep url"
stop dirty

# f) build-validation "Load patterns" step: target branch file wins, else the embedded default
mk() { # $1 dir; a PR merge commit whose PR branch edits (or has no) patterns file
  git init -q "$1" && cd "$1" && git checkout -q -b main && git config user.email d@example.com && git config user.name D
}
export AGENT_TEMPDIRECTORY="$work/agent"; mkdir -p "$AGENT_TEMPDIRECTORY"
( mk "$work/g1" && mkdir -p tools/attribution-guard && echo target-pattern >tools/attribution-guard/patterns.ere \
  && git add . && git commit -qm init && git checkout -qb f && echo pr-weakened >tools/attribution-guard/patterns.ere \
  && git commit -qam "change patterns" && git checkout -q main && git merge -q --no-ff f -m merge ) >/dev/null 2>&1
(cd "$work/g1" && bash "$ex/attribution-guard.yml.step1.sh" >/dev/null) && [ "$(cat "$AGENT_TEMPDIRECTORY/attribution-patterns.ere")" = target-pattern ] \
  && ok "patterns taken from HEAD^1 (target), PR edit ignored" || ko "patterns from target"
( mk "$work/g2" && echo a >a && git add a && git commit -qm i && git checkout -qb f && echo b >b && git add b \
  && git commit -qm b && git checkout -q main && git merge -q --no-ff f -m m ) >/dev/null 2>&1
(cd "$work/g2" && bash "$ex/attribution-guard.yml.step1.sh" >/dev/null) \
  && cmp -s <(sed -n 1p "$root/tools/attribution-guard/patterns.ere") "$AGENT_TEMPDIRECTORY/attribution-patterns.ere" \
  && ok "embedded default pattern used when target has none" || ko "embedded default"

# g) build-validation guard step (the embedded copy) in git mode against the dirty mock
start clean 18096; agent_env 18096
export PROJECT_ID=$P REPO_ID=$R PR_ID=7 GUARD_GIT_RANGE='HEAD^1..HEAD^2' PATTERN_FILE="$AGENT_TEMPDIRECTORY/attribution-patterns.ere"
unset GUARD_STATUS
sed -n 1p "$root/tools/attribution-guard/patterns.ere" >"$PATTERN_FILE"
out=$(cd "$work/g2" && bash "$ex/attribution-guard.yml.step2.sh" 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q '1 commit(s)' && ok "embedded guard step runs in git mode" || { ko "embedded guard rc=$rc"; echo "$out"; }
stop clean

# h) push audit on the protected branch: every commit since the one the previous run checked
#    (read from the Builds API); patterns from the branch itself (a neutral marker here).
( mk "$work/g3" && mkdir -p tools/attribution-guard && echo forbidden-marker >tools/attribution-guard/patterns.ere \
  && git add . && git commit -qm init && echo a >a && git add a && git commit -qm "Merged PR 8: clean" ) >/dev/null 2>&1
audit() { # $1 = previous checked commit ("" = first run); runs the audit step against the mock
  # patterns come from the previous commit (the neutral marker) or, on a first run, the real default
  export MOCK_PREV_SHA=$1
  if [ -n "${CANARY:-}" ]; then export ATTRIB_CANARY=$CANARY
  elif [ -n "$1" ]; then export ATTRIB_CANARY=FORBIDDEN-MARKER
  else unset ATTRIB_CANARY; fi
  start clean 18097; agent_env 18097
  out=$(cd "$work/g3" && SYSTEM_TEAMPROJECTID=$P SYSTEM_DEFINITIONID=5 BUILD_SOURCEBRANCH=refs/heads/main \
    BUILD_SOURCEBRANCHNAME=main bash "$ex/attribution-audit.yml.step1.sh" 2>&1); rc=$?
  stop clean
}
audit ''
[ $rc -eq 0 ] && echo "$out" | grep -q 'First run' && ok "audit: first run checks the latest commit" || { ko "audit first rc=$rc"; echo "$out"; }
c1=$(git -C "$work/g3" rev-parse HEAD)
( cd "$work/g3" && echo b >b && git add b && git commit -qm "Merged PR 9: x" -m "Forbidden-Marker in the completion dialog" \
  && echo c >c && git add c && git commit -qm "Merged PR 10: clean" ) >/dev/null 2>&1
audit "$c1"
[ $rc -eq 1 ] && echo "$out" | grep -q 'Checked 2 commit(s)' && echo "$out" | grep -q 'in commit [0-9a-f]\{8\}, line(s) 3' \
  && ! echo "$out" | grep -qi 'forbidden-marker' \
  && ok "audit: a bad commit below a clean HEAD is flagged by line, text not echoed" || { ko "audit range rc=$rc"; echo "$out"; }
grep -q '/_apis/build/builds?definitions=5&branchName=refs/heads/main&statusFilter=completed' "$work/req-clean.log" \
  && ok "audit: previous run looked up for this pipeline and branch" || ko "audit builds URL"
c3=$(git -C "$work/g3" rev-parse HEAD)
( cd "$work/g3" && echo d >d && git add d && GIT_COMMITTER_EMAIL=bot@anthropic.com git commit -qm "Direct push" ) >/dev/null 2>&1
audit "$c3"
[ $rc -eq 1 ] && echo "$out" | grep -q 'vendor identity as committer' && echo "$out" | grep -q 'Checked 1 commit(s)' \
  && ok "audit: vendor committer flagged, only new commits checked" || { ko "audit committer rc=$rc"; echo "$out"; }
audit 0123456789abcdef0123456789abcdef01234567
[ $rc -eq 2 ] && echo "$out" | grep -q 'not in the fetched history' && ok "audit: unknown previous commit fails closed" || { ko "audit unknown prev rc=$rc"; echo "$out"; }
grep -q 'tagFilters=attribution-audited' "$work/req-clean.log" && ok "audit: baseline is the last run that finished the check (tag)" || ko "audit tagFilters"
c4=$(git -C "$work/g3" rev-parse HEAD)
audit "$c4"
[ $rc -eq 0 ] && echo "$out" | grep -q '##vso\[build.addbuildtag\]attribution-audited' && ok "audit: a finished check tags its run" || { ko "audit tag rc=$rc"; echo "$out"; }
# a push that weakens the patterns is still judged by the patterns of the last checked commit
( cd "$work/g3" && echo zzz >tools/attribution-guard/patterns.ere && git commit -qam "Tune patterns" \
  && echo e >e && git add e && git commit -qm "Merged PR 11: x" -m "Forbidden-Marker again" ) >/dev/null 2>&1
audit "$c4"
[ $rc -eq 1 ] && echo "$out" | grep -q 'Checked 2 commit(s)' && ok "audit: patterns come from the last checked commit, not the push" || { ko "audit patterns source rc=$rc"; echo "$out"; }
# a slower run for an older push finds that a later run already covered it
audit "$(git -C "$work/g3" rev-parse HEAD)"
old=$(cd "$work/g3" && git rev-parse HEAD~1); ( cd "$work/g3" && git checkout -q "$old" ) >/dev/null 2>&1
audit "$(git -C "$work/g3" rev-parse main)"
[ $rc -eq 0 ] && echo "$out" | grep -q 'already checked' && ok "audit: out-of-order run exits clean" || { ko "audit out-of-order rc=$rc"; echo "$out"; }
( cd "$work/g3" && git checkout -q main ) >/dev/null 2>&1
CANARY='this never matches' audit ''
[ $rc -eq 2 ] && echo "$out" | grep -q 'self-test' && ok "audit: a pattern that fails its self-test fails closed" || { ko "audit canary rc=$rc"; echo "$out"; }
echo "passed=$pass failed=$failn"
[ $failn -eq 0 ]
