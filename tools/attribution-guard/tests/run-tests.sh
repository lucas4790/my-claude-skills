#!/bin/sh
# Tests for the attribution guard. Usage: sh tools/attribution-guard/tests/run-tests.sh [path-to-git]
# Runs in a throwaway HOME; never touches the real git config.
# ok/ko never fail, so `test && ok || ko` is a safe if/else here; GIT_EDITOR is expanded by git's sh.
# shellcheck disable=SC2015,SC2016
set -u
GIT=${1:-git}
if [ "$GIT" != git ]; then # install.sh and the hooks must run this git too, not the one on PATH
    PATH=$(CDPATH='' cd -- "$(dirname -- "$(command -v "$GIT")")" && pwd):$PATH; export PATH
fi
S=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
export HOME="$W/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$W/home/.gitconfig"
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL CLAUDE_ENV_FILE CLAUDE_PROJECT_DIR ATTRIB_RE
mkdir -p "$HOME"
git() { command "$GIT" "$@"; }
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$*"; }
ko() { fail=$((fail + 1)); printf 'FAIL %s\n' "$*"; }
G="$S/attribution-guard.sh"

git config --global user.name 'Lucas'
git config --global user.email '73317412+lucas4790@users.noreply.github.com'
git config --global init.defaultBranch main
git config --global commit.gpgsign false

# ---- installer (Git >= 2.54: config hooks; older: init.templateDir, or --global-hooks-path dispatcher)
H="$HOME/.config/git/attribution-guard"
mkdir -p "$HOME/.claude"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"sh %s/claude-pretooluse.sh"}]}]}}\n' "$H" >"$HOME/.claude/settings.json"
sh "$S/install.sh" >/dev/null 2>"$W/err" && ok "install.sh ran" || ko "install.sh failed: $(cat "$W/err")"
[ -f "$H/patterns.ere" ] && [ -f "$H/attribution-guard.sh" ] && ok "installed files present" || ko "installed files missing"
v=$(git version | sed 's/^git version \([0-9]*\)\.\([0-9]*\).*/\1 \2/')
# shellcheck disable=SC2086
set -- $v
new_git=0
if [ "$1" -gt 2 ] || { [ "$1" -eq 2 ] && [ "$2" -ge 54 ]; }; then
    new_git=1
    [ -n "$(git config --global --get hook.attribution-guard-msg.command)" ] && [ -z "$(git config --global --get core.hooksPath)" ] \
        && ok "git $1.$2: config-based hooks, no global core.hooksPath" || ko "git $1.$2: wrong install path"
else
    [ "$(git config --global --get init.templateDir)" = "$H/template" ] && [ -z "$(git config --global --get core.hooksPath)" ] \
        && ok "git $1.$2: init.templateDir, no global core.hooksPath" || ko "git $1.$2: wrong install path"
