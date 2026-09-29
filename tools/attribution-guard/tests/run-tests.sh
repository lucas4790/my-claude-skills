#!/bin/sh
# Tests for the attribution guard. Usage: sh tools/attribution-guard/tests/run-tests.sh [path-to-git]
# Runs in a throwaway HOME; never touches the real git config.
# ok/ko never fail, so `test && ok || ko` is a safe if/else here; GIT_EDITOR is expanded by git's sh.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2129
set -u
GIT=${1:-git}
if [ "$GIT" != git ]; then # install.sh and the hooks must run this git too, not the one on PATH
    PATH=$(CDPATH='' cd -- "$(dirname -- "$(command -v "$GIT")")" && pwd):$PATH; export PATH
fi
S=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
export HOME="$W/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$W/home/.gitconfig"
# install.sh writes to ${XDG_CONFIG_HOME:-$HOME/.config} and ${CLAUDE_CONFIG_DIR:-$HOME/.claude}.
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL CLAUDE_ENV_FILE CLAUDE_PROJECT_DIR ATTRIB_RE \
    XDG_CONFIG_HOME CLAUDE_CONFIG_DIR GIT_SSH GIT_SSH_COMMAND ATTRIB_CANARY
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
) && ok "--global-hooks-path: dispatcher strips and chains .git/hooks" || ko "--global-hooks-path dispatcher failed"
(
    export GIT_CONFIG_GLOBAL="$W/dispatch.gitconfig" XDG_CONFIG_HOME="$W/xdg2" ATTRIBUTION_GUARD_SKIP_CLAUDE=1
    sh "$S/install.sh" reject --global-hooks-path >/dev/null 2>&1 && sh "$S/install.sh" >/dev/null 2>&1
    [ "$(git config --global --get core.hooksPath)" = "$W/xdg2/git/attribution-guard/hooks" ] \
        && [ "$(git config --global --get attributionguard.mode)" = reject ] \
        && [ ! -e "$W/xdg2/git/attribution-guard/hooks/push-to-checkout" ]
) && ok "re-running install.sh keeps reject mode and the opted-in hooks path" || ko "re-running install.sh reset earlier choices"
(
    export GIT_CONFIG_GLOBAL="$W/dispatch.gitconfig" XDG_CONFIG_HOME="$W/xdg2" ATTRIBUTION_GUARD_SKIP_CLAUDE=1
    cp "$W/xdg2/git/attribution-guard/dispatch" "$W/xdg2/git/attribution-guard/hooks/push-to-checkout" # an earlier layout
    sh "$S/install.sh" >/dev/null 2>&1 && [ ! -e "$W/xdg2/git/attribution-guard/hooks/push-to-checkout" ] || exit 1
    sh "$S/install.sh" --no-global-hooks-path >/dev/null 2>&1
    [ -z "$(git config --global --get core.hooksPath)" ] \
        && [ "$(git config --global --get init.templateDir)" = "$W/xdg2/git/attribution-guard/template" ] \
        && [ -f "$W/xdg2/git/attribution-guard/template/info/exclude" ]
) && ok "stale dispatcher hooks removed; --no-global-hooks-path goes back to a seeded template" || ko "dispatcher upgrade or way back failed"; fi
command -v jq >/dev/null 2>&1 && {
    printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"sh %s/claude-pretooluse.sh"},{"type":"command","command":"echo mine"}]}]}}\n' "$H" >"$HOME/.claude/settings.json"
    sh "$S/install.sh" >/dev/null 2>&1
    [ "$(jq '[.hooks.PreToolUse[].hooks[] | select(.command == "echo mine")] | length' "$HOME/.claude/settings.json")" = 1 ] \
        && [ "$(jq '[.hooks.PreToolUse[].hooks[] | select(.command | test("claude-pretooluse"))] | length' "$HOME/.claude/settings.json")" = 1 ] \
        && ok "registration keeps other hooks of the same group" || ko "registration dropped a user hook: $(cat "$HOME/.claude/settings.json")"
}

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
landed() { # $1 = subject: HEAD is that commit (it was not aborted) and its message is clean
    [ "$(git log -1 --format=%s 2>/dev/null)" = "$1" ] && git log -1 --format=%B | sh "$G" check >/dev/null
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
Fix settings loading\n\nReviewed-by: Lucas (checked ~/.claude/settings.json and .claude.json)
Wire the action\n\nTested-by: Lucas (with claude-code-action and claude-code-router)
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
cat >>"$W/cases" <<'EOF'
Add guardrails\n\n> Co-Authored-By: Claude <bot@example.com>
Add guardrails\n\n- Co-authored-by: Claude
Add guardrails\n\nGenerated by claude-sonnet-4-5
Add guardrails\n\nCo-authored-by: aider (anthropic/claude-sonnet-4-5) <aider@aider.chat>
Add guardrails\n\nCo-authored-by: aider (vertex_ai/claude-3-5-sonnet-v2@20241022) <aider@aider.chat>
Add guardrails\n\nGenerated by claude-3-7-sonnet-20250219
Add guardrails\n\n+ Co-authored-by: Claude
Add guardrails\n\n1. Co-authored-by: Claude
Add guardrails\n\nGenerated	with ClaudeCode
Add guardrails\n\nSee https://claude.ai%2Fshare%2Fabc-123 (wrapped link)
Add guardrails\n\nHelped-by: us.anthropic.claude-3-7-sonnet
EOF
# zero-width characters inside a trailer; a non-UTF-8 byte in a trailer line
printf 'Add guardrails\\n\\nCo-Authored\342\200\213-By: Cl\342\200\214aude <noreply@anthropic.com>\n' >>"$W/cases"
printf 'Add guardrails\\n\\nCo-Authored-By: Claude Jos\351 <noreply@anthropic.com>\n' >>"$W/cases"
out=$(printf 'Fix\n\nCo-Authored-By: Claude Jos\351 <noreply@anthropic.com>\n' | LC_ALL=C.UTF-8 LANG=C.UTF-8 sh "$G" check 2>&1); rc=$?
[ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q '^3:' && ok "check reports a non-UTF-8 line in a UTF-8 locale" || ko "check with a non-UTF-8 byte: rc=$rc $out"
# a pattern that does not compile must fail closed, never pass everything
mkdir -p "$W/broken" && cp "$G" "$W/broken/" && echo '(' >"$W/broken/patterns.ere"
rc=$(printf 'Fix\n' | sh "$W/broken/attribution-guard.sh" check >/dev/null 2>&1; echo $?)
[ "$rc" = 1 ] && ok "broken pattern: check fails" || ko "broken pattern: check rc=$rc"
# the pattern always comes from the file: an environment value must not switch the guard off
out=$(printf 'Fix\n\nClaude-Session: x\n' | ATTRIB_RE=zzz sh "$G" check 2>/dev/null); rc=$?
[ "$rc" = 1 ] && [ -n "$out" ] && ok "ATTRIB_RE in the environment is ignored" || ko "ATTRIB_RE env override works (rc=$rc)"
# check <file>: a file that cannot be read fails closed; a readable one is checked
printf 'Fix\n\nClaude-Session: x\n' >"$W/hit.txt"; printf 'Fix\n' >"$W/clean.txt"
rc=$(for f in "$W/missing.txt" "$W" "$W/hit.txt" "$W/clean.txt"; do sh "$G" check "$f" >/dev/null 2>&1; printf '%s' $?; done)
[ "$rc" = 1110 ] && ok "check <file>: unreadable fails closed, readable is checked" || ko "check <file>: rc=$rc (want 1110)"

# ---- the matcher of the CI checks (match.awk): every awk available here, the same results as the hooks
M="$S/match.awk"
RE=$(sed -n '1p' "$S/patterns.ere")
# Zero-width and invisible characters: U+00AD, U+034F, U+180E, U+200B-U+200D, U+2060-U+2064, U+FEFF.
ZW='\302\255 \315\217 \341\240\216 \342\200\213 \342\200\214 \342\200\215 \342\201\240 \342\201\241 \342\201\242 \342\201\243 \342\201\244 \357\273\277'
for a in awk mawk gawk original-awk busybox; do
    command -v "$a" >/dev/null 2>&1 || continue
    m() { # $1 = pattern, $2 = mode; the awk under test runs match.awk on stdin
        if [ "$a" = busybox ]; then ATTRIB_RE=$1 busybox awk -v mode="$2" -f "$M"; else ATTRIB_RE=$1 "$a" -v mode="$2" -f "$M"; fi
    }
    [ "$a" != busybox ] || busybox awk 'BEGIN { exit 0 }' </dev/null 2>/dev/null || continue
    got=$(m "$RE" selftest </dev/null 2>&1; echo "rc=$?")
    bad=$(for r in '(' '' '.'; do m "$r" selftest </dev/null >/dev/null 2>&1; printf '%s' "$(($? != 0))"; done)
    [ "$got" = rc=0 ] && [ "$bad" = 111 ] && ok "match.awk [$a]: self-test passes, and fails on a broken, empty or match-all pattern" \
        || ko "match.awk [$a] self-test: $got $bad"
    got=$(printf 'Fix\n\nCo-Authored-By: Claude <noreply@anthropic.com>\nok\r\nClaude-Session: x\r\n' | m "$RE" report | tr '\n' ' ')
    [ "$got" = '3 5 ' ] && ok "match.awk [$a]: report prints the lines with a hit (CRLF too)" || ko "match.awk [$a] report: [$got]"
    got=$(printf 'Summary\n\n---\nGenerated with [Claude Code](https://claude.com/claude-code)\n' | m "$RE" strip)
    [ "$got" = Summary ] && ok "match.awk [$a]: strip drops hit lines and the separators they leave" || ko "match.awk [$a] strip: [$got]"
    rc=$(printf 'x\n' | m '(' report >/dev/null 2>&1; echo $?)
    [ "$rc" != 0 ] && ok "match.awk [$a]: report fails closed on a broken pattern" || ko "match.awk [$a]: broken pattern reported clean"
    # Most callers only read the output (< <(awk ...), [ -n "$(awk ...)" ]): a mode this copy does not
    # know, or a report with a failed self-test, must print a hit (line 0), not an empty clean result.
    got=$(for md in reprot '' report; do [ "$md" = report ] && r= || r=$RE
        o=$(printf 'x\n' | m "$r" "$md" 2>/dev/null); printf '%s:%s ' "$o" "$?"; done)
    [ "$got" = '0:2 0:2 0:2 ' ] && ok "match.awk [$a]: an unknown mode or a failed report prints line 0 and exits 2" \
        || ko "match.awk [$a] unknown mode / failed report: [$got]"
    # shellcheck disable=SC2059 # $z is an octal escape for printf
    got=$(for z in $ZW; do printf "Co-Authored-By: Cl${z}aude <bot@example.com>\n" | m "$RE" report; done | tr -d '\n')
    [ "$got" = 111111111111 ] && ok "match.awk [$a]: removes every zero-width character" || ko "match.awk [$a] zero-width: [$got]"
    got=$(ATTRIB_CANARY=MARKER; export ATTRIB_CANARY; printf 'MARKER here\n' | m marker report)
    [ "$got" = 1 ] && ok "match.awk [$a]: ATTRIB_CANARY replaces the known trailer" || ko "match.awk [$a] canary: [$got]"
done
# shellcheck disable=SC2059 # $z is an octal escape for printf
got=$(for z in $ZW; do printf "Fix\n\nCo-Authored-By: Cl${z}aude <bot@example.com>\n" | sh "$G" check >/dev/null 2>&1; printf '%s' $?; done)
[ "$got" = 111111111111 ] && ok "check removes the same zero-width characters as match.awk" || ko "check zero-width: [$got]"
# One matcher: the workflows load match.awk and self-test it in every step before they use it; no copies.
R="$S/../.."
bad=$(awk '
    /^ *- (name|uses): / { loaded = tested = 0; step = $0 }
    /ATTRIB_AWK=\$\(cat [^)]*match\.awk"?\)$/ { loaded = 1 }
    /awk -v mode=selftest "\$ATTRIB_AWK" <\/dev\/null \|\|/ { tested = loaded; next }
    /"\$ATTRIB_AWK"/ && !tested { print FILENAME ":" FNR ": " step }' \
    "$R/.github/workflows/attribution-guard.yml" "$R/.github/workflows/attribution-audit.yml")
[ -z "$bad" ] && ok "workflows load and self-test match.awk before each use" || ko "workflow steps use a matcher they did not load or test: $bad"
copies=$(cat "$R/.github/workflows/attribution-guard.yml" "$R/.github/workflows/attribution-audit.yml" \
    "$S/azure-devops/ado-pr-guard.sh" "$S/azure-devops/gen.py" | grep -c -e 'ATTRIB_ZW' -e 'ATTRIB_AWK:' -e "ATTRIB_AWK='")
[ "$copies" = 0 ] && ok "no inline copy of the matcher in the workflows or the Azure DevOps guard" || ko "$copies inline matcher line(s) found"
# main-audit reads the patterns and matcher of main before the push; it may use the pushed (here:
# weakened) copy only for a new branch or when that commit predates the file, never on an API error.
wf_run() { # $1 = workflow, $2 = step name: print the step's run: script
    awk -v name="$2" '
        index($0, "- name: " name) == 0 && !found { next }
        !found { found = 1; next }
        !inrun { if ($0 ~ /^ *run: \|/) inrun = 1; next }
        /^ *$/ { print ""; next }
        { match($0, /^ */); if (!ind) ind = RLENGTH; if (RLENGTH < ind) exit; print substr($0, ind + 1) }' "$1"
}
if command -v jq >/dev/null 2>&1 && command -v bash >/dev/null 2>&1 && [ "$(printf 'eA==' | base64 -d 2>/dev/null)" = x ]; then
    AU="$W/audit"; mkdir -p "$AU/co/tools/attribution-guard" "$AU/bin" "$AU/tmp"
    wf_run "$R/.github/workflows/attribution-audit.yml" 'Check the commits that just landed on main' >"$AU/step.sh"
    cp "$S/match.awk" "$AU/co/tools/attribution-guard/"
    echo 'co-authored-by:[[:space:]]*claude' >"$AU/co/tools/attribution-guard/patterns.ere"
    cat >"$AU/bin/gh" <<'EOF'
#!/bin/sh
# fake gh: GH_MODE ok (the files of main before the push), empty, 404 (file absent), gone (404 and no such commit), 502
case "$*" in
*/contents/*) case $GH_MODE in
    ok) for a do u=$a; done; u=${u##*/}; cat "$GH_SRC/${u%%\?*}" ;;
    empty) ;;
    404 | gone) echo '{"message":"Not Found"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
    *) echo 'gh: Server Error (HTTP 502)' >&2; exit 1 ;;
    esac ;;
