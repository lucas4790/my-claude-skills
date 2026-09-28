#!/bin/sh
# Claude Code PreToolUse hook: stop tool calls that would publish AI attribution or skip the git hooks.
#
# Registered with matcher "Bash|PowerShell|Monitor|mcp__.*([Gg]it[Hh]ub|[Aa]do|[Aa]zure|[Dd]ev[Oo]ps).*":
#   - by this repository's .claude/settings.json, with --strict;
#   - by install.sh / install.ps1 in ~/.claude/settings.json, for every repository (no --strict).
# Shell tools (Bash, PowerShell, Monitor):
#   1. always: block commands that skip or switch off the git hooks: --no-verify, commit -n,
#      core.hooksPath / hook.* / GIT_CONFIG_* / HOME overrides, deleting or disabling hook files;
#   2. --strict: block GitHub writes that this repository leaves to its owner: gh pr/issue
#      create/new/edit/merge/comment/review/..., gh api writes, REST writes to api.github.com;
#   3. always: block git, gh and az commands and GitHub / Azure DevOps REST calls whose text
#      carries AI attribution or a chat/session link.
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
        gsub(/\001/, "\\\\", s)
        print s
    }'
}

has() { printf '%s\n' "$1" | grep -Eiq -e "$2"; }

scan() { # $1 = text; blocks when it carries attribution
    hits=$(printf '%s\n' "$1" | sh "$guard" check 2>/dev/null)
    rc=$?
    if [ "$rc" -eq 1 ] && [ -n "$hits" ]; then
        printf 'Blocked by attribution-guard: this would publish AI attribution or a chat/session link, which the owner forbids.\nRemove these lines and retry:\n%s\n' "$hits" >&2
        exit 2
    fi
    [ "$rc" -eq 0 ] || printf 'attribution-guard: PreToolUse check failed (exit %s); not blocking. Reinstall tools/attribution-guard.\n' "$rc" >&2
}

input=$(cat)
tool=$(printf '%s' "$input" | json_text tool_name 2>/dev/null) || tool=

# Word starts: ".github", "legit" and "digh" are not git/gh.
B='(^|[^[:alnum:]_./-])'
GIT="${B}git(\\.exe)?[[:space:]]+([^[:space:]]+[[:space:]]+)*"
GH="${B}gh(\\.exe)?[[:space:]]+([^[:space:]]+[[:space:]]+)*"
AZ="${B}az(\\.cmd|\\.exe)?[[:space:]]+([^[:space:]]+[[:space:]]+)*"
GIT_WRITE="${GIT}(commit|merge|push|am|rebase|cherry-pick|revert|pull|tag|notes)([[:space:]]|\$)"
HOOK_CONF='hookspath|(^|[^[:alnum:]_])hook\.[^[:space:]=]+\.(command|enabled|event)|\[hook[[:space:]]|(remove|rename)-section[[:space:]]+["'"'"']?(hook|core)'
ENV_OVERRIDE='git_config_(count|parameters|global|nosystem|system)|git_config_(key|value)_[0-9]|--config-env|(^|[^[:alnum:]_])(home|xdg_config_home|userprofile)[[:space:]]*='
HOOK_FILES='\.githooks|\.git[/\\]hooks|git[/\\]attribution-guard'
REST_GH='api\.github\.com|uploads\.github\.com|github\.com/[^[:space:]"]+/(pulls|issues|commits|releases|comments)'
REST_ADO='dev\.azure\.com|visualstudio\.com'

