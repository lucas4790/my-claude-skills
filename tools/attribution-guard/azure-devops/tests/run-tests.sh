#!/usr/bin/env bash
# Tests for ado-pr-guard.sh against mockado.py (a minimal Azure DevOps REST mock), several scenarios.
# Git-mode fixtures use neutral markers (FORBIDDEN-MARKER / bot@example.invalid) so no local commit
# ever carries real attribution text; the real patterns are covered by the API-mode scenarios.
# Needs bash 4+, curl, jq, python3, git.
# ok/ko never fail, so `test && ok || ko` is a safe if/else here.
# shellcheck disable=SC2015,SC2016
set -u
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
guard="$here/../ado-pr-guard.sh"
pat="$here/../../patterns.ere"
work=$(mktemp -d)
cleanup() { for f in "$work"/pid-*; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done; rm -rf "$work"; }
trap cleanup EXIT
pass=0 failn=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
ko() { echo "FAIL $1"; failn=$((failn + 1)); }
start() { # $1 scenario, $2 port
  : >"$work/req-$1.log"
  SCENARIO=$1 MOCK_LOG="$work/req-$1.log" python3 "$here/mockado.py" "$2" &
  echo $! >"$work/pid-$1"
  for _ in $(seq 50); do curl -s "http://127.0.0.1:$2/" >/dev/null 2>&1 && break; sleep 0.1; done
}
stop() { kill "$(cat "$work/pid-$1")" 2>/dev/null; wait "$(cat "$work/pid-$1")" 2>/dev/null; rm -f "$work/pid-$1"; }
common() {
  export COLLECTION_URI="http://127.0.0.1:$1/org" PROJECT_ID=11111111-2222-3333-4444-555555555555 \
    REPO_ID=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE PR_ID=7 SYSTEM_ACCESSTOKEN=test-token PATTERN_FILE=$pat
  unset ATTRIB_RE IDENT_RE GUARD_STATUS GUARD_SANITIZE GUARD_GIT_RANGE GUARD_TARGET_URL GUARD_RERUN GUARD_ALLOW_VENDOR_COMMITTER
}

