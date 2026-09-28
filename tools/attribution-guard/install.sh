#!/bin/sh
# Install the attribution guard for EVERY git repository of the current user (work repos too).
# Linux, WSL, macOS, and Git Bash on Windows (Git for Windows runs hooks with its own sh.exe).
#   sh install.sh [strip|reject]      default strip: attribution lines are removed from messages
# Git >= 2.54: config-based hooks (hook.<name>.command). They run in addition to .git/hooks and to a
#   repo's own core.hooksPath (husky, lefthook, pre-commit), so nothing needs chaining.
# Git <  2.54: global core.hooksPath with a dispatcher that also runs the repo's .git/hooks/<name>.
#   Repos that set their own core.hooksPath bypass it; upgrade Git (>= 2.54) to cover those.
set -eu
src=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
dst="${XDG_CONFIG_HOME:-$HOME/.config}/git/attribution-guard"
mkdir -p "$dst"
cp "$src/attribution-guard.sh" "$src/patterns.ere" "$src/claude-pretooluse.sh" "$src/dispatch" "$dst/"
git config --global attributionguard.mode "${1:-strip}"
# On your own machines the committer is you as well, so check both identities there.
git config --global attributionguard.checkCommitter true

ver=$(git version | sed 's/^git version \([0-9]*\)\.\([0-9]*\).*/\1 \2/')
# shellcheck disable=SC2086 # split "major minor" on purpose
set -- $ver
if [ "$1" -gt 2 ] || { [ "$1" -eq 2 ] && [ "$2" -ge 54 ]; }; then
    git config --global hook.attribution-guard-msg.command "sh \"$dst/attribution-guard.sh\" commit-msg"
    git config --global hook.attribution-guard-msg.event commit-msg
    git config --global hook.attribution-guard-push.command "sh \"$dst/attribution-guard.sh\" pre-push"
    git config --global hook.attribution-guard-push.event pre-push
    # A dispatcher-based core.hooksPath from an older install would now hide .git/hooks; drop it.
    if [ "$(git config --global --get core.hooksPath || true)" = "$dst/hooks" ]; then
        git config --global --unset core.hooksPath
    fi
    echo "attribution guard: config-based hooks installed (git $1.$2)"
else
    existing=$(git config --global --get core.hooksPath || true)
    if [ -n "$existing" ] && [ "$existing" != "$dst/hooks" ]; then
        echo "core.hooksPath is already $existing; add 'sh \"$dst/attribution-guard.sh\" commit-msg \"\$1\"' and the pre-push call to its hooks instead." >&2
        exit 1
    fi
    mkdir -p "$dst/hooks"
    for h in applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg \
             commit-msg post-commit pre-rebase post-checkout post-merge pre-push post-rewrite; do
        cp "$src/dispatch" "$dst/hooks/$h"
        chmod +x "$dst/hooks/$h"
    done
    git config --global core.hooksPath "$dst/hooks"
    echo "attribution guard: global core.hooksPath $dst/hooks (git $1.$2; upgrade to 2.54+ for config-based hooks)"
fi
echo "attribution guard: files in $dst; mode $(git config --global --get attributionguard.mode)"

# Claude Code, every repository: PreToolUse hook that blocks tool calls publishing attribution
# (git/gh/az commands, GitHub and Azure DevOps MCP tools, REST calls to Azure DevOps).
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
if grep -q 'attribution-guard/claude-pretooluse.sh' "$settings"; then
    echo "attribution guard: Claude Code PreToolUse hook already registered in $settings"
else
    cmd="f=\"$dst/claude-pretooluse.sh\"; [ ! -f \"\$f\" ] || sh \"\$f\""
    tmp=$(mktemp)
    jq --arg cmd "$cmd" '.hooks.PreToolUse = ((.hooks.PreToolUse // []) +
        [{matcher: "Bash|PowerShell|mcp__.*(github|ado|azure|devops).*", hooks: [{type: "command", command: $cmd}]}])' \
        "$settings" >"$tmp" && cat "$tmp" >"$settings"
    rm -f "$tmp"
    echo "attribution guard: Claude Code PreToolUse hook registered in $settings"
fi
