#!/usr/bin/env bash
# Refreshes the my-claude-skills marketplace, installs plugins added upstream, and updates the
# installed ones. Runs from a Claude Code SessionStart hook (in the background) and throttles
# itself to once per interval; changes apply to the next session.
#   update-plugins.sh            throttled run (default every 6 h; MY_CLAUDE_SKILLS_INTERVAL=seconds)
#   update-plugins.sh --force    run now
set -uo pipefail

NAME="my-claude-skills"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/$NAME"
STAMP="$CACHE/last-run"
LOG="$CACHE/update.log"
INTERVAL="${MY_CLAUDE_SKILLS_INTERVAL:-21600}"
mkdir -p "$CACHE"

if [ "${1:-}" != "--force" ] && [ -f "$STAMP" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$STAMP" 2>/dev/null || stat -f %m "$STAMP") ))
  [ "$age" -lt "$INTERVAL" ] && exit 0
fi
touch "$STAMP"

command -v claude >/dev/null || exit 0
command -v jq >/dev/null || exit 0
exec >>"$LOG" 2>&1
echo "=== $(date -u +%FT%TZ)"

claude plugin marketplace update "$NAME" || { echo "marketplace update failed"; exit 1; }

mp="$HOME/.claude/plugins/marketplaces/$NAME/.claude-plugin/marketplace.json"
[ -f "$mp" ] || { echo "marketplace manifest not found at $mp"; exit 1; }
mapfile -t available < <(jq -r '.plugins[].name' "$mp")
mapfile -t installed < <(claude plugin list --json 2>/dev/null | jq -r --arg m "@$NAME" '.[] | select(.id | endswith($m)) | .id | sub($m; "")')

for p in "${available[@]}"; do
  if printf '%s\n' "${installed[@]}" | grep -qx "$p"; then
    claude plugin update "$p@$NAME" 2>&1 | grep -vE "already up to date|is already" || true
  else
    echo "new plugin: $p"
    claude plugin install "$p@$NAME"
  fi
done
echo "done"
