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
#      assignments or unsets and `env -i` next to a git write, writing .git/config, deleting or
#      disabling hook files (rm, mv, chmod -x, chmod -R 644, ...);
#   2. --strict: block GitHub writes that this repository leaves to its owner: gh pr/issue
#      create/new/edit/merge/comment/review/..., gh variable/secret set/delete, gh repo
#      create/edit/delete/rename/archive/fork/sync, gh workflow run/enable/disable, gh run
#      delete/rerun/cancel, gh release create/edit/delete/upload, gh label create/edit/delete/clone,
#      gh api writes (-X POST/PATCH/PUT/DELETE, -f/-F/--input fields; rulesets and branch protection
#      only change this way) and GraphQL mutations, REST writes to api.github.com;
#   3. always: block git, gh and az commands and GitHub / Azure DevOps REST calls whose text
#      carries AI attribution or a chat/session link (also after \n, `n and quotes start new lines).
# File tools (Write, Edit, MultiEdit, NotebookEdit): block writes to git config and hook locations.
# MCP tools: read-only tools (get/list/search/read) pass; every string of the other tools is scanned
# (also after quotes start new lines).
# Exit 2 blocks the call and stderr goes back to the agent. Internal errors fail open with a warning;
# the commit-msg/pre-push hooks and the CI checks still stand behind this hook.
# Limits: text passed through files (git commit -F, gh --body-file) is not visible here, and a
# determined agent can always find a spelling these patterns miss; the git hooks and CI are the backstop.
set -u
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
guard="$here/attribution-guard.sh"
strict=0
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
        gsub(/\\u(00[aA][dD]|034[fF]|180[eE]|200[bBcCdD]|206[0-4]|[fF][eE][fF][fF])/, "", s)   # zero-width and invisible characters
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
GIT_WRITE="${GIT}(commit|commit-tree|mktag|merge|push|am|rebase|cherry-pick|revert|pull|tag|notes|replace|update-ref)([[:space:]]|\$)"
HOOK_KEYS='hookspath|(^|[^[:alnum:]_])hook\.[^[:space:]=]+\.(command|enabled|event)|\[hook[[:space:]]|(^|[^[:alnum:]_])include\.path|includeif\.|attributionguard\.|(^|[^[:alnum:]_])url\.[^[:space:]]*\.(push)?insteadof|extensions\.worktreeconfig|(remove|rename)-section[[:space:]]+(hook|core|include|attributionguard|url)'
ENV_VARS='home|xdg_config_home|userprofile|git_config[a-z0-9_]*|git_dir|git_work_tree|git_common_dir|git_exec_path|git_template_dir'
# env with its options (-u NAME, -C DIR and -S STRING take a value) and assignments.
ENV_CMD='^[[:space:]]*([^[:space:]]*/)?env[[:space:]]+(-[ucs][[:space:]]+[^[:space:]]+[[:space:]]+|-[^[:space:]]+[[:space:]]+|[a-z_][a-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
# Setting or unsetting one of ENV_VARS, or `env -i` / `env -` (git then reads no user-level config,
# so the user-level hooks do not run). Other assignments (GIT_AUTHOR_NAME=... git commit) pass.
ENV_SET="^[[:space:]]*((export|([^[:space:]]*/)?env|set)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*|\\\$env:)?([a-z_][a-z0-9_]*=[^[:space:]]*[[:space:]]+)*($ENV_VARS)[[:space:]]*=|^[[:space:]]*(unset[[:space:]]+([a-z_0-9]+[[:space:]]+)*|remove-item[[:space:]]+env:)($ENV_VARS)([[:space:]]|\$)|$ENV_CMD(-u[[:space:]]*|--unset[=[:space:]]*)($ENV_VARS)([[:space:]]|\$)|$ENV_CMD(-[0v]*i[^[:space:]]*|--ignore-environment|-)([[:space:]]|\$)"
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
    # Also: an empty quoted argument ("" or '') becomes EMPTY, so removing quotes cannot make
    # 'git config key ""' look like a one-argument read; $(command -v git) and the like become git.
    # shellcheck disable=SC2016 # sed programs, not shell
    joined=$(printf '%s\n' "$cmd" | awk '{ line = line $0 } /[\\`]$/ { sub(/[\\`]$/, "", line); next } { print line; line = "" } END { if (line != "") print line }' \
        | sed -E -e "s/(^|[[:space:]=])(\"\"|'')([[:space:]]|\$)/\1EMPTY\3/g" \
              -e 's/[$][(](command[[:space:]]+-v|which|type[[:space:]]+-[pP]|get-command)[[:space:]]+(git|gh)([.]exe)?[)]/\2/g' \
              -e 's/`(command[[:space:]]+-v|which)[[:space:]]+(git|gh)`/\2/g')
    # shellcheck disable=SC2020 # one newline per separator character
    segs=$(printf '%s\n' "$joined" | tr -d "\"'\`\\\\" | tr ';&|(){}' '\n\n\n\n\n\n\n'
           printf '%s\n' "$joined" | tr -d "\"'\`" | tr '\134' '/' | tr ';&|(){}' '\n\n\n\n\n\n\n')

    # 1. Skipping or switching off the git hooks.
    if has "$segs" "$GIT_WORD" && has "$segs" '--no-veri'; then
        block 'git --no-verify skips the attribution hooks. Commit and push without it.'
    fi
    # Only segments that can matter go through the per-segment checks (heredocs stay fast).
    cand=$(printf '%s\n' "$segs" | grep -Ei -e '(^|[^[:alnum:]_-])(git|gh|az|rm|rmdir|mv|cp|ln|install|tee|dd|rsync|chmod|unlink|truncate|sed|perl|copy|ri|del|erase|remove-item|rename-item|move-item|copy-item|clear-content|set-content|add-content|out-file)([^[:alnum:]_-]|$)|>' | sort -u)
    # Each check filters all candidate segments at once: a handful of greps however long the command.
    pick() { # candidate segments matching $1 and, when given, $2 (case-insensitive)
        if [ -n "${2:-}" ]; then printf '%s\n' "$cand" | grep -Ei -e "$1" | grep -Ei -e "$2"
        else printf '%s\n' "$cand" | grep -Ei -e "$1"; fi
    }
    # -n anywhere in a short-option cluster before an option that takes the rest as its value.
    if has_cs "$cand" "${GIT}commit([[:space:]]+[^[:space:]]+)*[[:space:]]+-[^-[:space:]mFCctS]*n[^[:space:]]*([[:space:]]|\$)"; then
        block 'git commit -n skips the attribution hooks. Commit without it (if -n was part of the message text, rephrase).'
    fi
    if pick "${GIT}config([[:space:]]|\$)" "$HOOK_KEYS" | while IFS= read -r s; do
            printf '%s\n' "$s" | config_writes && echo write; done | grep -q write; then
        block 'changing core.hooksPath, hook.*, include.path, url.*.insteadOf or attributionguard.* settings would switch off the attribution hooks.'
    fi
    [ -z "$(pick "$GIT_WORD" "(^|[[:space:]])(-c[[:space:]]*|--config-env[=[:space:]]*)[^[:space:]]*($HOOK_KEYS)")" ] \
        || block 'git -c / --config-env overrides of hook settings would switch off the attribution hooks.'
    [ -z "$(pick "$GIT_WRITE" '(^|[[:space:]])--(git-dir|work-tree)([=[:space:]]|$)')" ] \
        || block 'git --git-dir / --work-tree on a git write can move the repository away from its hooks; run git from the repository instead.'
    [ -z "$(pick '\.git/config' '>|(^|[[:space:]])(tee|sed[[:space:]].*-i|perl[[:space:]].*-i|set-content|add-content|out-file|cp|mv|rm|remove-item|copy-item|move-item)([[:space:]]|$)')" ] \
        || block 'writing .git/config directly could switch off the attribution hooks.'
    if pick "$HOOK_FILES" | grep -Eiq \
        -e '^[[:space:]]*(sudo[[:space:]]+)?(rm|rmdir|mv|cp|ln|install|tee|dd|rsync|unlink|truncate|sed|perl|copy|remove-item|rename-item|move-item|copy-item|clear-content|set-content|add-content|out-file|ri|del|erase)([[:space:]]|$)' \
        -e '^[[:space:]]*(sudo[[:space:]]+)?chmod[[:space:]]+(-[^[:space:]]+[[:space:]]+)*([^[:space:]]*-[rwx]*x|([^[:space:]]*,)?[ugoa]*=[rwst]*|0*[0-7]?[0246][0-7][0-7]|[0-7]{1,2})([,[:space:]]|$)' \
        -e ">[[:space:]]*[^[:space:]]*($HOOK_FILES)"; then
        block 'deleting, replacing or disabling hook files would switch off the attribution hooks.'
    fi
    if has "$segs" "$GIT_WRITE" && has "$segs" "$ENV_SET"; then
        block 'setting GIT_CONFIG_*, GIT_DIR, GIT_WORK_TREE or HOME next to a git write would skip the attribution hooks.'
    fi

    # 2. --strict: GitHub writes are the owner's (this repository: agents push a branch, nothing more).
    if [ "$strict" = 1 ]; then
        if has "$segs" "${GH}(pr|issue)[[:space:]]+(create|new|edit|merge|comment|review|close|reopen|ready|lock|unlock|transfer|delete|develop|pin|unpin|update-branch|revert)([[:space:]]|\$)"; then
            block 'agents do not create, edit, comment on or merge pull requests or issues in this repository. Push the branch and give the owner the compare link.'
        fi
        if has "$segs" "${GH}((variable|secret)[[:space:]]+(set|delete|remove)|repo[[:space:]]+(create|new|edit|delete|rename|archive|unarchive|fork|sync|deploy-key[[:space:]]+(add|delete))|workflow[[:space:]]+(run|enable|disable)|run[[:space:]]+(delete|rerun|cancel)|release[[:space:]]+(create|new|edit|delete|delete-asset|upload)|label[[:space:]]+(create|edit|delete|clone))([[:space:]]|\$)"; then
            block 'agents do not change repository settings, variables, secrets, workflows, runs, releases or labels in this repository; the owner does.'
        fi
        if has "$segs" "${GH}api([[:space:]]|\$)"; then
            if has "$segs" 'graphql'; then
                if has "$segs" 'mutation|(^|[[:space:]])(-[fF]|--field|--raw-field)[[:space:]=]*query=@|(^|[[:space:]])--input([[:space:]=]|$)'; then
                    block 'GitHub GraphQL mutations (or queries read from a file) are left to the owner in this repository.'
                fi
            elif has "$segs" '(^|[[:space:]])(-X|--method)[[:space:]=]*get([[:space:]]|$)'; then
                :
            elif has "$segs" "$WRITE_METHOD|(^|[[:space:]])(-[fF]|--field|--raw-field|--input)([[:space:]=]|\$)|(^|[[:space:]])-[fF][^[:space:]=]+="; then
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
    if has "$path" '(^|/)\.git/(config|hooks/|attribution-guard/)|/config\.worktree$|/worktrees/[^/]+/config$|(^|/)\.gitconfig$|/\.config/git/(config$|attribution-guard/)'; then
        block "editing $path could switch off the attribution hooks; the owner changes git config and hooks by hand."
    fi
    ;;
mcp__*)
    op=${tool##*__}
    case $op in
        get_* | list_* | search_* | read_* | *_get | *_list | *_read | *_search | *_get_* | *_list_* | *_search_*) exit 0 ;;
    esac
    # Also with quotes starting new lines, so a trailer at the start of a string value is at the
    # start of a line for the line-anchored patterns.
    text=$(printf '%s' "$input" | json_text)
    scan "$text
$(printf '%s\n' "$text" | tr '"' '\n')"
    ;;
esac
exit 0