case $tool in
Bash | PowerShell | Monitor)
    cmd=$(printf '%s' "$input" | json_text command 2>/dev/null) || cmd=
    [ -n "$cmd" ] || cmd=$(printf '%s' "$input" | json_text)
    # Split on command separators so each check looks at one command at a time.
    # shellcheck disable=SC2020 # one newline per separator character
    segs=$(printf '%s\n' "$cmd" | tr ';&|()`{}' '\n\n\n\n\n\n\n\n')

    # 1. Skipping or switching off the git hooks.
    why=$(printf '%s\n' "$segs" | while IFS= read -r s; do
        if has "$s" "${GIT}.*--no-veri"; then
            echo 'git --no-verify skips the attribution hooks. Commit and push without it.'
        elif has "$s" "${GIT}commit([[:space:]]+[^[:space:]]+)*[[:space:]]+-[[:alpha:]]*n[[:alpha:]]*([[:space:]]|\$)"; then
            echo 'git commit -n skips the attribution hooks. Commit without it (if -n was part of the message text, rephrase).'
        elif has "$s" "${GIT}config([[:space:]]|\$)" && has "$s" "$HOOK_CONF" \
            && ! has "$s" '[[:space:]](--get|--get-all|--get-regexp|--get-urlmatch|-l|--list|get|list)([[:space:]]|$)'; then
            echo 'changing core.hooksPath or hook.* settings would switch off the attribution hooks.'
        elif has "$s" '\.git[/\\]config' && has "$s" '>|(^|[[:space:]])(tee|sed[[:space:]].*-i|perl[[:space:]].*-i|set-content|add-content|out-file|cp|mv|rm|remove-item|copy-item|move-item)([[:space:]]|$)'; then
            echo 'writing .git/config directly could switch off the attribution hooks.'
        elif has "$s" "$HOOK_FILES" && { has "$s" '(^|[^[:alnum:]_-])(rm|mv|unlink|truncate|remove-item|rename-item|move-item|clear-content|set-content|ri|del|erase)([[:space:]]|$)' \
            || has "$s" 'chmod[[:space:]]+([^[:space:]]*-[rwx]*x|0*[0-7]?[0246][0246][0246])([[:space:]]|$)' \
            || has "$s" ">[[:space:]]*[\"']?[^[:space:]]*($HOOK_FILES)"; }; then
            echo 'deleting or disabling hook files would switch off the attribution hooks.'
        fi
    done | head -n 1)
    [ -z "$why" ] || block "$why"
    if has "$segs" "$GIT_WRITE" && has "$cmd" "$HOOK_CONF|$ENV_OVERRIDE"; then
        block 'overriding git config (core.hooksPath, hook.*, GIT_CONFIG_*, HOME) next to a git write would skip the attribution hooks.'
    fi

    # 2. --strict: GitHub writes are the owner's (this repository: agents push a branch, nothing more).
    if [ "$strict" = 1 ]; then
        if has "$segs" "${GH}(pr|issue)[[:space:]]+(create|new|edit|merge|comment|review|close|reopen|ready|lock|unlock|transfer|delete|develop|pin|unpin)([[:space:]]|\$)"; then
            block 'agents do not create, edit, comment on or merge pull requests or issues in this repository. Push the branch and give the owner the compare link.'
        fi
        if has "$segs" "${GH}api([[:space:]]|\$)"; then
            if has "$segs" 'graphql'; then
                has "$segs" 'mutation' && block 'GitHub GraphQL mutations are left to the owner in this repository.'
            elif has "$segs" '(^|[[:space:]])(-X|--method)[[:space:]=]*["'"'"']?(post|patch|put|delete)|(^|[[:space:]])(-[fF]|--field|--raw-field|--input)([[:space:]=]|$)'; then
                block 'gh api writes are left to the owner in this repository.'
            fi
        fi
        if has "$segs" "$REST_GH" && has "$segs" '(^|[[:space:]])(-X|--request)[[:space:]=]*["'"'"']?(post|patch|put|delete)|-method[[:space:]]+["'"'"']?(post|patch|put|delete)|(^|[[:space:]])(-d|--data[a-z-]*|--json|-F|--form|-T|--upload-file|-body|--body-file|--post-data|--post-file|--method=)([[:space:]=]|$)'; then
            block 'REST writes to the GitHub API are left to the owner in this repository.'
        fi
    fi

    # 3. Attribution in the text of anything that publishes.
    if has "$segs" "$GIT_WRITE|${GH}(pr|issue|api|release|gist|repo|workflow)([[:space:]]|\$)|${AZ}(repos|boards|devops|pipelines)([[:space:]]|\$)|$REST_GH|$REST_ADO"; then
        scan "$cmd"
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