*/commits/*) [ "$GH_MODE" = 404 ] || { echo 'gh: No commit found for SHA (HTTP 422)' >&2; exit 1; }; echo abc ;;
*) exit 1 ;;
esac
EOF
    chmod +x "$AU/bin/gh"
    printf '{"commits":[{"id":"abcdef1234","message":"Fix\\n\\nClaude-Session: https://claude.ai/code/session_0123456789abcdefghijklmn","author":{"email":"l@example.com"},"committer":{"email":"l@example.com"}}]}\n' >"$AU/event.json"
    audit() { # $1 = GH_MODE, $2 = BEFORE; prints the exit status, output in $AU/out
        (cd "$AU/co" && PATH="$AU/bin:$PATH" GH_MODE=$1 GH_SRC=$S RUNNER_TEMP="$AU/tmp" GITHUB_EVENT_PATH="$AU/event.json" \
            REPO=o/r BEFORE=$2 IDENT_RE='@anthropic\.com$' bash "$AU/step.sh" >"$AU/out" 2>&1); echo $?
    }
    sha=0123456789abcdef0123456789abcdef01234567 zero=0000000000000000000000000000000000000000
    [ -s "$AU/step.sh" ] && [ "$(audit ok "$sha")" = 1 ] && grep -q 'commit abcdef1 message, line 3' "$AU/out" \
        && ok "main-audit judges a push with the patterns of main before it" || ko "main-audit with the patterns before the push: $(cat "$AU/out")"
    got=$(for md in 502 empty gone; do printf '%s ' "$(audit "$md" "$sha")"; grep -q 'No AI attribution' "$AU/out" && printf 'passed '; done)
    [ "$got" = '1 1 1 ' ] && ok "main-audit fails when the patterns before the push cannot be read (API error, empty, no such commit)" \
        || ko "main-audit fell back to the pushed patterns: [$got]"
    [ "$(audit 404 "$sha")" = 0 ] && grep -q 'does not exist in 0123456' "$AU/out" && [ "$(audit 502 "$zero")" = 0 ] \
        && ok "main-audit uses main after the push only for a file the commit before lacks, or a new branch" || ko "main-audit fallback: $(cat "$AU/out")"
fi
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
landed 'Use -m' && ok "commit -m stripped" || ko "commit -m kept trailer or failed"
git commit -q --amend -m 'Amended' -m 'Claude-Session: https://claude.ai/code/session_x' 2>/dev/null
landed 'Amended' && ok "commit --amend stripped" || ko "amend kept trailer or failed"
printf 'Co-Authored-By: Claude <noreply@anthropic.com>\n' >pattern-doc.txt; git add pattern-doc.txt
GIT_EDITOR='sh -c "printf \"Add pattern doc\\n\" | cat - \"\$1\" > \"\$1.t\" && mv \"\$1.t\" \"\$1\"" --' git commit -q -v 2>"$W/err" \
  && [ "$(git log -1 --format=%s)" = 'Add pattern doc' ] && ok "commit -v: diff below scissors ignored" || ko "commit -v blocked: $(cat "$W/err")"
git checkout -q -b feature; echo feat >g; git add g; git commit -q -m 'Feature'
git checkout -q main; echo m >>f; git add f; git commit -q -m 'Main change'
git merge -q --no-ff feature -m 'Merge feature' -m 'Co-Authored-By: Claude <noreply@anthropic.com>' 2>/dev/null
landed 'Merge feature' && ok "git merge message stripped" || ko "merge kept trailer or failed"

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
git push -q origin fork-topic 2>/dev/null && ko "pre-push trusted an untrusted remote's history" || ok "pre-push checks history the destination lacks"
git config attributionguard.trustUrl "$W/upstream.git"
git push -q origin fork-topic 2>"$W/err" && ok "pre-push allows a fork topic on a trusted upstream's history" || ko "pre-push refused trusted upstream history: $(cat "$W/err")"
# Local remote-tracking refs prove nothing: anyone can write them with a fetch into refs/remotes/.
git checkout -q -b spoof main; echo sp >sp; git add sp
git commit -q --no-verify -m 'Spoof' -m 'Co-Authored-By: Claude <noreply@anthropic.com>'
git fetch -q . spoof:refs/remotes/scratch/spoof 2>/dev/null
git push -q origin spoof 2>/dev/null && ko "pre-push trusted a locally written remote-tracking ref" || ok "pre-push ignores locally written remote-tracking refs"
git checkout -q fork-topic
echo own >m; git add m; git commit -q --no-verify -m 'Own change' -m 'Claude-Session: https://claude.ai/code/session_0123456789abcdefghijklmn'
git push -q origin fork-topic 2>/dev/null && ko "pre-push allowed an own unpushed trailer" || ok "pre-push still refuses own unpushed trailer"
git reset -q --hard HEAD~1
git tag -a v1 -m 'Release v1' -m 'Co-Authored-By: Claude <noreply@anthropic.com>'
git push -q origin v1 2>/dev/null && ko "pre-push allowed an annotated tag with a trailer" || ok "pre-push blocks an annotated tag with a trailer"
git tag -a v2 -m 'Release v2'
git push -q origin v2 2>"$W/err" && ok "pre-push allows a clean annotated tag" || ko "clean tag refused: $(cat "$W/err")"
git tag -a inner -m 'Inner' -m 'Co-Authored-By: Claude <noreply@anthropic.com>'
git tag -a outer -m 'Outer clean' inner 2>/dev/null
git push -q origin refs/tags/outer 2>/dev/null && ko "pre-push allowed a clean tag wrapping a bad tag" || ok "pre-push peels nested tags"
git notes add -m 'See https://claude.ai/code/session_0123456789abcdefghijklmn' HEAD
git push -q origin refs/notes/commits 2>/dev/null && ko "pre-push allowed notes with a session link" || ok "pre-push blocks notes with a session link"
git notes edit -m 'Clean note' HEAD 2>/dev/null || git notes add -f -m 'Clean note' HEAD
git push -q origin refs/notes/commits 2>/dev/null && ko "pre-push allowed a bad note kept in notes history" || ok "pre-push checks notes history, not only the tip"
git branch -f nb refs/notes/commits
git push -q origin nb:refs/notes/commits 2>/dev/null && ko "pre-push allowed notes pushed from a branch" || ok "pre-push decides on notes by the destination ref"
git notes --ref=review add -m '++ https://claude.ai/code/session_0123456789abcdefghijklmn' HEAD
git push -q origin refs/notes/review 2>/dev/null && ko "pre-push allowed a note line starting with ++" || ok "pre-push reads note blobs, not diffs"
git checkout -q main

# ---- pre-push tricks: git replace, insteadOf redirects, log encoding, deep tag nesting
git checkout -q -b tricks main; echo r >r; git add r
git commit -q --no-verify -m 'Replace me' -m 'Co-Authored-By: Claude <noreply@anthropic.com>'
bad=$(git rev-parse HEAD)
twin=$(printf 'Replace me\n' | git commit-tree "$bad^{tree}" -p "$bad^")
git replace "$bad" "$twin"
git push -q origin tricks 2>/dev/null && ko "pre-push read a replacement object" || ok "pre-push ignores git replace"
git replace -d "$bad" >/dev/null
git init -q --bare "$W/evil.git"; git push -q --no-verify "$W/evil.git" tricks 2>/dev/null
git remote add fk "fake:r"
git config url."$W/remote.git".pushInsteadOf "fake:r"
git config url."$W/evil.git".insteadOf "$W/remote.git"
git push -q fk tricks 2>/dev/null && ko "pre-push trusted a listing redirected by insteadOf" || ok "pre-push distrusts a listing redirected by insteadOf"
git config --unset url."$W/evil.git".insteadOf; git config --unset url."$W/remote.git".pushInsteadOf; git remote remove fk
git -c i18n.logOutputEncoding=UTF-16 push -q origin tricks 2>/dev/null && ko "pre-push fooled by i18n.logOutputEncoding" || ok "pre-push reads messages as UTF-8 whatever the log encoding"
git tag -a d0 -m 'Deep' -m 'Co-Authored-By: Claude <noreply@anthropic.com>' 2>/dev/null
i=0; prev=d0; while [ $i -lt 11 ]; do i=$((i + 1)); git tag -a "d$i" -m "Wrap $i" "$prev" 2>/dev/null; prev="d$i"; done
git push -q origin refs/tags/d11 2>/dev/null && ko "pre-push allowed a bad tag under 11 clean ones" || ok "pre-push fails closed on deeply nested tags"
git checkout -q main
# over SSH the listing gets connect and keep-alive timeouts, so a stalled connection cannot hang the push
mkdir -p "$W/fakessh"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/fakessh/log"\ncase " $* " in *" -G "*) exit 0 ;; esac\nfor a; do last=$a; done\nPATH="$(git --exec-path):$PATH" exec sh -c "$last"\n' "$W" >"$W/fakessh/ssh"
chmod +x "$W/fakessh/ssh"
GIT_SSH_COMMAND="$W/fakessh/ssh" git push -q "ssh://fakehost$W/remote.git" HEAD:refs/heads/over-ssh 2>"$W/err"; rc=$?
[ "$rc" = 0 ] && grep 'git-upload-pack' "$W/fakessh/log" | grep -q 'ConnectTimeout=30 -o ServerAliveInterval=15' \
    && ok "pre-push lists an SSH remote with timeouts" || ko "pre-push SSH listing (rc=$rc): $(cat "$W/err" "$W/fakessh/log" 2>/dev/null)"
# a literal scissors line in -F/-m text is not the end of the message (no diff follows it)
printf 'Fix\n\n# ------------------------ >8 ------------------------\nCo-Authored-By: Claude <noreply@anthropic.com>\n' >"$W/msg"
out=$(commit_with); printf '%s\n' "$out" | sh "$G" check >/dev/null && ok "commit-msg scans past a literal scissors line" || ko "trailer kept below a literal scissors line: $out"
git reset -q --hard HEAD~1

# ---- scripts/adopt-branch.sh: a cloud branch re-committed as the owner on a new branch
A="$S/../../scripts/adopt-branch.sh"
if [ -f "$A" ] && command -v bash >/dev/null 2>&1; then
    git checkout -q -b claude/cloud-work main
    echo w >w; git add w
    GIT_COMMITTER_NAME=Claude GIT_COMMITTER_EMAIL=noreply@anthropic.com \
        git commit -q --no-verify --cleanup=verbatim -m 'Cloud work' -m '#123 is fixed by this change.' -m 'Co-Authored-By: Claude <noreply@anthropic.com>'
    GIT_COMMITTER_NAME=Claude GIT_COMMITTER_EMAIL=noreply@anthropic.com git commit -q --no-verify --allow-empty -m 'Trigger CI'
    git push -q --no-verify origin claude/cloud-work 2>/dev/null
    git checkout -q main
    printf 'n\n' | bash "$A" claude/cloud-work cloud-work main >"$W/adopt.log" 2>&1
    if git ls-remote --exit-code origin refs/heads/cloud-work >/dev/null \
        && [ "$(git log --format='%ae %ce' origin/main..origin/cloud-work | grep -c anthropic)" = 0 ] \
        && git log --format=%B origin/main..origin/cloud-work | sh "$G" check >/dev/null \
        && [ "$(git log --format=%s origin/main..origin/cloud-work | tr '\n' '|')" = 'Trigger CI|Cloud work|' ] \
        && git log --format=%B origin/main..origin/cloud-work | grep -q '^#123 is fixed'; then
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
landed 'Repo hook' && ok ".githooks/commit-msg strips" || ko ".githooks/commit-msg did not strip, or failed the commit"
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
2 plain {"tool_name":"Bash","tool_input":{"command":"/usr/bin/git commit --no-verify -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"/usr/bin/git push --no-verify origin HEAD"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"git push \\\n  --no-verify origin HEAD"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"\"git\" push --no-verify origin HEAD"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"$(command -v git) push --no-verify origin HEAD"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"git push --no-\"\"verify origin HEAD"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"git push --no-ver\\ify origin HEAD"}}
2 plain {"tool_name":"PowerShell","tool_input":{"command":"git push --no-ver`ify origin HEAD"}}
2 plain {"tool_name":"PowerShell","tool_input":{"command":"& 'C:\\Program Files\\Git\\bin\\git.exe' commit --no-verify -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"git commit -anm\"msg\""}}
2 plain {"tool_name":"Bash","tool_input":{"command":"git commit -sn -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"git -c include.path=/tmp/inc.cfg commit -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"git --work-tree=/tmp commit -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"cd docs && git --git-dir=../.git commit -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"GIT_DIR=/tmp/x git commit -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"git config --global include.path /tmp/x.cfg"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"git config attributionguard.trustUrl /tmp/evil.git"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"git config --global hook.attribution-guard-msg.enabled \"\""}}
2 plain {"tool_name":"Bash","tool_input":{"command":"git config url./tmp/evil.git.insteadOf https://github.com/o/r"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"$(command -v git) commit -nm x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"cp /tmp/x.sh .git/attribution-guard/claude-pretooluse.sh"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"git config extensions.worktreeConfig true"}}
2 plain {"tool_name":"Edit","tool_input":{"file_path":"/work/repo/.git/worktrees/wt/config.worktree","old_string":"a","new_string":"b"}}
2 plain {"tool_name":"Edit","tool_input":{"file_path":"/work/repo/.git/config","old_string":"a","new_string":"b"}}
2 plain {"tool_name":"Write","tool_input":{"file_path":"/home/me/.gitconfig","content":"[core]"}}
2 plain {"tool_name":"Write","tool_input":{"file_path":"C:\\Users\\me\\.config\\git\\attribution-guard\\patterns.ere","content":"x"}}
# ordinary commands pass
0 plain {"tool_name":"Bash","tool_input":{"command":"git config --get core.hooksPath"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"git status && git log --oneline -n 5"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"git commit -m \"Fix internal naming\""}}
0 plain {"tool_name":"Bash","tool_input":{"command":"git -C sub commit -m \"Fix\""}}
0 plain {"tool_name":"Bash","tool_input":{"command":"chmod +x .githooks/commit-msg"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"grep -rn hooksPath docs/"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"echo 'Co-Authored-By: Claude <noreply@anthropic.com>' > fixture.txt"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"gh -R o/r pr new --title Fix --body Adds"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"git config core.hooksPath"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"git config --show-origin core.hooksPath"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"m=$(git config --global --get attributionguard.mode 2>/dev/null || true)"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"git commit -m \"Document core.hooksPath in the README\""}}
0 plain {"tool_name":"Bash","tool_input":{"command":"git commit -m \"Use HOME=/tmp in tests\""}}
0 plain {"tool_name":"Bash","tool_input":{"command":"git commit -m\"Enable the new check\""}}
0 plain {"tool_name":"Bash","tool_input":{"command":"grep -rn \"rm -f\" .githooks tools/attribution-guard"}}
0 plain {"tool_name":"PowerShell","tool_input":{"command":"& 'C:\\Program Files\\Git\\bin\\git.exe' status"}}
0 plain {"tool_name":"Edit","tool_input":{"file_path":"/work/repo/tools/attribution-guard/install.sh","old_string":"a","new_string":"b"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"gh api repos/o/r/pulls -f state=open --method GET"}}
# --strict (this repository): GitHub writes are the owner's
2 strict {"tool_name":"Bash","tool_input":{"command":"gh -R o/r pr new --title Fix --body Adds"}}
2 strict {"tool_name":"PowerShell","tool_input":{"command":"gh pr create --title Fix --body Adds"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh api repos/o/r/pulls -f title=Fix -f head=b -f base=main"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh api -X PUT repos/o/r/pulls/1/merge"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh api graphql -F query=@/tmp/m.graphql"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"/usr/local/bin/gh pr create --title x --body y"}}
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
2 plain {"tool_name":"Bash","tool_input":{"command":"az repos pr create --description \"Summary\" \"\" \"Co-Authored-By: Claude Opus 5\""}}
2 plain {"tool_name":"Bash","tool_input":{"command":"gh pr create --title x --body \"$(printf 'Summary\\n\\nCo-Authored-By: Claude')\""}}
2 plain {"tool_name":"PowerShell","tool_input":{"command":"gh pr create --title x --body \"Summary`n`nCo-Authored-By: Claude\""}}
0 plain {"tool_name":"mcp__github__search_pull_requests","tool_input":{"query":"claude.ai/code/session_ in:body"}}
0 plain {"tool_name":"mcp__github__list_commits","tool_input":{"author":"noreply@anthropic.com"}}
0 plain {"tool_name":"mcp__ado__repo_list_pull_request_threads","tool_input":{"note":"Claude-Session: x"}}
# MCP: a trailer that starts a string value is still at the start of a line
2 plain {"tool_name":"mcp__ado__repo_create_pull_request","tool_input":{"title":"Fix","description":"Co-Authored-By: Claude Opus 4"}}
2 plain {"tool_name":"mcp__github__add_issue_comment","tool_input":{"body":"Claude-Session: 01ABCDEF"}}
2 plain {"tool_name":"mcp__github__create_pull_request","tool_input":{"title":"x","body":"Co-Authored-By: Cl­aude <bot@example.com>"}}
# chmod with options before the mode disables hook files too
2 strict {"tool_name":"Bash","tool_input":{"command":"chmod -R a-x .git/attribution-guard/hooks"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"chmod -R 644 .git/attribution-guard/hooks"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"chmod --recursive 600 .git/attribution-guard"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"sudo chmod -v a=r .githooks/pre-push"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"chmod -R 755 .githooks"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"chmod -R +x .git/attribution-guard/hooks"}}
# any mode that leaves the owner without execute, wherever x sits in the clause; chmod behind find -exec,
# xargs, a path or a prefix command; after cd into the hooks directory; modes that keep u+x pass
2 plain {"tool_name":"Bash","tool_input":{"command":"chmod a-xr .git/attribution-guard/hooks/commit-msg"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"chmod -xr .git/attribution-guard/hooks/commit-msg"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"chmod u-xw .git/attribution-guard/hooks/commit-msg"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"chmod u-x+r .githooks/pre-push"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"chmod u=rw .githooks/pre-push"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"chmod = .githooks/pre-push"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"chmod -- -x .githooks/pre-push"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"chmod --reference=/etc/hosts .githooks/pre-push"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"chmod --reference /etc/hosts .githooks/pre-push"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"find .git/attribution-guard/hooks -type f -exec chmod 644 {} +"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"ls .git/attribution-guard/hooks/* | xargs chmod 644"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"cd .git/attribution-guard/hooks && chmod 644 commit-msg"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"/bin/chmod 644 .githooks/pre-push"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"sudo -u bob chmod 0644 .githooks/pre-push"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"chmod go=r .githooks/pre-push"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"chmod og-x .githooks/pre-push"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"chmod u+x,go=r .githooks/pre-push"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"chmod u=rwX,go=r .githooks/pre-push"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"chmod 4755 .githooks/pre-push"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"chmod +x scripts/foo.sh"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"chmod -R 755 dir"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"chmod 644 docs/notes.md"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"git commit -m \"chmod 644 .githooks/pre-push is blocked now\""}}
0 plain {"tool_name":"Bash","tool_input":{"command":"find .githooks -exec grep -l chmod {} +"}}
# env -i / env - / unsetting HOME next to a git write: git then skips the user-level guard
2 plain {"tool_name":"Bash","tool_input":{"command":"env -i PATH=/usr/bin git commit -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"env - PATH=/usr/bin git push origin HEAD"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"/usr/bin/env --ignore-environment git tag -a v1 -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"env -u LANG -i git rebase main"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"env -iu LANG git cherry-pick abc123"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"env -i git am 0001.patch"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"env -i git merge feature"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"env -i git commit-tree 4b825dc -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"env -u HOME git commit -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"env --unset=HOME git commit -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"HOME=/tmp/empty git push origin HEAD"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"env XDG_CONFIG_HOME=/tmp/x git commit -m x"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"env -i PATH=/usr/bin git status"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"env LC_ALL=C git commit -m x"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"env -u LANG git commit -m x"}}
# GNU env: any unique prefix of a long option, short options clustered, a value after a long option,
# env behind a command that runs it (nice, nohup, timeout 60, sudo -u bob, ...)
2 plain {"tool_name":"Bash","tool_input":{"command":"env --ignore-env git commit -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"env --ignore-e git commit -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"env --u HOME git commit -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"env --uns=HOME git commit -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"env -vu HOME git commit -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"env --unset LANG -i git commit -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"env --chdir /tmp -i git commit -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"nice env -i git commit -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"timeout -s KILL 60 env -i git commit -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"sudo -u bob env -i git commit -m x"}}
2 plain {"tool_name":"Bash","tool_input":{"command":"nice env HOME=/tmp git commit -m x"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"nice env -u LANG git commit -m x"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"nice env -i git status"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"env LC_ALL=C git log"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"git commit -m \"use env -i here\""}}
# --strict: gh api field flags with an attached value; write verbs of the other gh command groups
2 strict {"tool_name":"Bash","tool_input":{"command":"gh api -fbody=hi repos/o/r/issues/1/comments"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh api repos/o/r/issues/1/comments -Fbody=@/tmp/x.md"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh api graphql -Fquery=@/tmp/m.graphql"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh api -X PUT repos/o/r/rulesets/1 --input /tmp/r.json"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh variable set ATTRIBUTION_ALLOW_CLOUD_COMMITTER --body true"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh variable delete X"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh secret set TOKEN < /tmp/t"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh secret remove TOKEN"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh repo edit --enable-auto-merge"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh repo rename other"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh repo archive -y"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh -R o/r repo delete --yes"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh repo deploy-key add key.pub"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh workflow run attribution-audit.yml -f delete_runs=true"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh workflow disable attribution-guard.yml"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh workflow enable sync-upstream.yml"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh run rerun 123 --failed"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh run delete 123"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh run cancel 123"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh release create v9 --notes x"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh release edit v9 --draft=false"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh release delete v9 -y"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh release upload v9 dist.zip"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh label create bug --color f00"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh label delete bug --yes"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh pr update-branch 5"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"gh api -X GET repos/o/r/pulls -fstate=open"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"gh variable list"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"gh secret list"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"gh repo view o/r --json name"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"gh repo clone o/r /tmp/r"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"gh workflow list"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"gh run view 123 --log-failed"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"gh run list --workflow attribution-guard.yml"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"gh release view v1"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"gh label list"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"gh ruleset list"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"gh api repos/o/r/pulls --jq .[].title | cut -f1 | sort -fu"}}
# --strict gh api: -i clustered with -f/-F/-X; each gh api command on its own; the last -X counts
2 strict {"tool_name":"Bash","tool_input":{"command":"gh api -if body=hi repos/o/r/issues/1/comments"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh api -ifbody=hi repos/o/r/issues/1/comments"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh api -iX POST repos/o/r/issues/1/comments"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh api -iXDELETE repos/o/r/git/refs/heads/main"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh api -X POST -f body=hi repos/o/r/issues/1/comments; gh api -X GET repos/o/r"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh api repos/o/r/issues/1/comments -X GET -X POST -f body=hi"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh api -X POST -f body=hi repos/o/r/issues/1/comments; echo graphql"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh api repos/o/r/issues/1/comments -f \"body=reads use -X GET\""}}
0 strict {"tool_name":"Bash","tool_input":{"command":"gh api -X POST -X GET repos/o/r/pulls -fstate=open"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"gh api repos/o/r/pulls | grep -if x"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"cut -f1 file"}}
# --strict gh write verbs count only where gh runs: not in a commit message, a heredoc body, a search
# string or a comment; they do when the text goes to a shell or a command substitution
0 strict {"tool_name":"Bash","tool_input":{"command":"git commit -m \"docs: agents never run gh release create\""}}
0 strict {"tool_name":"Bash","tool_input":{"command":"git commit -m \"docs: gh pr create is owner-only\""}}
0 strict {"tool_name":"Bash","tool_input":{"command":"git commit -m \"Fix\n\ngh secret set is owner-only (see docs); gh pr merge too\""}}
0 strict {"tool_name":"Bash","tool_input":{"command":"git commit -F - <<'MSG'\ndocs: explain why gh workflow run is left to the owner\nMSG"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"git commit -F - <<'MSG'\nKeep releases with the owner\n\ngh release create; gh label create (both owner-only)\nMSG"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"git commit -m \"$(cat <<'EOF'\nFix\n\ngh release create is owner-only\nEOF\n)\""}}
0 strict {"tool_name":"PowerShell","tool_input":{"command":"git commit -m @\"\nFix\n\ngh release create is owner-only\n\"@"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"gh issue list --search \"release create\""}}
0 strict {"tool_name":"Bash","tool_input":{"command":"gh search issues \"label create\" --repo o/r"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"grep -n 'gh workflow run' file"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"gh run list | grep \"gh run cancel\""}}
0 strict {"tool_name":"Bash","tool_input":{"command":"cat f # gh repo create"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"GH_TOKEN=x gh release create v1"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"sudo gh secret set X"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"gh pr -R o/r create --title x"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"\"gh\" release create v1"}}
2 strict {"tool_name":"PowerShell","tool_input":{"command":"& 'C:\\Program Files\\GitHub CLI\\gh.exe' release create v1"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"sh -c \"gh release create v1\""}}
2 strict {"tool_name":"Bash","tool_input":{"command":"echo \"gh release create v1\" | sh"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"cat <<'EOF' | bash\ngh release create v1\nEOF"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"git commit -m \"$(gh release create v1)\""}}
2 strict {"tool_name":"Bash","tool_input":{"command":"git commit -F - <<EOF\n$(gh release create v1)\nEOF"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"git commit -F - <<'MSG'\nx\nMSG\ngh release create v1"}}
2 strict {"tool_name":"Bash","tool_input":{"command":"x=$((1<<2))\ngh release create v1"}}
# what agent sessions in this repository do all the time must keep passing (strict)
0 strict {"tool_name":"Bash","tool_input":{"command":"GIT_AUTHOR_NAME='x' GIT_AUTHOR_EMAIL='x@users.noreply.github.com' GIT_COMMITTER_NAME='x' GIT_COMMITTER_EMAIL='x@users.noreply.github.com' git commit -q -F - <<'MSG'\nFix the guard tests\n\nCheck that each commit landed.\nMSG"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"git push -u origin some-branch"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"git push -q origin some-branch"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"git push -q origin some-branch"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"git -C /d log --oneline -3"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"chmod +x scripts/foo.sh"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"chmod -R 755 dir"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"env LC_ALL=C git log"}}
0 plain {"tool_name":"Bash","tool_input":{"command":"GIT_AUTHOR_NAME='x' GIT_AUTHOR_EMAIL='x@users.noreply.github.com' GIT_COMMITTER_NAME='x' GIT_COMMITTER_EMAIL='x@users.noreply.github.com' git commit -q -F - <<'MSG'\nFix the guard tests\n\nCheck that each commit landed.\nMSG"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"git -C /some/dir log --oneline -5"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"git -C /some/dir diff --stat main...HEAD"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"git -C /some/dir status --short"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"git -C /some/dir rev-parse HEAD"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"git -C /some/dir fetch origin"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"git -C /some/dir ls-remote --heads origin"}}
0 strict {"tool_name":"Bash","tool_input":{"command":"git fetch origin some-branch"}}
0 strict {"tool_name":"mcp__github__get_file_contents","tool_input":{"owner":"o","repo":"r","path":"README.md"}}
0 strict {"tool_name":"mcp__github__pull_request_read","tool_input":{"method":"get","owner":"o","repo":"r","pullNumber":1}}
0 strict {"tool_name":"mcp__github__issue_read","tool_input":{"method":"get_comments","owner":"o","repo":"r","issue_number":1}}
0 strict {"tool_name":"mcp__github__list_commits","tool_input":{"owner":"o","repo":"r","author":"noreply@anthropic.com"}}
0 strict {"tool_name":"mcp__github__search_pull_requests","tool_input":{"query":"repo:o/r claude.ai/code/session_ in:body"}}
0 strict {"tool_name":"mcp__github__get_job_logs","tool_input":{"owner":"o","repo":"r","job_id":1}}
0 strict {"tool_name":"mcp__github__actions_get","tool_input":{"method":"get_workflow_run","owner":"o","repo":"r","resource_id":"1"}}
0 strict {"tool_name":"mcp__github__actions_list","tool_input":{"method":"list_workflow_runs","owner":"o","repo":"r"}}
EOF
# JSON escapes of every zero-width character are removed before matching
for u in 00ad 034f 180e 200b 200c 200d 2060 2061 2062 2063 2064 feff; do
    printf '{"tool_name":"mcp__github__create_pull_request","tool_input":{"title":"x","body":"Fix\\n\\nCo-Authored-By: Cl\\u%saude <bot@example.com>"}}' "$u"
    echo
done | { r=; while IFS= read -r json; do r="$r$(pt "$json")"; done; [ "$r" = 222222222222 ]; } \
    && ok "pretooluse removes JSON-escaped zero-width characters" || ko "pretooluse JSON zero-width escapes not all blocked"
# speed: a long script of git lines must not make every tool call slow
i=0; : >"$W/long"; while [ $i -lt 300 ]; do i=$((i + 1)); printf 'git log --oneline -n %s > /tmp/out%s.txt\\n' "$i" "$i" >>"$W/long"; done
printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$(cat "$W/long")" >"$W/long.json"
t0=$(date +%s); printf '%s' "$(cat "$W/long.json")" | sh "$P" --strict >/dev/null 2>&1; t1=$(date +%s)
[ $((t1 - t0)) -le 2 ] && ok "pretooluse handles a 300-line git script in <= 2 s" || ko "pretooluse took $((t1 - t0)) s on a 300-line script"
# fail open: a broken install must not block every tool call
mkdir -p "$W/lonely" && cp "$P" "$W/lonely/"
rc=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git commit -m x -m \"Claude-Session: x\""}}' | sh "$W/lonely/claude-pretooluse.sh" 2>/dev/null; echo $?)
[ "$rc" = 0 ] && ok "pretooluse fails open when the guard is missing" || ko "pretooluse blocked with a missing guard (rc=$rc)"

# ---- SessionStart hook
git config --global --unset init.templateDir 2>/dev/null
mkdir -p "$W/r3" && cd "$W/r3" && git init -q && rm -f .git/hooks/commit-msg .git/hooks/pre-push
echo old >old && git add old && git commit -q -m 'Before the guard' && git branch pre-guard
mkdir -p .githooks tools/attribution-guard
cp "$S/session-start.sh" "$S/attribution-guard.sh" "$S/patterns.ere" "$S/claude-pretooluse.sh" "$S/dispatch" tools/attribution-guard/
printf 'lucas4790 <73317412+lucas4790@users.noreply.github.com>\n' >tools/attribution-guard/cloud-author
git add -A && git commit -q -m 'Add the guard'
git config user.email noreply@anthropic.com
CLAUDE_PROJECT_DIR="$W/r3" CLAUDE_ENV_FILE="$W/envfile" sh tools/attribution-guard/session-start.sh
case $(git config --get core.hooksPath) in
    /*/.git/attribution-guard/hooks) ok "session-start points core.hooksPath at the copy in .git (absolute)" ;;
    *) ko "session-start core.hooksPath: $(git config --get core.hooksPath)" ;;
