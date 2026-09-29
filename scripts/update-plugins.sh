#!/usr/bin/env bash
# Refreshes the my-claude-skills marketplace, updates the installed plugins, and installs the ones
# added to the marketplace since the last run, so plugins left out of a subset install or uninstalled
# stay out. The names it has seen are in plugins/my-claude-skills-known-plugins of the Claude config
# dir, one list per config (install.sh writes the first). Runs from a Claude Code SessionStart hook
# (in the background) and throttles itself to once per interval; changes apply to the next session.
#   update-plugins.sh            throttled run (default every 6 h; MY_CLAUDE_SKILLS_INTERVAL=seconds)
#   update-plugins.sh --force    run now
set -uo pipefail

NAME="my-claude-skills"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/$NAME"
STAMP="$CACHE/last-run"
LOG="$CACHE/update.log"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
KNOWN="$CLAUDE_DIR/plugins/$NAME-known-plugins"   # per config dir: each has its own plugins
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

# Copilot CLI copies (install-copilot.sh; VS Code reads the same ones): update only what is
# installed there. New plugins are never added, so a Copilot profile stays a profile.
if command -v copilot >/dev/null; then
  copilot plugin marketplace update "$NAME" || echo "copilot marketplace update failed"
  while IFS= read -r p; do
    [ -n "$p" ] && { copilot plugin update "$p@$NAME" || echo "copilot update failed: $p"; }
  done < <(copilot plugin list --json 2>/dev/null | jq -r --arg m "$NAME" '.[] | select(.marketplace == $m) | .name')
fi

claude plugin marketplace update "$NAME" || { echo "marketplace update failed"; exit 1; }
clone="$CLAUDE_DIR/plugins/marketplaces/$NAME"

# install.sh copied this script once: refresh that copy from the marketplace clone so updater fixes
# reach this machine. mv gives it a new inode while bash keeps reading the old one, so the new copy
# runs next time. Only a file named update-plugins.sh: piped to bash (bash -s, bash -c) there is no
# script file and $0 is the shell. Not in a checkout of the repo (.claude-plugin/ next to scripts/):
# that would overwrite its working tree.
self="${BASH_SOURCE[0]:-}"
self_new="$clone/scripts/update-plugins.sh"
if [ -n "$self" ] && [ "${self##*/}" = update-plugins.sh ] && [ -f "$self" ] && [ -f "$self_new" ] \
  && [ ! -f "$(dirname "$self")/../.claude-plugin/marketplace.json" ] && ! cmp -s "$self_new" "$self"; then
  if cp "$self_new" "$self.$$" && mv -f "$self.$$" "$self"; then
    echo "refreshed $self from the marketplace (applies next run)"
  else
    rm -f "$self.$$"; echo "could not refresh $self"
  fi
fi

# Keep the attribution guard current (patterns, hooks, Claude Code PreToolUse registration) from
# the marketplace clone, but only where it was installed and not opted out (docs/ATTRIBUTION.md).
guard="$clone/tools/attribution-guard/install.sh"
guard_home="${XDG_CONFIG_HOME:-$HOME/.config}/git/attribution-guard"
if [ "${MY_CLAUDE_SKILLS_ATTRIBUTION:-}" != keep ] && [ -f "$guard" ] && [ -d "$guard_home" ]; then
  sh "$guard" || echo "attribution guard refresh failed"   # install.sh keeps the mode and an opted-in hooks path
fi

mp="$clone/.claude-plugin/marketplace.json"
[ -f "$mp" ] || { echo "marketplace manifest not found at $mp"; exit 1; }
names=$(jq -r '.plugins[].name' "$mp") || { echo "could not read the plugin names from $mp"; exit 1; }
available=()   # while-read, not mapfile: macOS still ships bash 3.2
while IFS= read -r p; do [ -n "$p" ] && available+=("$p"); done <<<"$names"

# Without a list of what is installed, only update: installing would bring back every plugin that
# was left out or uninstalled.
listed=0 installed=""
if json=$(claude plugin list --json 2>/dev/null) && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$json" \
  && installed=$(jq -r --arg m "@$NAME" '.[] | select(.id | endswith($m)) | .id | sub($m; "")' <<<"$json"); then
  listed=1
else
  echo "claude plugin list --json failed or gave no JSON list: updating only, installing no new plugins"
fi

# New plugins are the ones in the marketplace but not in the snapshot of the earlier runs. Without a
# snapshot yet for this config dir (installed before install.sh wrote one), record one and install nothing.
if [ "$listed" = 1 ] && [ ! -s "$KNOWN" ]; then
  echo "no plugin snapshot yet: recording the marketplace's ${#available[@]} plugins, installing none"
fi
known=()
for p in ${available[@]+"${available[@]}"}; do
  if [ "$listed" = 0 ] || printf '%s\n' "$installed" | grep -qxF -- "$p"; then
    claude plugin update "$p@$NAME" 2>&1 | grep -vE "already up to date|is already" || true
  elif [ -s "$KNOWN" ] && ! grep -qxF -- "$p" "$KNOWN"; then
    echo "new plugin: $p"
    claude plugin install "$p@$NAME" || { echo "install failed: $p (retried next run)"; continue; }
  fi
  known+=("$p")
done

# Only after a pass that saw what is installed. The snapshot keeps the names of earlier runs, so a
# plugin that leaves the marketplace and comes back later is not new again. A failed install was not
# in it and is not added, so it is retried.
if [ "$listed" = 1 ] && [ "${#known[@]}" -gt 0 ]; then
  if [ -s "$KNOWN" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] && ! printf '%s\n' "${known[@]}" | grep -qxF -- "$p" && known+=("$p")
    done < "$KNOWN"
  fi
  printf '%s\n' "${known[@]}" > "$KNOWN.$$" && mv -f "$KNOWN.$$" "$KNOWN"
fi
echo "done"
