#!/bin/sh
# Claude Code SessionStart hook for this repository.
# 1. Copy the guard into the repository's git directory (<git-common-dir>/attribution-guard) and point
#    core.hooksPath there, as an absolute path. The hooks then keep working when a branch from before
#    the guard is checked out, and with --git-dir / --work-tree, because nothing depends on the
#    worktree. The dispatcher also runs the repository's own hooks: .git/hooks, or the hooks path the
#    repository had before (saved as attributionguard.previousHooksPath).
#    The path is refreshed at every session start; after moving the clone, start a session (or run
#    this script) before committing, or git finds no hooks at all.
# 2. In cloud sessions, where git commits as the vendor identity, make the repository owner the
#    commit AUTHOR (cloud-author). GitHub credits every commit author as co-author of a squash
#    merge, so a vendor-authored commit would put the vendor on main even with a clean message.
#    The committer stays the cloud identity: the harness requires it for commit signing.
set -u
root=${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)} || exit 0
src="$root/tools/attribution-guard"
# Portable (git >= 2.5): --path-format=absolute is newer and older git echoes it back unrecognized.
common=$(cd "$root" 2>/dev/null && c=$(git rev-parse --git-common-dir 2>/dev/null) && cd "$c" 2>/dev/null && pwd) || common=
if [ -n "$common" ]; then
    d="$common/attribution-guard"
    if [ -f "$src/attribution-guard.sh" ] && [ -f "$src/dispatch" ]; then
        mkdir -p "$d/hooks"
        for f in attribution-guard.sh patterns.ere claude-pretooluse.sh dispatch; do
            [ -f "$src/$f" ] && tr -d '\r' <"$src/$f" >"$d/$f.tmp" && mv "$d/$f.tmp" "$d/$f"
        done
        for h in applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg \
                 commit-msg post-commit pre-rebase post-checkout post-merge pre-push post-rewrite pre-auto-gc \
                 sendemail-validate fsmonitor-watchman p4-changelist p4-prepare-changelist p4-post-changelist p4-pre-submit; do
            cp "$d/dispatch" "$d/hooks/$h" && chmod +x "$d/hooks/$h"
        done
    fi
    # An existing copy stays in force on a branch that has no tools/attribution-guard.
    if [ -x "$d/hooks/commit-msg" ]; then
        cur=$(git -C "$root" config --local --get core.hooksPath 2>/dev/null || true)
        prev=$(git -C "$root" config --local --get attributionguard.previousHooksPath 2>/dev/null || true)
        # A guard hooks directory is never the repository's own hooks path: after moving or copying
        # the clone, core.hooksPath still names the old one (and an older version saved it).
        case $prev in
            *[/\\]attribution-guard[/\\]hooks | *[/\\]attribution-guard[/\\]hooks[/\\])
                git -C "$root" config --local --unset attributionguard.previousHooksPath; prev= ;;
        esac
        case $cur in
            '' | .githooks | *[/\\]attribution-guard[/\\]hooks | *[/\\]attribution-guard[/\\]hooks[/\\]) ;;
            *) if [ -z "$prev" ]; then
                   git -C "$root" config --local attributionguard.previousHooksPath "$cur"
                   printf 'attribution-guard: core.hooksPath was %s; its hooks still run through the guard.\n' "$cur" >&2
               fi ;;
        esac
        git -C "$root" config --local core.hooksPath "$d/hooks"
    elif [ -d "$root/.githooks" ]; then
        git -C "$root" config --local core.hooksPath .githooks
    fi
fi

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