esac
grep -q "GIT_AUTHOR_EMAIL='73317412+lucas4790@users.noreply.github.com'" "$W/envfile" 2>/dev/null && ok "session-start sets owner author in cloud identity" || ko "session-start author env missing"
rm -f "$W/envfile"; git config user.email me@example.com
CLAUDE_PROJECT_DIR="$W/r3" CLAUDE_ENV_FILE="$W/envfile" sh tools/attribution-guard/session-start.sh
[ ! -s "$W/envfile" ] && ok "session-start leaves a normal identity alone" || ko "session-start overrode a normal identity"
# The copy in .git keeps guarding on a branch from before the guard and with --work-tree.
git checkout -q pre-guard && [ ! -d tools ] && echo p >p && git add p
git commit -q -m 'Old branch' -m 'Co-Authored-By: Claude <noreply@anthropic.com>' 2>/dev/null
landed 'Old branch' && ok "guard still strips on a branch without tools/" || ko "guard gone (or commit failed) on a pre-guard branch"
mkdir -p "$W/wt"
git --work-tree="$W/wt" commit -q --allow-empty -m 'Work tree' -m 'Claude-Session: https://claude.ai/code/session_0123456789abcdefghijklmn' 2>/dev/null
landed 'Work tree' && ok "guard still strips with --work-tree" || ko "guard skipped (or commit failed) with --work-tree"
(cd "$W/r3" && mkdir -p sub && cd sub && git --git-dir=../.git commit -q --allow-empty -m 'Git dir' -m 'Claude-Session: x' 2>/dev/null)
landed 'Git dir' && ok "guard still strips with --git-dir from a subdirectory" || ko "guard skipped (or commit failed) with --git-dir"
git checkout -q -
# a repository's own hooks path (husky and the like) keeps running through the guard's dispatcher
mkdir -p .husky && printf '#!/bin/sh\necho ran >"%s/husky-ran"\n' "$W" >.husky/post-commit && chmod +x .husky/post-commit
git config core.hooksPath .husky
CLAUDE_PROJECT_DIR="$W/r3" sh tools/attribution-guard/session-start.sh 2>/dev/null
git commit -q --allow-empty -m 'Husky' -m 'Claude-Session: x' 2>/dev/null
[ "$(git config --get attributionguard.previousHooksPath)" = .husky ] && [ -f "$W/husky-ran" ] \
    && landed 'Husky' && ok "session-start keeps an earlier hooks path running" || ko "earlier hooks path lost"
