#!/bin/sh
# Install the attribution guard for the current user's git repositories (work repos too).
# Linux, WSL, macOS, and Git Bash on Windows (Git for Windows runs hooks with its own sh.exe).
#   sh install.sh [strip|reject] [--global-hooks-path | --no-global-hooks-path]
#     strip (default): attribution lines are removed from commit messages; reject: the commit fails.
# Git >= 2.54: config-based hooks (hook.<name>.command). They run in addition to .git/hooks and to a
#   repository's own core.hooksPath (husky, lefthook, pre-commit), so every repository is covered.
# Git <  2.54: init.templateDir. `git clone` and `git init` copy the commit-msg and pre-push hooks
#   into .git/hooks; run `git init` once in an existing repository to add them (a hook that is
#   already there is kept, so such repositories and repositories with their own core.hooksPath are
#   NOT covered; upgrade Git to 2.54+ for those).
#   --global-hooks-path: instead set a global core.hooksPath with a dispatcher that also runs each
#   repository's .git/hooks. Covers existing repositories at once, but pre-commit, lefthook and
#   git-lfs refuse to install their hooks while a global core.hooksPath is set.
set -eu
src=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
dst="${XDG_CONFIG_HOME:-$HOME/.config}/git/attribution-guard"
# Re-running keeps earlier choices: the mode, and the global hooks path opt-in (stored as
# attributionguard.globalHooksPath; an older install without it counts as opted in while its
# dispatcher is in place; --no-global-hooks-path switches back to init.templateDir).
mode=$(git config --global --get attributionguard.mode 2>/dev/null || true)
[ "$mode" = reject ] || mode='strip'
global_hooks_path=$(git config --global --type=bool --get attributionguard.globalHooksPath 2>/dev/null || true)
case $global_hooks_path in
    true) global_hooks_path=1 ;;
    false) global_hooks_path=0 ;;
    *) global_hooks_path=0
       [ "$(git config --global --get core.hooksPath 2>/dev/null || true)" = "$dst/hooks" ] && global_hooks_path=1 ;;
esac
for a in "$@"; do
    case $a in
        strip | reject) mode=$a ;;
        --global-hooks-path) global_hooks_path=1 ;;
        --no-global-hooks-path) global_hooks_path=0 ;;
        *) echo "usage: sh install.sh [strip|reject] [--global-hooks-path | --no-global-hooks-path]" >&2; exit 2 ;;
    esac
done
if [ "$global_hooks_path" = 1 ]; then git config --global attributionguard.globalHooksPath true
else git config --global attributionguard.globalHooksPath false; fi

mkdir -p "$dst"
# Strip CR so a CRLF checkout (Windows, core.autocrlf) still installs working scripts.
for f in attribution-guard.sh patterns.ere claude-pretooluse.sh dispatch; do
    tr -d '\r' <"$src/$f" >"$dst/$f.tmp" && mv "$dst/$f.tmp" "$dst/$f"
done
chmod +x "$dst/attribution-guard.sh" "$dst/claude-pretooluse.sh"
git config --global attributionguard.mode "$mode"
# On your own machines the committer is you as well, so check both identities there.
git config --global attributionguard.checkCommitter true

ours_hooks_path() { [ "$(git config --global --get core.hooksPath || true)" = "$dst/hooks" ]; }
ours_template() { [ "$(git config --global --get init.templateDir || true)" = "$dst/template" ]; }

ver=$(git version | sed 's/^git version \([0-9]*\)\.\([0-9]*\).*/\1 \2/')
# shellcheck disable=SC2086 # split "major minor" on purpose
set -- $ver
if [ "$1" -gt 2 ] || { [ "$1" -eq 2 ] && [ "$2" -ge 54 ]; }; then
    git config --global hook.attribution-guard-msg.command "sh \"$dst/attribution-guard.sh\" commit-msg"
    git config --global hook.attribution-guard-msg.event commit-msg
    git config --global hook.attribution-guard-push.command "sh \"$dst/attribution-guard.sh\" pre-push"
    git config --global hook.attribution-guard-push.event pre-push
    # Settings from an install on an older Git are no longer needed (a global core.hooksPath would
    # even hide .git/hooks). Hooks already copied into .git/hooks only run the guard a second time.
    ! ours_hooks_path || git config --global --unset core.hooksPath
    ! ours_template || git config --global --unset init.templateDir
    echo "attribution guard: config-based hooks installed (git $1.$2); every repository is covered"
