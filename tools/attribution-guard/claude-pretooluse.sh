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
#      assignments or unsets and `env -i` (any spelling GNU env accepts, also behind sudo, nice,
#      timeout, ...) next to a git write, writing .git/config, deleting or disabling hook files (rm,
#      mv, ..., and a chmod that leaves the owner without execute: -x, a-xr, 644, a=r, --reference,
#      also through find -exec or xargs, or after cd, once the command names a hook file);
#   2. --strict: block GitHub writes that this repository leaves to its owner: gh pr/issue
#      create/new/edit/merge/comment/review/..., gh variable/secret set/delete, gh repo
#      create/edit/delete/rename/archive/fork/sync, gh workflow run/enable/disable, gh run
#      delete/rerun/cancel, gh release create/edit/delete/upload, gh label create/edit/delete/clone,
#      gh api writes (-X POST/PATCH/PUT/DELETE, the last -X counting; -f/-F/--input fields, also
#      in a short-option cluster such as -if; rulesets and branch protection only change this way)
#      and GraphQL mutations, REST writes to api.github.com. Only where gh runs as a command: words
#      in a quoted string (a commit message, a search), a comment or a quoted-delimiter heredoc body
#      do not count, unless the command hands text to a shell (sh -c, | bash, eval, ssh, ...);
#   3. always: block git, gh and az commands and GitHub / Azure DevOps REST calls whose text
#      carries AI attribution or a chat/session link (also after \n, `n and quotes start new lines).
# File tools (Write, Edit, MultiEdit, NotebookEdit): block writes to git config and hook locations.
# MCP tools: read-only tools (get/list/search/read) pass; every string of the other tools is scanned
# (also after quotes start new lines).
# Exit 2 blocks the call and stderr goes back to the agent. Internal errors fail open with a warning;
# the commit-msg/pre-push hooks and the CI checks still stand behind this hook.
# Limits: text passed through files (git commit -F, gh --body-file) is not visible here, and a
# determined agent can always find a spelling these patterns miss (the --strict gh checks trust shell
# quoting unless the command runs a shell they know, so python -c or a command in a variable gets
# past them); the git hooks and CI are the backstop.
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

