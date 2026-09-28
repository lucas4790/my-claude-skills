#!/bin/sh
# Claude Code SessionStart hook for this repository.
# 1. Point git at the repo hooks (.githooks: commit-msg + pre-push attribution guard).
# 2. In cloud sessions, where git commits as the vendor identity, make the repository owner the
#    commit AUTHOR (cloud-author). GitHub credits every commit author as co-author of a squash
#    merge, so a vendor-authored commit would put the vendor on main even with a clean message.
#    The committer stays the cloud identity: the harness requires it for commit signing.
set -u
root=${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)} || exit 0
[ -d "$root/.githooks" ] && git -C "$root" config core.hooksPath .githooks

email=$(git -C "$root" config --get user.email 2>/dev/null || true)
case $email in
    noreply@anthropic.com)
        author=$(sed -n '1p' "$root/tools/attribution-guard/cloud-author" 2>/dev/null)
        name=${author% <*}; mail=${author#*<}; mail=${mail%>}
        if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -n "$name" ] && [ -n "$mail" ] && [ "$mail" != "$author" ]; then
            printf "export GIT_AUTHOR_NAME='%s'\nexport GIT_AUTHOR_EMAIL='%s'\n" "$name" "$mail" >>"$CLAUDE_ENV_FILE"
        fi ;;
esac
exit 0