elif [ "$global_hooks_path" = 1 ]; then
    existing=$(git config --global --get core.hooksPath || true)
    if [ -n "$existing" ] && [ "$existing" != "$dst/hooks" ]; then
        echo "core.hooksPath is already $existing; add 'sh \"$dst/attribution-guard.sh\" commit-msg \"\$1\"' and the pre-push call to its hooks instead." >&2
        exit 1
    fi
    mkdir -p "$dst/hooks"
    # Not push-to-checkout (its mere presence changes updateInstead pushes), post-index-change,
    # reference-transaction (overhead on every ref update) or proc-receive (a two-way protocol the
    # dispatcher cannot relay); a repository's own copies of those stop running under a global
    # hooks path. Remove them if an earlier install created them.
    rm -f "$dst/hooks/push-to-checkout" "$dst/hooks/post-index-change" "$dst/hooks/reference-transaction"
    for h in applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg \
             commit-msg post-commit pre-rebase post-checkout post-merge pre-push post-rewrite pre-auto-gc \
             sendemail-validate fsmonitor-watchman p4-changelist p4-prepare-changelist p4-post-changelist p4-pre-submit \
             pre-receive update post-receive post-update; do
        cp "$dst/dispatch" "$dst/hooks/$h"
        chmod +x "$dst/hooks/$h"
    done
    git config --global core.hooksPath "$dst/hooks"
    ! ours_template || git config --global --unset init.templateDir
    echo "attribution guard: global core.hooksPath $dst/hooks (git $1.$2)"
    echo "attribution guard: pre-commit, lefthook and git-lfs will not install hooks while it is set; upgrade Git to 2.54+" >&2
else
    existing=$(git config --global --get init.templateDir || true)
    if [ -n "$existing" ] && [ "$existing" != "$dst/template" ]; then
        echo "init.templateDir is already $existing; add hooks/commit-msg and hooks/pre-push calling 'sh \"$dst/attribution-guard.sh\" <hook> \"\$@\"' there, or upgrade Git to 2.54+." >&2
        exit 1
    fi
    mkdir -p "$dst/template/hooks"
    # init.templateDir replaces git's own template: start from it (info/exclude, description).
    tpl="$(git --exec-path 2>/dev/null)/../../share/git-core/templates"
    if [ -d "$tpl" ]; then cp -R "$tpl/." "$dst/template/" 2>/dev/null || true
    else mkdir -p "$dst/template/info" && [ -f "$dst/template/info/exclude" ] || : >"$dst/template/info/exclude"; fi
    for h in commit-msg pre-push; do
        printf '#!/bin/sh\n# attribution guard (installed by my-claude-skills tools/attribution-guard/install.sh)\nexec sh "%s/attribution-guard.sh" %s "$@"\n' "$dst" "$h" >"$dst/template/hooks/$h"
        chmod +x "$dst/template/hooks/$h"
    done
    git config --global init.templateDir "$dst/template"
    if ours_hooks_path; then
        git config --global --unset core.hooksPath
        echo "attribution guard: removed the global core.hooksPath of an earlier install" >&2
    fi
    echo "attribution guard: init.templateDir $dst/template (git $1.$2): new clones get the hooks;"
    echo "  run 'git init' once in each existing repository. Repositories that already have a commit-msg or"
    echo "  pre-push hook, or their own core.hooksPath, are not covered: upgrade Git to 2.54+ for those." >&2
fi
echo "attribution guard: files in $dst; mode $mode"

# Claude Code, every repository: PreToolUse hook that blocks tool calls publishing attribution or
# skipping the git hooks (git/gh/az commands, GitHub and Azure DevOps MCP tools and REST calls).
# install.ps1 registers it itself (Git for Windows has no jq) and sets ATTRIBUTION_GUARD_SKIP_CLAUDE=1.
[ "${ATTRIBUTION_GUARD_SKIP_CLAUDE:-}" = 1 ] && exit 0
settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
if ! command -v jq >/dev/null 2>&1; then
    echo "attribution guard: jq not found; add the PreToolUse hook to $settings by hand (docs/ATTRIBUTION.md)" >&2
    exit 0
fi
mkdir -p "$(dirname "$settings")"
[ -s "$settings" ] || echo '{}' >"$settings"
if ! jq -e . "$settings" >/dev/null 2>&1; then
    echo "attribution guard: $settings is not plain JSON; add the PreToolUse hook by hand (docs/ATTRIBUTION.md)" >&2
    exit 0
fi
# Replace an earlier registration so matcher and command stay current: remove only our own hook
# entries (other hooks in the same group stay), drop groups left empty, then add ours.
cmd="f=\"$dst/claude-pretooluse.sh\"; [ ! -f \"\$f\" ] || sh \"\$f\""
tmp=$(mktemp)
jq --arg cmd "$cmd" '
    .hooks.PreToolUse = ([(.hooks.PreToolUse // [])[]
        | .hooks = [(.hooks // [])[] | select((.command // "") | test("attribution-guard/claude-pretooluse\\.sh") | not)]
        | select(.hooks | length > 0)]
      + [{matcher: "Bash|PowerShell|Monitor|Write|Edit|MultiEdit|NotebookEdit|mcp__.*([Gg]it[Hh]ub|[Aa]do|[Aa]zure|[Dd]ev[Oo]ps).*",
          hooks: [{type: "command", shell: "bash", command: $cmd}]}])' \
    "$settings" >"$tmp" || { rm -f "$tmp"; exit 1; }
# Rewrite only on change: the session-start updater re-runs this while Claude Code is open.
cmp -s "$tmp" "$settings" || cat "$tmp" >"$settings"
rm -f "$tmp"
echo "attribution guard: Claude Code PreToolUse hook registered in $settings"
