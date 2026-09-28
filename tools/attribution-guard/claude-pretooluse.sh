#!/bin/sh
# Claude Code PreToolUse hook: stop tool calls that would publish AI attribution or skip the git hooks.
#
# Registered with matcher
#   "Bash|PowerShell|Monitor|Write|Edit|MultiEdit|NotebookEdit|mcp__.*([Gg]it[Hh]ub|[Aa]do|[Aa]zure|[Dd]ev[Oo]ps).*":
#   - by this repository's .claude/settings.json, with --strict;
#   - by install.sh / install.ps1 in ~/.claude/settings.json, for every repository (no --strict).
# Shell tools (Bash, PowerShell, Monitor). The command is checked as written and normalized (line
# continuations joined, quotes, backslashes and backticks removed, git/gh found by base name):
#   1. always: block commands that skip or switch off the git hooks: --no-verify, commit -n,
#      writing core.hooksPath / hook.* / include.path / attributionguard.* config, -c or
#      --config-env overrides, --git-dir/--work-tree on a git write, GIT_CONFIG_* / GIT_DIR / HOME
#      assignments next to a git write, writing .git/config, deleting or disabling hook files;
#   2. --strict: block GitHub writes that this repository leaves to its owner: gh pr/issue
#      create/new/edit/merge/comment/review/..., gh api writes and GraphQL mutations, REST writes
#      to api.github.com;
#   3. always: block git, gh and az commands and GitHub / Azure DevOps REST calls whose text
#      carries AI attribution or a chat/session link (also after \n, `n and quotes start new lines).
# File tools (Write, Edit, MultiEdit, NotebookEdit): block writes to git config and hook locations.
# MCP tools: read-only tools (get/list/search/read) pass; every string of the other tools is scanned.
# Exit 2 blocks the call and stderr goes back to the agent. Internal errors fail open with a warning;
# the commit-msg/pre-push hooks and the CI checks still stand behind this hook.
# Limits: text passed through files (git commit -F, gh --body-file) is not visible here, and a
# determined agent can always find a spelling these patterns miss; the git hooks and CI are the backstop.
set -u
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
guard="$here/attribution-guard.sh"
strict=${ATTRIBUTION_GUARD_STRICT:-0}
[ "${1:-}" = --strict ] && strict=1

block() {
    printf 'Blocked by attribution-guard: %s\n' "$1" >&2
    exit 2
}