# the settings.json command finds the copy in .git, also on a branch without tools/
cmd=$(sed -n 's/.*"command": "\(c=.*--strict\)".*/\1/p' "$S/../../.claude/settings.json" | sed 's/\\"/"/g')
git checkout -q pre-guard
rc=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git commit --no-verify -m x"}}' | CLAUDE_PROJECT_DIR="$W/r3" sh -c "$cmd" >/dev/null 2>&1; echo $?)
[ -n "$cmd" ] && [ "$rc" = 2 ] && ok "settings.json hook command works on a branch without tools/" || ko "settings.json hook command on an old branch: rc=$rc"
git checkout -q -
# A moved or copied clone: core.hooksPath still names the old guard hooks directory, which is never
# the repository's own hooks path. Its .git/hooks keep running, and a copy does not recurse.
commit_to() { # like git commit, bounded: a dispatcher that calls itself would never return
    if command -v timeout >/dev/null 2>&1; then timeout 60 "$GIT" commit "$@"; else git commit "$@"; fi
}
mkdir -p "$W/m1/tools/attribution-guard" && cd "$W/m1" && git init -q || exit 1
cp "$S/session-start.sh" "$S/attribution-guard.sh" "$S/patterns.ere" "$S/claude-pretooluse.sh" "$S/dispatch" tools/attribution-guard/
printf '#!/bin/sh\necho ran >>"$(git rev-parse --git-dir)/post-commit-ran"\n' >.git/hooks/post-commit && chmod +x .git/hooks/post-commit
git add -A && git commit -q -m 'Add the guard'
CLAUDE_PROJECT_DIR="$W/m1" sh tools/attribution-guard/session-start.sh 2>/dev/null
cd "$W" && mv m1 m2 && cd m2 || exit 1
CLAUDE_PROJECT_DIR="$W/m2" sh tools/attribution-guard/session-start.sh 2>"$W/err"
rm -f .git/post-commit-ran; commit_to -q --allow-empty -m 'Moved' -m 'Claude-Session: x' 2>/dev/null
[ -z "$(git config --get attributionguard.previousHooksPath)" ] && [ "$(git config --get core.hooksPath)" = "$W/m2/.git/attribution-guard/hooks" ] \
    && [ -s .git/post-commit-ran ] && landed 'Moved' && ok "moved clone: session-start takes the hooks path over; .git/hooks still run" \
    || ko "moved clone: prev=$(git config --get attributionguard.previousHooksPath) $(cat "$W/err")"