fi
command -v jq >/dev/null 2>&1 && {
    [ "$(jq '[.hooks.PreToolUse[] | select(.hooks[0].command | test("claude-pretooluse"))] | length' "$HOME/.claude/settings.json")" = 1 ] \
        && jq -e '.hooks.PreToolUse[0].matcher | test("Monitor")' "$HOME/.claude/settings.json" >/dev/null \
        && ok "Claude hook registration replaced, not duplicated" || ko "Claude hook registration: $(cat "$HOME/.claude/settings.json")"
}
# A CRLF checkout (core.autocrlf on Windows) must still install LF scripts.
mkdir -p "$W/crlf" && cp "$S"/*.sh "$S/patterns.ere" "$S/dispatch" "$W/crlf/"
for f in attribution-guard.sh claude-pretooluse.sh patterns.ere dispatch; do sed 's/$/\r/' "$S/$f" >"$W/crlf/$f"; done
XDG_CONFIG_HOME="$W/xdg" GIT_CONFIG_GLOBAL="$W/crlf.gitconfig" ATTRIBUTION_GUARD_SKIP_CLAUDE=1 sh "$W/crlf/install.sh" >/dev/null 2>&1
rc=$(printf 'Fix\n\nClaude-Session: x\n' | sh "$W/xdg/git/attribution-guard/attribution-guard.sh" check >/dev/null 2>&1; echo $?)
if ! grep -q "$(printf '\r')" "$W/xdg/git/attribution-guard/attribution-guard.sh" && [ "$rc" = 1 ]; then
    ok "CRLF checkout installs working LF scripts"
else ko "CRLF checkout: installed scripts broken (rc=$rc)"; fi
sh "$S/install.sh" >/dev/null 2>&1
command -v jq >/dev/null 2>&1 && { [ "$(jq '.hooks.PreToolUse | length' "$HOME/.claude/settings.json")" = 1 ] \
    && ok "second install run keeps one registration" || ko "second install run duplicated the registration"; }
# Opt-in dispatcher (--global-hooks-path, Git < 2.54 only): guards existing repos, still runs .git/hooks.
if [ "$new_git" = 0 ]; then (
    export GIT_CONFIG_GLOBAL="$W/dispatch.gitconfig" XDG_CONFIG_HOME="$W/xdg2" ATTRIBUTION_GUARD_SKIP_CLAUDE=1
    git config --global user.name Lucas && git config --global user.email l@example.com && git config --global init.defaultBranch main
    git init -q "$W/existing" && cd "$W/existing" || exit 1
    printf '#!/bin/sh\necho repo-hook-ran >"%s/repo-hook"\n' "$W" >.git/hooks/post-commit && chmod +x .git/hooks/post-commit
    sh "$S/install.sh" --global-hooks-path >/dev/null 2>&1
    echo a >a && git add a && git commit -q -m 'Dispatch' -m 'Claude-Session: x' 2>/dev/null
    [ "$(git config --global --get core.hooksPath)" = "$W/xdg2/git/attribution-guard/hooks" ] \
        && [ "$(git log -1 --format=%B | grep -c 'Claude-Session')" = 0 ] && [ -f "$W/repo-hook" ]
) && ok "--global-hooks-path: dispatcher strips and chains .git/hooks" || ko "--global-hooks-path dispatcher failed"; fi

git init -q --bare "$W/remote.git"
git init -q "$W/repo"
cd "$W/repo" || exit 1
git remote add origin "$W/remote.git"
echo base >f && git add f && git commit -q -m 'Initial commit' && git push -q origin main

n=0
commit_with() { # message in $W/msg; prints resulting message or FAILED
    n=$((n + 1)); echo "$n" >>f; git add f
    if git commit -q -F "$W/msg" 2>"$W/err"; then git log -1 --format=%B; else echo FAILED; fi
}

# ---- legit messages must pass unchanged (both modes); the word "claude" alone never matches
for mode in strip reject; do
  git config attributionguard.mode "$mode"
  while IFS= read -r m; do
    printf '%s\n' "$m" | sed 's/\\n/\n/g' >"$W/msg"
    out=$(commit_with)
    exp=$(git stripspace <"$W/msg")
    if [ "$out" = "$exp" ]; then ok "[$mode] legit passes: $m"; else ko "[$mode] legit changed/blocked: $m -> $out $(cat "$W/err")"; fi
  done <<'EOF'
Add claude-security plugin
Update .claude-plugin/marketplace.json for claude-code-setup
chore: sync high-trust upstream skills (anthropics-skills@3337550, claude-plugins-official@fa59bc9)
Document Claude Code cloud sessions (claude.ai/code) in README
Generate SKILLS.md with gen-catalog.py\n\nGenerated with scripts/gen-catalog.py; see https://code.claude.com/docs/en/plugins
Refresh SKILLS.md generated by claude-plugins-official sync
Drop files generated with claude-code-setup
Fix Claude Code manifest validation\n\nReviewed-by: Lucas (claude-security maintainer)\nCo-authored-by: Lucas <lucas@example.com>
Explain how the guard handles attribution trailers\n\nThe hook strips trailers that name the model as co-author.
Report security issues to security@anthropic.com for the vendored plugins
Link the docs at https://claude.ai/code and https://claude.com/product
Add the claude-code-review workflow generated with claude-code-setup
EOF
done

# ---- attribution: strip mode removes lines, reject mode blocks
cat >"$W/cases" <<'EOF'
Add guardrails\n\nBody text.\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_0123456789abcdefghijklmn
Add guardrails\n\nBody.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n\nhttps://claude.ai/code/session_0123456789abcdefghijklmn\n\n---\n_Generated by [Claude Code](https://claude.ai/code/session_0123456789abcdefghijklmn)_
Add guardrails\n\nco-authored-by: claude <noreply@anthropic.com>
Add guardrails\n\nAssisted-by: Claude Code
Add guardrails\n\nSigned-off-by: Lucas <l@x.nl>\nCo-developed-by: Anthropic Claude
Add guardrails\n\nSee the chat: https://claude.ai/share/abc-123
Add guardrails\n\nBuilt with [Claude Code](https://claude.com/claude-code)
Add guardrails\n\nWritten by Claude Code
Add guardrails\n\nAssisted by Claude
Add guardrails\n\nOpen https://claude.ai/code/artifact/0b1c2d3e
Add guardrails\n\nCo-Authored-By : Claude
Add guardrails\n\nCo-authored-by: ClaudeAI <bot@example.com>
Add guardrails\n\nHelped-by: Opus <opus@anthropic.com>
Add guardrails\n\nGenerated with **Claude Code**
Add guardrails\n\nGenerated  with  _Claude_
Add guardrails\n\nCreated via Claude-Code
Add guardrails\n\nSession https://claude.ai:443/code/session_0123456789abcdefghijklmn
Add guardrails\n\nSession claude.ai/code/session%5F0123456789abcdefghijklmn
Add guardrails\n\nSession https://claude.ai/code/sessions/0123456789abcdefghijklmn
Add guardrails\n\nSee https://claude.ai/public/artifacts/0b1c2d3e
Add guardrails\n\nSee https://0b1c2d3e.claude.site/
EOF
# zero-width characters inside a trailer
printf 'Add guardrails\\n\\nCo-Authored\342\200\213-By: Cl\342\200\214aude <noreply@anthropic.com>\n' >>"$W/cases"
git config attributionguard.mode strip
while IFS= read -r m; do
  printf '%s\n' "$m" | sed 's/\\n/\n/g' >"$W/msg"
  out=$(commit_with)
  if [ "$out" != FAILED ] && printf '%s\n' "$out" | sh "$G" check >/dev/null \
     && printf '%s\n' "$out" | head -n 1 | grep -qx 'Add guardrails'; then
    ok "[strip] cleaned: $(printf '%s' "$out" | tr '\n' '|')"
  else ko "[strip] not cleaned: $m -> $out"; fi
done <"$W/cases"
printf 'Add guardrails\n\nSigned-off-by: Lucas <l@x.nl>\nCo-developed-by: Anthropic Claude\n' >"$W/msg"
out=$(commit_with); printf '%s\n' "$out" | grep -q 'Signed-off-by: Lucas' && ok "[strip] keeps human Signed-off-by" || ko "[strip] lost Signed-off-by: $out"

git config attributionguard.mode reject
while IFS= read -r m; do
  printf '%s\n' "$m" | sed 's/\\n/\n/g' >"$W/msg"
  out=$(commit_with)
  if [ "$out" = FAILED ]; then ok "[reject] blocked: $(head -c 60 "$W/msg" | tr '\n' '|')"; else ko "[reject] allowed: $m"; fi
done <"$W/cases"
git reset -q --hard HEAD; git config attributionguard.mode strip

printf 'Co-Authored-By: Claude <noreply@anthropic.com>\n' >"$W/msg"
[ "$(commit_with)" = FAILED ] && ok "[strip] subject-line hit rejected" || ko "[strip] subject-line hit accepted"
git reset -q --hard HEAD

# ---- identity: vendor author always rejected; vendor committer only with checkCommitter=true
printf 'Clean message\n' >"$W/msg"
out=$(GIT_AUTHOR_NAME=Claude GIT_AUTHOR_EMAIL=noreply@anthropic.com commit_with)
[ "$out" = FAILED ] && ok "vendor author rejected" || ko "vendor author accepted"
git reset -q --hard HEAD
git config attributionguard.checkCommitter false
out=$(GIT_COMMITTER_NAME=Claude GIT_COMMITTER_EMAIL=noreply@anthropic.com commit_with)
[ "$out" != FAILED ] && ok "vendor committer allowed with checkCommitter=false (cloud)" || ko "vendor committer rejected with checkCommitter=false"
git reset -q --hard HEAD~1
git config attributionguard.checkCommitter true
out=$(GIT_COMMITTER_NAME=Claude GIT_COMMITTER_EMAIL=noreply@anthropic.com commit_with)
[ "$out" = FAILED ] && ok "vendor committer rejected with checkCommitter=true (local)" || ko "vendor committer accepted with checkCommitter=true"
git reset -q --hard HEAD

# ---- git commit -m, --amend, merge, commit -v with a diff that contains patterns
echo x >>f; git add f
git commit -q -m 'Use -m' -m 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>' 2>/dev/null
git log -1 --format=%B | sh "$G" check >/dev/null && ok "commit -m stripped" || ko "commit -m kept trailer"
git commit -q --amend -m 'Amended' -m 'Claude-Session: https://claude.ai/code/session_x' 2>/dev/null
git log -1 --format=%B | sh "$G" check >/dev/null && ok "commit --amend stripped" || ko "amend kept trailer"
printf 'Co-Authored-By: Claude <noreply@anthropic.com>\n' >pattern-doc.txt; git add pattern-doc.txt
GIT_EDITOR='sh -c "printf \"Add pattern doc\\n\" | cat - \"\$1\" > \"\$1.t\" && mv \"\$1.t\" \"\$1\"" --' git commit -q -v 2>"$W/err" \
  && [ "$(git log -1 --format=%s)" = 'Add pattern doc' ] && ok "commit -v: diff below scissors ignored" || ko "commit -v blocked: $(cat "$W/err")"
git checkout -q -b feature; echo feat >g; git add g; git commit -q -m 'Feature'
git checkout -q main; echo m >>f; git add f; git commit -q -m 'Main change'
git merge -q --no-ff feature -m 'Merge feature' -m 'Co-Authored-By: Claude <noreply@anthropic.com>' 2>/dev/null
git log -1 --format=%B | sh "$G" check >/dev/null && ok "git merge message stripped" || ko "merge kept trailer"

# ---- pre-push blocks what commit-msg missed (--no-verify)
git checkout -q -b sneaky; echo s >h; git add h
git commit -q --no-verify -m 'Sneaky' -m 'Co-Authored-By: Claude <noreply@anthropic.com>'
if git push -q origin sneaky 2>"$W/err"; then ko "pre-push allowed --no-verify commit"; else grep -q 'refusing to push' "$W/err" && ok "pre-push blocked --no-verify commit" || ko "push failed otherwise: $(cat "$W/err")"; fi
git checkout -q main
git push -q origin main 2>"$W/err" && ok "pre-push allows clean main" || ko "clean push blocked: $(cat "$W/err")"
git checkout -q -b vendor-author main; echo c >i; git add i
GIT_AUTHOR_NAME=Claude GIT_AUTHOR_EMAIL=noreply@anthropic.com git commit -q --no-verify -m 'Add file i'
git push -q origin vendor-author 2>"$W/err" && ko "pre-push allowed vendor-authored commit" || ok "pre-push blocked vendor-authored commit"
git checkout -q sneaky; git rebase -q -r --exec 'git commit -q --amend --no-edit --reset-author' main 2>/dev/null
git push -q origin sneaky 2>"$W/err" && ok "fix recipe (rebase --exec amend --reset-author) cleans and push passes" || ko "fix recipe failed: $(cat "$W/err")"
git checkout -q main

# ---- pre-push ignores commits that are already on a remote (other people's published work)
git checkout -q -b feature2 main; echo f2 >j; git add j; git commit -q -m 'Feature two'; git push -q origin feature2
git clone -q "$W/remote.git" "$W/colleague" 2>/dev/null
( cd "$W/colleague" && echo c >k && git add k \
  && git commit -q --no-verify -m 'Colleague change' -m 'Co-Authored-By: Claude <noreply@anthropic.com>' \
  && git push -q --no-verify origin main ) 2>/dev/null
git fetch -q origin && git merge -q --no-edit origin/main 2>/dev/null
git push -q origin feature2 2>"$W/err" && ok "pre-push allows merging a colleague's published commit" || ko "pre-push refused a colleague's commit: $(cat "$W/err")"
git init -q --bare "$W/upstream.git"
( cd "$W/colleague" && echo u >u && git add u \
  && git commit -q --no-verify -m 'Upstream only' -m 'Co-Authored-By: Claude <noreply@anthropic.com>' \
  && git push -q --no-verify "$W/upstream.git" main ) 2>/dev/null
git remote add upstream "$W/upstream.git" && git fetch -q upstream
git checkout -q -b fork-topic upstream/main; echo t >l; git add l; git commit -q -m 'Fork topic'
git push -q origin fork-topic 2>"$W/err" && ok "pre-push allows a fork topic on upstream's history" || ko "pre-push refused upstream history: $(cat "$W/err")"
echo own >m; git add m; git commit -q --no-verify -m 'Own change' -m 'Claude-Session: https://claude.ai/code/session_0123456789abcdefghijklmn'
git push -q origin fork-topic 2>/dev/null && ko "pre-push allowed an own unpushed trailer" || ok "pre-push still refuses own unpushed trailer"
git reset -q --hard HEAD~1
git tag -a v1 -m 'Release v1' -m 'Co-Authored-By: Claude <noreply@anthropic.com>'
git push -q origin v1 2>/dev/null && ko "pre-push allowed an annotated tag with a trailer" || ok "pre-push blocks an annotated tag with a trailer"
git tag -a v2 -m 'Release v2'
git push -q origin v2 2>"$W/err" && ok "pre-push allows a clean annotated tag" || ko "clean tag refused: $(cat "$W/err")"
git notes add -m 'See https://claude.ai/code/session_0123456789abcdefghijklmn' HEAD
git push -q origin refs/notes/commits 2>/dev/null && ko "pre-push allowed notes with a session link" || ok "pre-push blocks notes with a session link"
git checkout -q main

# ---- scripts/adopt-branch.sh: a cloud branch re-committed as the owner on a new branch
A="$S/../../scripts/adopt-branch.sh"
if [ -f "$A" ] && command -v bash >/dev/null 2>&1; then
    git checkout -q -b claude/cloud-work main
    echo w >w; git add w
    GIT_COMMITTER_NAME=Claude GIT_COMMITTER_EMAIL=noreply@anthropic.com \
        git commit -q --no-verify -m 'Cloud work' -m 'Co-Authored-By: Claude <noreply@anthropic.com>'
    git push -q --no-verify origin claude/cloud-work 2>/dev/null
    git checkout -q main
    printf 'n\n' | bash "$A" claude/cloud-work cloud-work main >"$W/adopt.log" 2>&1
    if git ls-remote --exit-code origin refs/heads/cloud-work >/dev/null \
        && [ "$(git log --format='%ae %ce' origin/main..origin/cloud-work | grep -c anthropic)" = 0 ] \
        && git log --format=%B origin/main..origin/cloud-work | sh "$G" check >/dev/null \
        && [ "$(git log --format=%s origin/main..origin/cloud-work)" = 'Cloud work' ]; then
        ok "adopt-branch re-commits a cloud branch as the owner, clean"
    else ko "adopt-branch failed: $(tail -n 5 "$W/adopt.log")"; fi
    git checkout -q main
fi

# ---- repo hooks (.githooks wrappers used by this repository)
mkdir -p "$W/r2/.githooks" "$W/r2/tools/attribution-guard"
cp "$S/attribution-guard.sh" "$S/patterns.ere" "$W/r2/tools/attribution-guard/"
cp "$S/../../.githooks/commit-msg" "$S/../../.githooks/pre-push" "$W/r2/.githooks/" 2>/dev/null
cd "$W/r2" && git init -q && git config core.hooksPath .githooks && git config --global --unset core.hooksPath 2>/dev/null
for k in $(git config --global --name-only --get-regexp '^hook\.' 2>/dev/null); do git config --global --unset "$k"; done
echo a >a; git add a; git commit -q -m 'Repo hook' -m 'Claude-Session: https://claude.ai/code/session_y' 2>/dev/null
git log -1 --format=%B | sh "$G" check >/dev/null && ok ".githooks/commit-msg strips" || ko ".githooks/commit-msg did not strip"
cd "$W/repo" || exit 1

# ---- Claude Code PreToolUse hook
P="$S/claude-pretooluse.sh"
pt() { printf '%s' "$1" | sh "$P" >/dev/null 2>&1; echo $?; }
[ "$(pt '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"Fix\" -m \"Co-Authored-By: Claude <noreply@anthropic.com>\""}}')" = 2 ] && ok "pretooluse blocks git commit with trailer" || ko "pretooluse allowed git commit with trailer"
[ "$(pt '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"Add claude-security plugin\""}}')" = 0 ] && ok "pretooluse allows clean commit" || ko "pretooluse blocked clean commit"
[ "$(pt '{"tool_name":"Bash","tool_input":{"command":"grep -rn noreply@anthropic.com ."}}')" = 0 ] && ok "pretooluse ignores non-publishing commands" || ko "pretooluse blocked a grep"
[ "$(pt '{"tool_name":"mcp__github__create_pull_request","tool_input":{"title":"x","body":"Summary\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"}}')" = 2 ] && ok "pretooluse blocks MCP PR body with footer" || ko "pretooluse allowed MCP PR footer"
[ "$(pt '{"tool_name":"mcp__github__merge_pull_request","tool_input":{"commit_message":"x\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"}}')" = 2 ] && ok "pretooluse blocks MCP merge message with trailer" || ko "pretooluse allowed MCP merge trailer"
[ "$(pt '{"tool_name":"PowerShell","tool_input":{"command":"gh pr create --body \"https://claude.ai/code/session_abc\""}}')" = 2 ] && ok "pretooluse blocks PowerShell gh pr with session link" || ko "pretooluse allowed PowerShell session link"
[ "$(pt '{"tool_name":"Bash","tool_input":{"command":"az repos pr create --title \"Fix\" --description \"Summary\n\nGenerated with [Claude Code](https://claude.com/claude-code)\""}}')" = 2 ] && ok "pretooluse blocks az repos pr create with footer" || ko "pretooluse allowed az repos pr footer"
[ "$(pt '{"tool_name":"Bash","tool_input":{"command":"az repos pr create --title \"Add claude-security plugin\" --description \"Adds the plugin\""}}')" = 0 ] && ok "pretooluse allows clean az repos pr create" || ko "pretooluse blocked clean az repos pr"
[ "$(pt '{"tool_name":"PowerShell","tool_input":{"command":"Invoke-RestMethod -Method Patch https://dev.azure.com/org/p/_apis/git/repositories/r/pullrequests/7 -Body (@{description=\"Claude-Session: https://claude.ai/code/session_x\"} | ConvertTo-Json)"}}')" = 2 ] && ok "pretooluse blocks REST call to dev.azure.com with session link" || ko "pretooluse allowed ADO REST session link"
[ "$(pt '{"tool_name":"mcp__ado__repo_create_pull_request","tool_input":{"title":"Fix","description":"Body\n\nCo-Authored-By: Claude <noreply@anthropic.com>"}}')" = 2 ] && ok "pretooluse blocks Azure DevOps MCP PR with trailer" || ko "pretooluse allowed ADO MCP trailer"
# <expected exit> <plain|strict> <hook input>
while read -r exp mode json; do
    case $exp in '' | '#'*) continue ;; esac
    if [ "$mode" = strict ]; then got=$(printf '%s' "$json" | sh "$P" --strict >/dev/null 2>&1; echo $?)
    else got=$(pt "$json"); fi
    [ "$got" = "$exp" ] && ok "pretooluse [$mode] $exp: $json" || ko "pretooluse [$mode] expected $exp, got $got: $json"
done <<'EOF'
# hook bypasses, in any flag position
2 plain {"tool_name":"Bash","tool_input":{"command":"git commit -q --allow-empty -m x --no-verify"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"git commit -q --allow-empty -nm x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"git commit --no-verif -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"git add -A && git push --no-verify origin HEAD"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"git -c core.hooksPath=/dev/null commit -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"git config hook.attribution-guard-msg.enabled false"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"git config --unset core.hooksPath"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"GIT_CONFIG_GLOBAL=/dev/null git commit -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"export HOME=/tmp/x; git commit -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"rm -f .githooks/commit-msg"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"chmod -x ~/.config/git/attribution-guard/attribution-guard.sh"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"printf '[core]\\n\\thooksPath = /dev/null\\n' >> .git/config"}}
2 plain {"tool_name":"PowerShell","tool_input":{"command":"Remove-Item .githooks\\pre-push"}}
2 plain {"tool_name":"Monitor","tool_input":{"command":"git commit --no-verify -m x"}}
# ordinary commands pass
0 plain {"tool_name":"Bash","tool_input":{"command":"git config --get core.hooksPath"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"git status && git log --oneline -n 5"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"git commit -m \"Fix internal naming\""}}
0 plain {"tool_name":"Bash","tool_input":{"command":"git -C sub commit -m \"Fix\""}}
0 plain {"tool_name":"Bash","tool_input":{"command":"chmod +x .githooks/commit-msg"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"grep -rn hooksPath docs/"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"echo 'Co-Authored-By: Claude <noreply@anthropic.com>' > fixture.txt"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"gh -R o/r pr new --title Fix --body Adds"}}
# --strict (this repository): GitHub writes are the owner's
2 strict {"tool_name":"Bash","tool_input":{"command":"gh -R o/r pr new --title Fix --body Adds"}}
2 strict {"tool_name":"PowerShell","tool_input":{"command":"gh pr create --title Fix --body Adds"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh api repos/o/r/pulls -f title=Fix -f head=b -f base=main"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh api -X PUT repos/o/r/pulls/1/merge"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"curl -X POST -H 'Authorization: token t' https://api.github.com/repos/o/r/issues/1/comments -d '{\"body\":\"ok\"}'"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"gh api repos/o/r/pulls/1"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"gh pr view 1 --json title"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"curl -s https://api.github.com/repos/o/r/pulls"}}
# attribution text in REST calls, gh flags in any order, MCP writes; read-only MCP tools pass
2 plain {"tool_name":"Bash","tool_input":{"command":"curl -X POST https://api.github.com/repos/o/r/issues/1/comments -d '{\"body\":\"Generated with [Claude Code](https://claude.com/claude-code)\"}'"}}
2 plain {"tool_name":"PowerShell","tool_input":{"command":"Invoke-RestMethod -Method Post -Uri https://api.github.com/repos/o/r/pulls -Body '{\"body\":\"Session https://claude.ai/code/session_x\"}'"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"gh -R o/r pr create --title x --body \"Generated with [Claude Code](https://claude.com/claude-code)\""}}
2 plain {"tool_name":"mcp__github__add_issue_comment","tool_input":{"body":"Done.\n\nGenerated with [Claude Code](https://claude.com/claude-code)"}}
2 plain {"tool_name":"mcp__github__create_pull_request","tool_input":{"title":"x","body":"Co​-Authored-By: Claude <noreply@anthropic.com>"}}
0 plain {"tool_name":"mcp__github__search_pull_requests","tool_input":{"query":"claude.ai/code/session_ in:body"}}
0 plain {"tool_name":"mcp__github__list_commits","tool_input":{"author":"noreply@anthropic.com"}}
0 plain {"tool_name":"mcp__ado__repo_list_pull_request_threads","tool_input":{"note":"Claude-Session: x"}}
EOF
# fail open: a broken install must not block every tool call
mkdir -p "$W/lonely" && cp "$P" "$W/lonely/"
rc=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git commit -m x -m \"Claude-Session: x\""}}' | sh "$W/lonely/claude-pretooluse.sh" 2>/dev/null; echo $?)
[ "$rc" = 0 ] && ok "pretooluse fails open when the guard is missing" || ko "pretooluse blocked with a missing guard (rc=$rc)"

# ---- SessionStart hook
mkdir -p "$W/r3/.githooks" "$W/r3/tools/attribution-guard"
cp "$S/session-start.sh" "$W/r3/tools/attribution-guard/"
printf 'lucas4790 <73317412+lucas4790@users.noreply.github.com>\n' >"$W/r3/tools/attribution-guard/cloud-author"
cd "$W/r3" && git init -q
git config user.email noreply@anthropic.com
CLAUDE_PROJECT_DIR="$W/r3" CLAUDE_ENV_FILE="$W/envfile" sh tools/attribution-guard/session-start.sh
[ "$(git config --get core.hooksPath)" = .githooks ] && ok "session-start sets core.hooksPath" || ko "session-start did not set core.hooksPath"
grep -q "GIT_AUTHOR_EMAIL='73317412+lucas4790@users.noreply.github.com'" "$W/envfile" 2>/dev/null && ok "session-start sets owner author in cloud identity" || ko "session-start author env missing"
rm -f "$W/envfile"; git config user.email me@example.com
CLAUDE_PROJECT_DIR="$W/r3" CLAUDE_ENV_FILE="$W/envfile" sh tools/attribution-guard/session-start.sh
[ ! -s "$W/envfile" ] && ok "session-start leaves a normal identity alone" || ko "session-start overrode a normal identity"
cd "$W/repo" || exit 1

printf '\n%s passed, %s failed (git %s, sh=%s)\n' "$pass" "$fail" "$(git version | cut -d' ' -f3)" "$(readlink -f /bin/sh 2>/dev/null || echo sh)"
[ "$fail" -eq 0 ]