# Undo JSON string escapes (enough for matching). With a key, print only that string field.
json_text() {
    awk -v key="${1:-}" '
    { doc = doc (NR > 1 ? "\n" : "") $0 }
    END {
        s = doc
        gsub(/\\\\/, "\001", s)             # escaped backslash
        gsub(/\\"/, "\002", s)              # escaped quote
        if (key != "") {
            i = index(s, "\"" key "\"")
            if (!i) exit 3
            s = substr(s, i + length(key) + 2)
            if (!match(s, /^[ \t\r\n]*:[ \t\r\n]*"/)) exit 3
            s = substr(s, RLENGTH + 1)
            i = index(s, "\"")
            if (i) s = substr(s, 1, i - 1)
        }
        gsub(/\\r\\n|\\n/, "\n", s)
        gsub(/\\t/, "\t", s)
        gsub(/\\[rbf]/, "", s)
        gsub(/\\\//, "/", s)
        gsub(/\\u(200[bBcCdD]|2060|[fF][eE][fF][fF])/, "", s)   # zero-width characters
        gsub(/\\u[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]/, "?", s)
        gsub(/\002/, "\"", s)
        # Not gsub: awks disagree on how many backslashes a "\\\\" replacement yields.
        while ((i = index(s, "\001")) > 0) s = substr(s, 1, i - 1) "\\" substr(s, i + 1)
        print s
    }'
}

has() { printf '%s\n' "$1" | grep -Eiq -e "$2"; }
has_cs() { printf '%s\n' "$1" | grep -Eq -e "$2"; } # case-sensitive: git's short options

scan() { # $1 = text; blocks when it carries attribution
    hits=$(printf '%s\n' "$1" | sh "$guard" check 2>/dev/null)
    rc=$?
    if [ "$rc" -eq 1 ] && [ -n "$hits" ]; then
        printf 'Blocked by attribution-guard: this would publish AI attribution or a chat/session link, which the owner forbids.\nRemove these lines and retry:\n%s\n' "$hits" >&2
        exit 2
    fi
    [ "$rc" -eq 0 ] || printf 'attribution-guard: PreToolUse check failed (exit %s); not blocking. Reinstall tools/attribution-guard.\n' "$rc" >&2
}

# 'git config ...' segment on stdin: exit 0 when it writes (a key and a value, or a write verb/flag).
config_writes() {
    awk '{
        n = split($0, t, /[[:space:]]+/); seen = 0; args = 0
        for (i = 1; i <= n; i++) {
            w = tolower(t[i])
            if (!seen) { if (w == "config") seen = 1; continue }
            if (w ~ /^(--unset|--unset-all|--add|--replace-all|--remove-section|--rename-section|--edit|-e)$/) exit 0
            if (w ~ /^(-f|--file|--blob|--type|--default|--comment|--value)$/) { i++; continue }
            if (w ~ /^[0-9]*[<>]/) { if (w ~ /^[0-9]*[<>]+&?$/) i++; continue }   # redirections
            if (w ~ /^-/ || w == "") continue
            if (args == 0 && w ~ /^(set|unset|edit|remove-section|rename-section)$/) exit 0
            if (args == 0 && w ~ /^(get|list)$/) exit 1
            args++
        }
        exit (args >= 2 ? 0 : 1)
    }'
}

input=$(cat)
tool=$(printf '%s' "$input" | json_text tool_name 2>/dev/null) || tool=

# Word starts: ".github", "legit" and "my-git" are not git; "/usr/bin/git", "\git.exe" and "'git" are.
B='(^|[^[:alnum:]_.-])'
GIT="${B}git(\\.exe)?[[:space:]]+([^[:space:]]+[[:space:]]+)*"
GH="${B}gh(\\.exe)?[[:space:]]+([^[:space:]]+[[:space:]]+)*"
AZ="${B}az(\\.cmd|\\.exe)?[[:space:]]+([^[:space:]]+[[:space:]]+)*"
GIT_WORD="${B}git(\\.exe)?([^[:alnum:]_.-]|\$)"
GIT_WRITE="${GIT}(commit|merge|push|am|rebase|cherry-pick|revert|pull|tag|notes)([[:space:]]|\$)"
HOOK_KEYS='hookspath|(^|[^[:alnum:]_])hook\.[^[:space:]=]+\.(command|enabled|event)|\[hook[[:space:]]|(^|[^[:alnum:]_])include\.path|includeif\.|attributionguard\.|(remove|rename)-section[[:space:]]+(hook|core|include|attributionguard)'
ENV_VARS='home|xdg_config_home|userprofile|git_config[a-z0-9_]*|git_dir|git_work_tree|git_common_dir|git_exec_path|git_template_dir'
ENV_SET="^[[:space:]]*((export|env|set)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*|\\\$env:)?([a-z_][a-z0-9_]*=[^[:space:]]*[[:space:]]+)*($ENV_VARS)[[:space:]]*=|^[[:space:]]*(unset[[:space:]]+([a-z_0-9]+[[:space:]]+)*|remove-item[[:space:]]+env:|env[[:space:]]+(-[^[:space:]]+[[:space:]]+)*-u[[:space:]]*)($ENV_VARS)([[:space:]]|\$)"
HOOK_FILES='\.githooks|\.git/hooks|git/attribution-guard'
REST_GH='api\.github\.com|uploads\.github\.com|github\.com/[^[:space:]"]+/(pulls|issues|commits|releases|comments)'
REST_ADO='dev\.azure\.com|visualstudio\.com'
WRITE_METHOD='(^|[[:space:]])(-X|--request|--method|-method)[[:space:]=]*(post|patch|put|delete)'

case $tool in
Bash | PowerShell | Monitor)
    cmd=$(printf '%s' "$input" | json_text command 2>/dev/null) || cmd=
    [ -n "$cmd" ] || cmd=$(printf '%s' "$input" | json_text)
    # Join line continuations (sh "\", PowerShell "`"); then two normalized forms: n1 drops quotes,
    # backticks and backslashes (--no-""verify, --no-ver\ify, --no-ver`ify); n2 turns backslashes
    # into slashes (C:\Program Files\Git\bin\git.exe). Segments split on command separators.
    joined=$(printf '%s\n' "$cmd" | awk '{ line = line $0 } /[\\`]$/ { sub(/[\\`]$/, "", line); next } { print line; line = "" } END { if (line != "") print line }')
    # shellcheck disable=SC2020 # one newline per separator character
    segs=$(printf '%s\n' "$joined" | tr -d "\"'\`\\\\" | tr ';&|(){}' '\n\n\n\n\n\n\n'
           printf '%s\n' "$joined" | tr -d "\"'\`" | tr '\134' '/' | tr ';&|(){}' '\n\n\n\n\n\n\n')

    # 1. Skipping or switching off the git hooks.
    if has "$segs" "$GIT_WORD" && has "$segs" '--no-veri'; then
        block 'git --no-verify skips the attribution hooks. Commit and push without it.'
    fi
    why=$(printf '%s\n' "$segs" | while IFS= read -r s; do
        # -n anywhere in a short-option cluster before an option that takes the rest as its value.
        if has_cs "$s" "${GIT}commit([[:space:]]+[^[:space:]]+)*[[:space:]]+-[^-[:space:]mFCctS]*n[^[:space:]]*([[:space:]]|\$)"; then
            echo 'git commit -n skips the attribution hooks. Commit without it (if -n was part of the message text, rephrase).'
        elif has "$s" "${GIT}config([[:space:]]|\$)" && has "$s" "$HOOK_KEYS" && printf '%s\n' "$s" | config_writes; then
            echo 'changing core.hooksPath, hook.*, include.path or attributionguard.* settings would switch off the attribution hooks.'
        elif has "$s" "$GIT_WORD" && has "$s" "(^|[[:space:]])(-c[[:space:]]*|--config-env[=[:space:]]*)[^[:space:]]*($HOOK_KEYS)"; then
            echo 'git -c / --config-env overrides of hook settings would switch off the attribution hooks.'
        elif has "$s" "$GIT_WRITE" && has "$s" '(^|[[:space:]])--(git-dir|work-tree)([=[:space:]]|$)'; then
            echo 'git --git-dir / --work-tree on a git write can move the repository away from its hooks; run git from the repository instead.'
        elif has "$s" '\.git/config' && has "$s" '>|(^|[[:space:]])(tee|sed[[:space:]].*-i|perl[[:space:]].*-i|set-content|add-content|out-file|cp|mv|rm|remove-item|copy-item|move-item)([[:space:]]|$)'; then
            echo 'writing .git/config directly could switch off the attribution hooks.'
        elif has "$s" "$HOOK_FILES" && { has "$s" '^[[:space:]]*(sudo[[:space:]]+)?(rm|rmdir|mv|unlink|truncate|remove-item|rename-item|move-item|clear-content|set-content|ri|del|erase)([[:space:]]|$)' \
            || has "$s" '^[[:space:]]*(sudo[[:space:]]+)?chmod[[:space:]]+([^[:space:]]*-[rwx]*x|0*[0-7]?[0246][0246][0246])([[:space:]]|$)' \
            || has "$s" ">[[:space:]]*[^[:space:]]*($HOOK_FILES)"; }; then
            echo 'deleting or disabling hook files would switch off the attribution hooks.'
        fi
    done | head -n 1)
    [ -z "$why" ] || block "$why"
    if has "$segs" "$GIT_WRITE" && has "$segs" "$ENV_SET"; then
        block 'setting GIT_CONFIG_*, GIT_DIR, GIT_WORK_TREE or HOME next to a git write would skip the attribution hooks.'
    fi

    # 2. --strict: GitHub writes are the owner's (this repository: agents push a branch, nothing more).
    if [ "$strict" = 1 ]; then
        if has "$segs" "${GH}(pr|issue)[[:space:]]+(create|new|edit|merge|comment|review|close|reopen|ready|lock|unlock|transfer|delete|develop|pin|unpin)([[:space:]]|\$)"; then
            block 'agents do not create, edit, comment on or merge pull requests or issues in this repository. Push the branch and give the owner the compare link.'
        fi
        if has "$segs" "${GH}api([[:space:]]|\$)"; then
            if has "$segs" 'graphql'; then
                if has "$segs" 'mutation|(^|[[:space:]])(-[fF]|--field|--raw-field)[[:space:]=]*query=@|(^|[[:space:]])--input([[:space:]=]|$)'; then
                    block 'GitHub GraphQL mutations (or queries read from a file) are left to the owner in this repository.'
                fi
            elif has "$segs" '(^|[[:space:]])(-X|--method)[[:space:]=]*get([[:space:]]|$)'; then
                :
            elif has "$segs" "$WRITE_METHOD|(^|[[:space:]])(-[fF]|--field|--raw-field|--input)([[:space:]=]|\$)"; then
                block 'gh api writes are left to the owner in this repository.'
            fi
        fi
        if has "$segs" "$REST_GH" && has "$segs" "$WRITE_METHOD|(^|[[:space:]])(-d|--data[a-z-]*|--json|-F|--form|-T|--upload-file|-body|--body-file|--post-data|--post-file)([[:space:]=]|\$)"; then
            block 'REST writes to the GitHub API are left to the owner in this repository.'
        fi
    fi

    # 3. Attribution in the text of anything that publishes. Also scan a variant where literal \n,
    #    PowerShell `n and quotes start new lines, so line-anchored trailers are found inside arguments.
    if has "$segs" "$GIT_WRITE|${GH}(pr|issue|api|release|gist|repo|workflow)([[:space:]]|\$)|${AZ}(repos|boards|devops|pipelines)([[:space:]]|\$)|$REST_GH|$REST_ADO"; then
        split=$(printf '%s\n' "$cmd" | awk '{ gsub(/\\[nr]|`[nr]/, "\n"); gsub(/["'"'"']/, "\n"); print }')
        scan "$cmd
$split"
    fi
    ;;
Write | Edit | MultiEdit | NotebookEdit)
    path=$(printf '%s' "$input" | json_text file_path 2>/dev/null) \
        || path=$(printf '%s' "$input" | json_text notebook_path 2>/dev/null) || path=
    path=$(printf '%s\n' "$path" | tr '\134' '/')
    if has "$path" '(^|/)\.git/(config|hooks/|attribution-guard/)|(^|/)\.gitconfig$|/\.config/git/(config$|attribution-guard/)'; then
        block "editing $path could switch off the attribution hooks; the owner changes git config and hooks by hand."
    fi
    ;;
mcp__*)
    op=${tool##*__}
    case $op in
        get_* | list_* | search_* | read_* | *_get | *_list | *_read | *_search | *_get_* | *_list_* | *_search_*) exit 0 ;;
    esac
    scan "$(printf '%s' "$input" | json_text)"
    ;;
esac
exit 0