cp -R "$W/m2" "$W/m3" && cd "$W/m3" || exit 1
CLAUDE_PROJECT_DIR="$W/m3" sh tools/attribution-guard/session-start.sh 2>/dev/null
rm -f .git/post-commit-ran; commit_to -q --allow-empty -m 'Copied' -m 'Claude-Session: x' 2>/dev/null; rc=$?
[ "$rc" = 0 ] && [ -s .git/post-commit-ran ] && landed 'Copied' && ok "copied clone: commits finish and .git/hooks still run" || ko "copied clone: commit rc=$rc"
# a guard hooks directory saved by an older session-start is ignored by the dispatcher, then removed
git config attributionguard.previousHooksPath "$W/m2/.git/attribution-guard/hooks"
rm -f .git/post-commit-ran; commit_to -q --allow-empty -m 'Stale' -m 'Claude-Session: x' 2>/dev/null; rc=$?
CLAUDE_PROJECT_DIR="$W/m3" sh tools/attribution-guard/session-start.sh 2>/dev/null
[ "$rc" = 0 ] && [ -s .git/post-commit-ran ] && landed 'Stale' && [ -z "$(git config --get attributionguard.previousHooksPath)" ] \
    && ok "a saved guard hooks path is ignored by the dispatcher and removed by session-start" || ko "stale guard hooks path: commit rc=$rc"
cd "$W/repo" || exit 1

printf '\n%s passed, %s failed (git %s, sh=%s)\n' "$pass" "$fail" "$(git version | cut -d' ' -f3)" "$(readlink -f /bin/sh 2>/dev/null || echo sh)"
[ "$fail" -eq 0 ]
