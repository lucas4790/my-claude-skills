#!/usr/bin/env bash
# Adds the my-claude-skills marketplace to Claude Code and installs its plugins.
# Usage: install.sh [plugin ...]      (no args = every plugin in the marketplace)
#        curl -fsSL https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/install.sh | bash
set -euo pipefail

REPO="lucas4790/my-claude-skills"
NAME="my-claude-skills"
MANIFEST_URL="https://raw.githubusercontent.com/$REPO/main/.claude-plugin/marketplace.json"

command -v claude >/dev/null || { echo "error: 'claude' CLI not found — install Claude Code first: https://code.claude.com/docs" >&2; exit 1; }

if [ "$#" -gt 0 ]; then
  plugins=("$@")
else
  if command -v jq >/dev/null; then
    mapfile -t plugins < <(curl -fsSL "$MANIFEST_URL" | jq -r '.plugins[].name')
  elif command -v python3 >/dev/null; then
    mapfile -t plugins < <(curl -fsSL "$MANIFEST_URL" | python3 -c 'import json,sys; print("\n".join(p["name"] for p in json.load(sys.stdin)["plugins"]))')
  else
    echo "error: need jq or python3 to read the plugin list (or pass plugin names as arguments)" >&2; exit 1
  fi
fi

if claude plugin marketplace list 2>/dev/null | grep -q "$NAME"; then
  echo "==> updating marketplace $NAME"
  claude plugin marketplace update "$NAME"
else
  echo "==> adding marketplace $NAME"
  claude plugin marketplace add "$REPO"
fi

failed=()
for p in "${plugins[@]}"; do
  echo "==> installing $p"
  claude plugin install "$p@$NAME" || failed+=("$p")
done

echo
echo "Installed ${#plugins[@]} plugin(s) from $NAME."
[ "${#failed[@]}" -eq 0 ] || { echo "Failed: ${failed[*]}" >&2; }
cat <<'EOF'

Restart Claude Code to load them. Optional tooling some plugins rely on:
  .NET 10 SDK            (dotnet C# language server)   https://dot.net
  agent-browser          npm i -g agent-browser && agent-browser install
  uv                     (spec-kit)                     https://docs.astral.sh/uv/
  pwsh + PSScriptAnalyzer + Pester   (powershell skills)
EOF
[ "${#failed[@]}" -eq 0 ]
