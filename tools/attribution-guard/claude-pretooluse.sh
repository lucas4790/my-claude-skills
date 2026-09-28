#!/bin/sh
# Claude Code PreToolUse hook: block tool calls that would publish AI attribution.
# Covers what git hooks cannot see: GitHub and Azure DevOps MCP calls (PR/issue/work-item text,
# comments, merge commit messages, API commits), gh and az repos/boards/devops commands, and REST
# calls to Azure DevOps. Exit 2 = block; stderr goes back to Claude.
# Registered with matcher "Bash|PowerShell|mcp__.*(github|ado|azure|devops).*": in this repo's
# .claude/settings.json and, by install.sh / install.ps1, in ~/.claude/settings.json for every repo.
# Limits: text passed through files (git commit -F, gh --body-file) is not visible here; the
# commit-msg/pre-push hooks and the attribution-guard CI check cover those.
set -u
guard="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/attribution-guard.sh"
input=$(cat)
case $input in
    *'"tool_name":"Bash"'* | *'"tool_name": "Bash"'* | *'"tool_name":"PowerShell"'* | *'"tool_name": "PowerShell"'*)
        # Only commands that write commits, tags, notes, PRs, issues, work items, comments or releases.
        printf '%s' "$input" | grep -Eiq '(git[^"]* (commit|merge|tag|notes|rebase|cherry-pick|am|revert)|gh (pr|issue|api|release)|az (repos|boards|devops|pipelines)) |dev\.azure\.com|visualstudio\.com' || exit 0 ;;
esac
# Turn JSON "\n" escapes into real newlines so line-anchored trailer patterns match.
hits=$(printf '%s' "$input" | awk '{ gsub(/\\r\\n|\\n/, "\n"); print }' | sh "$guard" check 2>/dev/null)
rc=$?
# Block only on a real hit (check exits 1 and prints the lines). Any other failure (missing guard,
# broken install) fails open with a warning: blocking every tool call would make the agent unusable,
# and the commit-msg/pre-push hooks and CI still stand behind this check.
if [ "$rc" -eq 1 ] && [ -n "$hits" ]; then
    printf 'Blocked: this would publish AI attribution or a chat/session link, which the repository owner forbids.\nRemove these lines and retry:\n%s\n' "$hits" >&2
    exit 2
fi
[ "$rc" -eq 0 ] || printf 'attribution-guard: PreToolUse check failed (exit %s); not blocking. Reinstall tools/attribution-guard.\n' "$rc" >&2
exit 0