# Segments on stdin: exit 0 when one runs chmod (also behind sudo, env, xargs, find -exec and the like)
# with --reference or a mode that leaves the owner without execute: -x, a-xr, u-x+r, a=r, =, 644,
# 0600, 55 (go=r, og-x, +x, u=rwX and 755 keep it). A mode it cannot read (a variable) passes.
chmod_clears_x() {
    awk '
    function base(w) { sub(/^.*\//, "", w); return tolower(w) }
    function clears(m,    c, k, i, who, r, op, p, x) { # mode m, applied to an executable file
        if (m ~ /^[0-7]+$/) return length(m) < 3 || substr(m, length(m) - 2, 1) % 2 == 0
        if (m ~ /^=[0-7]+$/) return clears(substr(m, 2))
        if (m ~ /^-[0-7]+$/) return length(m) > 3 && substr(m, length(m) - 2, 1) % 2 == 1
        if (m !~ /^[ugoa]*[-+=][-+=rwxXstugo]*(,[ugoa]*[-+=][-+=rwxXstugo]*)*$/) return 0
        x = 1
        k = split(m, c, ",")
        for (i = 1; i <= k; i++) {
            who = c[i]; sub(/[-+=].*/, "", who)
            if (who != "" && who !~ /[ua]/) continue   # g, o: the owner keeps its bits
            r = substr(c[i], length(who) + 1)
            while (match(r, /^[-+=][rwxXstugo]*/)) {
                op = substr(r, 1, 1); p = substr(r, 2, RLENGTH - 1); r = substr(r, RLENGTH + 1)
                if (op == "+") { if (p ~ /[xX]/) x = 1 }
                else if (op == "-") { if (p ~ /[xXugo]/) x = 0 }
                else x = (p ~ /[xXu]/)
            }
        }
        return !x
    }
    function check(j,    w, dm, m, opts) { # t[j..n]: the arguments of chmod
        opts = 1; dm = ""; m = ""
        for (; j <= n; j++) {
            w = t[j]
            if (w ~ /^[0-9]*[<>]/) { if (w ~ /^[0-9]*[<>]+&?$/) j++; continue }   # redirections
            if (w == "") continue
            if (opts && w == "--") { opts = 0; continue }
            if (opts && w ~ /^--ref/) return 1   # --reference=FILE: the mode of any file
            if (opts && (w ~ /^--/ || w ~ /^-[RcfvhHLP]+$/)) continue
            if (opts && w ~ /^-/) { dm = dm (dm == "" ? "" : ",") w; continue }   # chmod -x, -xr: a mode
            if (m == "") m = w
        }
        if (dm != "") m = dm
        return m != "" && clears(m)
    }
    {
        n = split($0, t, /[[:space:]]+/)
        for (i = 1; i <= n && (t[i] == "" || t[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/); i++) ;
        w = base(t[i])
        if (w != "chmod") {
            if (w !~ /^(sudo|doas|command|exec|nohup|nice|time|timeout|env|stdbuf|setsid|ionice|chrt|xargs|builtin|busybox|find)$/) next
            for (i++; i <= n && base(t[i]) != "chmod"; i++) ;
        }
        if (i <= n && check(i + 1)) { found = 1; exit }
    }
    END { exit !found }'
}

# The command as its shell parses it, one simple command per line, for the --strict gh checks: a
# quoted string stays one word (its blanks become \037, so a gh command named in a commit message or
# a search string is no command), comments and quoted-delimiter heredoc bodies are dropped, and
# command substitutions ($(...) and `...`, also inside double quotes and unquoted heredocs) are
# commands of their own; a literal backslash reads as a slash (C:\...\gh.exe). $1 = 1: PowerShell
# (backtick escapes, '' and "" inside strings, @'...'@ and @"..."@ here-strings, no heredocs).
code_segs() {
    awk -v ps="$1" '
    function top() { return substr(st, length(st), 1) }
    function push(c) { st = st c; pd[length(st)] = 0 }
    function pop() { st = substr(st, 1, length(st) - 1) }
    function put(x) { o = o x; if (length(o) > 4000) { printf "%s", o; o = "" } }
    function word(c) { # a character inside a word; blanks become \037, a literal backslash a slash
        if (c == " " || c == "\t" || c == "\r" || c == "\n") c = "\037"
        else if (c == "\\") c = "/"
        put(c)
    }
    function is_delim(l, d, dash) { sub(/\r$/, "", l); if (dash) sub(/^\t+/, "", l); return l == d }
    function eol(    t, k) { # the newline at the end of line ln
        t = top()
        if (t == "e" && ln + 1 == eend) { pop(); ln++; t = top() }   # heredoc body done; skip its end line
        if (t == "s" || t == "d" || t == "e" || t == "h" || t == "H") {
            word("\n")
            if ((t == "h" || t == "H") && substr(L[ln + 1], 1, 2) == (t == "H" ? q1 : "\"") "@") { pop(); from = 3 }
            return
        }
        put("\n")
        while (hi < hn) {                                            # heredoc bodies start on the next line
            hi++
            for (k = ln + 1; k <= nl && !is_delim(L[k], hd[hi], hx[hi]); k++) ;
            if (k > nl) { hi = hn; return }                          # no end line (1<<2?): read on as commands
            if (!hq[hi] && k > ln + 1) { push("e"); eend = k; return }   # unquoted: expanded like "..."
            ln = k; put("\n")                                        # quoted delimiter: text, dropped
        }
    }
    { L[++nl] = $0 }
    END {
        q1 = sprintf("%c", 39); from = 1
        for (ln = 1; ln <= nl; ln++) {
            s = L[ln]; n = length(s); i = from; from = 1
            for (; i <= n; i++) {
                c = substr(s, i, 1); c2 = substr(s, i + 1, 1); t = top()
                if (t == "s") {                                      # single quotes: literal
                    if (c != q1) word(c)
                    else if (ps && c2 == q1) { word(c); i++ }
                    else pop()
                    continue
                }
                if (t == "H") { word(c); continue }                  # @'...'@
                if (t == "d" || t == "e" || t == "h") {              # "...", unquoted heredoc, @"..."@
                    if (t == "d" && c == "\"") { if (ps && c2 == "\"") { word(c); i++ } else pop(); continue }
                    if (ps && c == "`") { i++; word(substr(s, i, 1)); continue }
                    if (!ps && c == "\\" && c2 != "" && index(t == "d" ? "$`\"\\" : "$`\\", c2)) { word(c2); i++; continue }
                    if (c == "$" && c2 == "(") { push("p"); put("\n"); i++; continue }
                    if (c == "`") { push("b"); put("\n"); continue }
                    word(c); continue
                }
                # code: the command line, $(...) and `...`
                if (t == "b" && c == "`") { pop(); put("\n"); continue }
                if (t == "p" && c == ")" && pd[length(st)] == 0) { pop(); put("\n"); continue }
                if (t == "p" && c == "(") pd[length(st)]++
                if (t == "p" && c == ")") pd[length(st)]--
                if (c == q1) { push("s"); continue }
                if (c == "\"") { push("d"); continue }
                if (ps && c == "@" && (c2 == q1 || c2 == "\"") && (i + 1 == n || (i + 2 == n && substr(s, n, 1) == "\r"))) {
                    push(c2 == q1 ? "H" : "h"); i = n; continue      # a here-string starts on the next line
                }
                if (c == (ps ? "`" : "\\")) { i++; word(substr(s, i, 1)); continue }
                if (c == "`") { push("b"); put("\n"); continue }
                if (c == "#" && (i == 1 || index(" \t;&|()", substr(s, i - 1, 1)))) break   # comment
                if (index(";&|(){}", c)) { put("\n"); continue }
                if (!ps && c == "<" && c2 == "<") {
                    if (substr(s, i + 2, 1) == "<") { put("<<<"); i += 2; continue }   # here-string
                    i += 2; x = 0
                    if (substr(s, i, 1) == "-") { x = 1; i++ }
                    while (substr(s, i, 1) == " " || substr(s, i, 1) == "\t") i++
                    w = ""; q = 0
                    for (; i <= n; i++) {                            # the delimiter word, quotes removed
                        c = substr(s, i, 1)
                        if (c == q1 || c == "\"") {
                            q = 1; j = index(substr(s, i + 1), c)
                            if (!j) { i = n; break }
                            w = w substr(s, i + 1, j - 1); i += j; continue
                        }
                        if (c == "\\") { q = 1; i++; w = w substr(s, i, 1); continue }
                        if (index(" \t\r;&|()<>", c)) break
                        w = w c
                    }
                    i--; hd[++hn] = w; hx[hn] = x; hq[hn] = q
                    put(" "); continue
                }
                if (ps && c == "\\") c = "/"
                put((c == "\t" || c == "\r") ? " " : c)
            }
            eol()
        }
        printf "%s", o
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
# Command position: assignments, then optionally a command that runs the rest (sudo, nice -n 5,
# timeout 60, xargs -I{}, ...; any words may follow it).
PRE='(([^[:space:]]*/)?(sudo|doas|command|exec|nohup|nice|time|timeout|env|stdbuf|setsid|ionice|chrt|xargs|builtin|find)(\.exe)?[[:space:]]+([^[:space:]]+[[:space:]]+)*)?'
CMD_POS="^[[:space:]]*([a-z_][a-z0-9_]*=[^[:space:]]*[[:space:]]+)*$PRE"
# env with its options (-u NAME, -C DIR, -S STRING and -a ARG take a value, also at the end of a
# cluster such as -vu; GNU accepts any unique prefix of a long option: --uns=HOME, --ignore-env)
# and assignments.
ENV_CMD="^[[:space:]]*$PRE([^[:space:]]*/)?env[[:space:]]+(-[0iv]*[ucsa][[:space:]]+[^[:space:]]+[[:space:]]+|--[ucsa][a-z0-9-]*[[:space:]]+[^[:space:]]+[[:space:]]+|-[^[:space:]]+[[:space:]]+|[a-z_][a-z0-9_]*=[^[:space:]]*[[:space:]]+)*"
# Setting or unsetting one of ENV_VARS, or `env -i` / `env -` (git then reads no user-level config,
# so the user-level hooks do not run). Other assignments (GIT_AUTHOR_NAME=... git commit) pass.
ENV_SET="^[[:space:]]*$PRE((export|([^[:space:]]*/)?env|set)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*|\\\$env:)?([a-z_][a-z0-9_]*=[^[:space:]]*[[:space:]]+)*($ENV_VARS)[[:space:]]*=|^[[:space:]]*(unset[[:space:]]+([a-z_0-9]+[[:space:]]+)*|remove-item[[:space:]]+env:)($ENV_VARS)([[:space:]]|\$)|$ENV_CMD(-[0iv]*u[[:space:]]*|--u[a-z]*[=[:space:]]*)($ENV_VARS)([[:space:]]|\$)|$ENV_CMD(-[0v]*i[^[:space:]]*|--ignore-e[a-z]*|-)([[:space:]]|\$)"
# gh as a command (in code_segs output): options (with a value) may come before the command group
# and the verb (gh -R o/r pr create, gh pr --repo o/r create), other words may not.
OPTS='(-[^[:space:]]*[[:space:]]+([^-[:space:]][^[:space:]]*[[:space:]]+)?)*'
GH_CMD="$CMD_POS([^[:space:]]*/)?gh(\\.exe)?[[:space:]]+$OPTS"
# A shell that runs text from the command (sh -c '...', ... | bash, bash <<EOF, eval, ssh host '...').
SHELL_CMD="$CMD_POS([^[:space:]]*/)?((eval|iex|invoke-expression|ssh|su|watch|trap|flock|parallel|cmd|busybox|script)(\\.exe)?([[:space:]]|\$)|(sh|bash|dash|zsh|ksh|mksh|ash|fish|pwsh|powershell)(\\.exe)?([[:space:]]+-[^[:space:]]*)*([[:space:]]*\$|[[:space:]]+[-/][a-z]*[ck]))"
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
        -e ">[[:space:]]*[^[:space:]]*($HOOK_FILES)"; then
        block 'deleting, replacing or disabling hook files would switch off the attribution hooks.'
    fi
    # chmod in any segment once the command names a hook file (cd .githooks && chmod 644 x, ... | xargs chmod 644).
    if has "$segs" "$HOOK_FILES" && pick '(^|[^[:alnum:]_-])chmod([^[:alnum:]_-]|$)' | chmod_clears_x; then
        block 'a chmod that removes the execute bit from hook files would switch off the attribution hooks.'
    fi
    if has "$segs" "$GIT_WRITE" && has "$segs" "$ENV_SET"; then
        block 'setting GIT_CONFIG_*, GIT_DIR, GIT_WORK_TREE or HOME next to a git write would skip the attribution hooks.'
    fi

    # 2. --strict: GitHub writes are the owner's (this repository: agents push a branch, nothing more).
    if [ "$strict" = 1 ] && has "$segs" "${B}gh(\\.exe)?([^[:alnum:]_.-]|\$)"; then
        # Only gh commands count, not a commit message, search string or heredoc that names one; but
        # when the command hands text to a shell, every word may be a command.
        [ "$tool" = PowerShell ] && ps=1 || ps=0
        gsegs=$(printf '%s\n' "$joined" | code_segs "$ps")
        G=$GH_CMD
        if has "$gsegs" "$SHELL_CMD"; then gsegs=$segs; G=$GH; fi
        if has "$gsegs" "${G}(pr|issue)[[:space:]]+$OPTS(create|new|edit|merge|comment|review|close|reopen|ready|lock|unlock|transfer|delete|develop|pin|unpin|update-branch|revert)([[:space:]]|\$)"; then
            block 'agents do not create, edit, comment on or merge pull requests or issues in this repository. Push the branch and give the owner the compare link.'
        fi
        if has "$gsegs" "${G}((variable|secret)[[:space:]]+$OPTS(set|delete|remove)|repo[[:space:]]+$OPTS(create|new|edit|delete|rename|archive|unarchive|fork|sync|deploy-key[[:space:]]+$OPTS(add|delete))|workflow[[:space:]]+$OPTS(run|enable|disable)|run[[:space:]]+$OPTS(delete|rerun|cancel)|release[[:space:]]+$OPTS(create|new|edit|delete|delete-asset|upload)|label[[:space:]]+$OPTS(create|edit|delete|clone))([[:space:]]|\$)"; then
            block 'agents do not change repository settings, variables, secrets, workflows, runs, releases or labels in this repository; the owner does.'
        fi
        # gh api, each command on its own: -i is its only boolean short option, so -if, -iF and -iX
        # are field and method flags; of several -X the last one counts (-X GET -X POST posts).
        api=$(printf '%s\n' "$gsegs" | grep -Ei -e "${G}api([[:space:]]|\$)" | while IFS= read -r s; do
            if has "$s" '(^|[[:space:]])/?graphql([[:space:]]|$)'; then
                has "$s" 'mutation|(^|[[:space:]])(-i*[fF]|--field|--raw-field)[[:space:]=]*query=@|(^|[[:space:]])--input([[:space:]=]|$)' && echo graphql
                continue
            fi
            m=$(printf '%s\n' "$s" | grep -Eio -e '(^|[[:space:]])(-i*X|--method)[[:space:]=]*[a-z]+' | tail -n 1)
            if [ -n "$m" ]; then has "$m" '(get|head)$' || echo write
            elif has "$s" '(^|[[:space:]])(-i*[fF]|--field|--raw-field|--input)([[:space:]=]|$)|(^|[[:space:]])-i*[fF][^[:space:]]'; then echo write; fi
        done)
        case $api in
        *graphql*) block 'GitHub GraphQL mutations (or queries read from a file) are left to the owner in this repository.' ;;
        *write*) block 'gh api writes are left to the owner in this repository.' ;;
        esac
    fi
    if [ "$strict" = 1 ] && has "$segs" "$REST_GH" \
        && has "$segs" "$WRITE_METHOD|(^|[[:space:]])(-d|--data[a-z-]*|--json|-F|--form|-T|--upload-file|-body|--body-file|--post-data|--post-file)([[:space:]=]|\$)"; then
        block 'REST writes to the GitHub API are left to the owner in this repository.'
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