# 1. clean PR, status mode, API commits with pagination + truncated commit
start clean 18081; common 18081
out=$(GUARD_STATUS=1 GUARD_TARGET_URL=https://example/run bash "$guard" 2>&1); rc=$?
[ $rc -eq 0 ] && ok "clean exits 0" || { ko "clean exits 0 (rc=$rc)"; echo "$out"; }
echo "$out" | grep -q '3 commit(s), 1 comment(s)' && ok "clean: 3 commits (2 pages), 1 live text comment" || { ko "clean counts"; echo "$out"; }
grep -q 'continuationToken=tok%2F2%2B%3D' "$work/req-clean.log" && ok "continuation token url-encoded and followed" || ko "continuation"
grep -q '/commits/3333333333333333333333333333333333333333' "$work/req-clean.log" && ok "truncated commit re-fetched" || ko "truncated refetch"
states=$(grep '"POST"' "$work/req-clean.log" | jq -r '.body|fromjson|"\(.state):\(.iterationId):\(.context.genre)/\(.context.name):\(.targetUrl)"' | tr '\n' ' ')
[ "$states" = "pending:2:attribution-guard/no-ai-attribution:https://example/run succeeded:2:attribution-guard/no-ai-attribution:https://example/run " ] \
  && ok "status pending->succeeded on latest iteration" || ko "status sequence: $states"
grep -q '"PATCH"' "$work/req-clean.log" && ko "clean must not PATCH" || ok "clean: no PATCH"
grep -v '"p": "/",' "$work/req-clean.log" | grep -v '"auth": "Bearer test-token"' | grep -q . && ko "request without bearer auth" || ok "every request sends Bearer token"
stop clean

# 2. dirty PR, status + sanitize
start dirty 18082; common 18082
out=$(GUARD_STATUS=1 GUARD_SANITIZE=1 bash "$guard" 2>&1); rc=$?
[ $rc -eq 1 ] && ok "dirty exits 1" || { ko "dirty exits 1 (rc=$rc)"; echo "$out"; }
for w in "auto-complete merge commit message, line 3" "commit 44444444, line 3" "commit 55555555: authored by the vendor identity" \
         "commit 55555555: committed by the vendor identity" "commit 66666666, line 4" "comment 3/1, line 1"; do
  echo "$out" | grep -qF -- "type=error]AI attribution in $w" && ok "dirty flags: $w" || ko "dirty flags: $w"
done
echo "$out" | grep -q 'AI attribution in PR description' && ko "description should be clean after sanitize" || ok "description sanitized before check"
body=$(grep '"PATCH"' "$work/req-dirty.log" | jq -r '.body|fromjson|.description')
[ "$body" = "Summary line" ] && ok "PATCH body strips all attribution lines and trailing blanks" || ko "PATCH body: [$body]"
echo "$out" | grep -q 'type=warning]The source branch carries the vendor prefix' && ok "branch prefix warning" || ko "branch warning"
echo "$out" | grep -qiE 'claude\.ai|claude\.com|noreply@|co-authored' && ko "matched text echoed into the log" || ok "log names places and lines only, never the text"
echo "$out" | grep -q '##vso\[task.complete' && ko "logging command injection not neutralized" || ok "no ##vso[task.complete injection in output"
last=$(grep '"POST"' "$work/req-dirty.log" | tail -1 | jq -r '.body|fromjson|.state')
[ "$last" = failed ] && ok "status failed posted" || ko "status last=$last"
stop dirty

# 3. dirty without sanitize flags the description (line 3 holds the injected logging command)
start dirty 18083; common 18083
out=$(GUARD_ALLOW_VENDOR_COMMITTER=1 bash "$guard" 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -qF 'AI attribution in PR description, line 3' && ok "description flagged by line number" || { ko "desc flag"; echo "$out"; }
echo "$out" | grep -qF 'type=warning]commit 55555555 is committed by the vendor identity' && ok "GUARD_ALLOW_VENDOR_COMMITTER turns the committer into a warning" || ko "committer allow"
grep -q '"POST"' "$work/req-dirty.log" && ko "no status without GUARD_STATUS" || ok "no status without GUARD_STATUS"
stop dirty

# 4. strict: attribution inside `code` and fenced blocks is flagged too
start quoted 18084; common 18084
out=$(bash "$guard" 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -qF 'AI attribution in PR description, line 3' && echo "$out" | grep -qF 'AI attribution in PR description, line 5' \
  && ok "strict: quoted and fenced attribution flagged" || { ko "quoted rc=$rc"; echo "$out"; }
stop quoted

# 5. the description changes while the check runs: the guard checks again and reports the new state
start flip 18085; common 18085
out=$(bash "$guard" 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q 'changed while it was being checked' && echo "$out" | grep -qF 'AI attribution in PR description' \
  && ok "mid-check edit: re-checked, final verdict covers the edit" || { ko "flip rc=$rc"; echo "$out"; }
stop flip

# 5b. a pattern that does not compile fails closed instead of passing everything
common 1; out=$(ATTRIB_RE='x|(' bash "$guard" 2>&1); rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q 'does not compile' && ok "broken pattern fails closed (rc 2)" || { ko "broken pattern rc=$rc"; echo "$out"; }

# 6. unset PR id macro (manual run) -> exit 2
common 1; out=$(PR_ID='$(System.PullRequest.PullRequestId)' bash "$guard" 2>&1); rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q 'is not a pull request id' && ok "manual run fails closed (rc 2)" || { ko "manual run rc=$rc"; echo "$out"; }

# 7. API error in status mode -> rc >= 2 (and an error status attempt)
start clean 18087; common 18087
out=$(REPO_ID=aaaaaaaa-bbbb-cccc-dddd-000000000000 GUARD_STATUS=1 bash "$guard" 2>&1); rc=$?
[ $rc -ge 2 ] && ok "API 404 fails closed (rc=$rc)" || { ko "api error rc=$rc"; echo "$out"; }
stop clean

# 8. git-range mode (build validation): merge commit HEAD^1 = target, HEAD^2 = source. Neutral markers.
g="$work/git"; mkdir -p "$g"
(
  cd "$g" && git init -q && git checkout -q -b main && git config user.email dev@contoso.com && git config user.name Dev
  git config commit.gpgsign false
  echo a >a && git add a && git commit -qm "init"
  git checkout -qb feature
  echo b >b && git add b && git commit -qm "feat: b" -m "Trailer: FORBIDDEN-MARKER"
  echo c >c && git add c && GIT_AUTHOR_EMAIL=bot@example.invalid git commit -qm "feat: c"
  git checkout -q main && echo d >d && git add d && git commit -qm "main: d FORBIDDEN-MARKER (target branch, not the PR)"
  git merge -q --no-ff feature -m "Merge pull request 7"
) >/dev/null 2>&1
start clean 18088; common 18088
out=$(cd "$g" && ATTRIB_RE='forbidden-marker' IDENT_RE='bot@example\.invalid' GUARD_GIT_RANGE='HEAD^1..HEAD^2' bash "$guard" 2>&1); rc=$?
[ $rc -eq 1 ] && ok "git mode exits 1" || { ko "git mode rc=$rc"; echo "$out"; }
echo "$out" | grep -q '2 commit(s)' && ok "git mode checks exactly the 2 PR commits" || { ko "git count"; echo "$out"; }
echo "$out" | grep -qE 'AI attribution in commit [0-9a-f]{8}: authored by the vendor identity' && ok "git mode flags vendor author" || ko "git author"
echo "$out" | grep -qE 'AI attribution in commit [0-9a-f]{8}, line 3' && ok "git mode flags the message line" || ko "git message"
[ "$(echo "$out" | grep -c 'AI attribution in commit')" = 2 ] && ok "target-branch commits excluded" || { ko "target-branch commit checked"; echo "$out"; }
grep -q '/commits?' "$work/req-clean.log" && ko "git mode must not call commits API" || ok "git mode skips commits API"
out2=$(cd "$g" && git checkout -q HEAD^2 && ATTRIB_RE='forbidden-marker' GUARD_GIT_RANGE='HEAD^1..HEAD^2' bash "$guard" 2>&1); rc=$?
[ $rc -eq 2 ] && echo "$out2" | grep -q 'not the PR merge commit' && ok "non-merge HEAD fails closed" || { ko "non-merge rc=$rc"; echo "$out2"; }
stop clean

# 9. token never printed
printf '%s\n%s\n' "$out" "$out2" | grep -q 'test-token' && ko "token leaked" || ok "token not in output"
echo "passed=$pass failed=$failn"
[ $failn -eq 0 ]
