#!/usr/bin/env bash
# Installs Claude Code if missing, adds the my-claude-skills marketplace, installs its plugins,
# and installs the CLI tools some plugins depend on (agent-browser, uv, pwsh, .NET SDK, pyright).
# Usage: install.sh [plugin ...]      (no args = every plugin in the marketplace)
#        curl -fsSL https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/install.sh | bash
set -euo pipefail

REPO="lucas4790/my-claude-skills"
NAME="my-claude-skills"
MANIFEST_URL="https://raw.githubusercontent.com/$REPO/main/.claude-plugin/marketplace.json"

warn() { echo "warning: $*" >&2; }
has()  { command -v "$1" >/dev/null 2>&1; }
selected() { printf '%s\n' "${plugins[@]}" | grep -qx "$1"; }

# --- base dependencies ---------------------------------------------------------
# git + curl: Claude Code and marketplace cloning; jq: manifest parsing; node/npm: caveman hooks, agent-browser
pkg_install() {
  if [ "$(uname -s)" = Darwin ] && has brew; then brew install "$@"
  elif has apt-get; then sudo apt-get update -qq && sudo apt-get install -y "$@"
  elif has dnf; then sudo dnf install -y "$@"
  else return 1; fi
}
missing=()
has git  || missing+=(git)
has curl || missing+=(curl)
has jq   || missing+=(jq)
if ! has node || ! has npm; then
  if has apt-get; then missing+=(nodejs npm); else missing+=(node); fi
fi
if [ "${#missing[@]}" -gt 0 ]; then
  echo "==> installing base dependencies: ${missing[*]} (sudo)"
  pkg_install "${missing[@]}" || { echo "error: could not install ${missing[*]}; install them manually and re-run" >&2; exit 1; }
fi
echo "==> base deps: git $(git --version | awk '{print $3}'), node $(node --version), jq $(jq --version)"

# --- desktop app check ---------------------------------------------------------
# Plugins live in ~/.claude/plugins, which both the desktop app and the CLI read, so
# installing via the CLI here also reaches the desktop app (after it is restarted).
# The desktop app has no plugin-install command of its own, so the CLI is still needed
# either way; this just makes sure that's not a surprise when only the desktop app is around.
# (The desktop app only ships for macOS and Windows; there is nothing to detect on Linux.)
has_desktop_claude() { [ "$(uname -s)" = Darwin ] && [ -d "/Applications/Claude.app" ]; }
if has_desktop_claude; then
  if has claude; then
    echo "==> found both the Claude desktop app and the claude CLI"
  else
    echo "==> found the Claude desktop app (no claude CLI yet)"
  fi
  if [ -z "${MY_CLAUDE_SKILLS_YES:-}" ]; then
    read -r -p "    Continue installing/updating plugins via the CLI, shared with the desktop app? [y/N] " reply
    case "$reply" in
      [yY]*) ;;
      *) echo "Aborted at your request."; exit 0 ;;
    esac
  fi
fi

# --- Claude Code -------------------------------------------------------------
if ! has claude; then
  echo "==> Claude Code not found, installing"
  curl -fsSL https://claude.ai/install.sh | bash
  export PATH="$HOME/.local/bin:$PATH"
  has claude || { echo "error: claude still not on PATH after install; open a new shell and re-run" >&2; exit 1; }
fi
echo "==> claude $(claude --version 2>/dev/null | head -1)"

# --- plugin list --------------------------------------------------------------
if [ "$#" -gt 0 ]; then
  plugins=("$@")
elif has jq; then
  mapfile -t plugins < <(curl -fsSL "$MANIFEST_URL" | jq -r '.plugins[].name')
elif has python3; then
  mapfile -t plugins < <(curl -fsSL "$MANIFEST_URL" | python3 -c 'import json,sys; print("\n".join(p["name"] for p in json.load(sys.stdin)["plugins"]))')
else
  echo "error: need jq or python3 to read the plugin list (or pass plugin names as arguments)" >&2; exit 1
fi

# --- marketplace + plugins ----------------------------------------------------
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
echo "Installed ${#plugins[@]} plugin(s) from $NAME."
[ "${#failed[@]}" -eq 0 ] || warn "failed plugins: ${failed[*]}"

# --- tools --------------------------------------------------------------------
if selected agent-browser; then
  if has agent-browser; then
    echo "==> agent-browser present"
  elif has npm; then
    echo "==> installing agent-browser"
    if [ -w "$(npm config get prefix)/lib/node_modules" ] 2>/dev/null; then
      npm install -g agent-browser
    else
      npm install -g --prefix "$HOME/.local" agent-browser
      export PATH="$HOME/.local/bin:$PATH"
    fi
    if [ "$(uname -s)" = Linux ]; then
      echo "    Linux: installing Chrome + system libraries (sudo)"
      agent-browser install --with-deps || warn "agent-browser install failed; run: agent-browser install --with-deps"
    else
      agent-browser install || warn "agent-browser install failed; run: agent-browser install"
    fi
  else
    warn "npm not found; install Node.js then run: npm i -g agent-browser && agent-browser install"
  fi
fi

if selected spec-kit; then
  if has uv; then
    echo "==> uv present ($(uv --version))"
  else
    echo "==> installing uv"
    curl -LsSf https://astral.sh/uv/install.sh | sh || warn "uv install failed; see https://docs.astral.sh/uv/"
  fi
fi

if selected powershell; then
  if has pwsh; then
    echo "==> pwsh present ($(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null))"
  elif [ "$(uname -s)" = Darwin ] && has brew; then
    echo "==> installing pwsh via Homebrew"
    brew install --cask powershell || warn "pwsh install failed"
  elif has snap; then
    echo "==> installing pwsh via snap (sudo)"
    sudo snap install powershell --classic || warn "pwsh install failed; see https://learn.microsoft.com/powershell/scripting/install/install-ubuntu"
  elif has dotnet; then
    echo "==> installing pwsh as dotnet global tool"
    dotnet tool install --global PowerShell || warn "pwsh install failed"
  else
    warn "no snap/brew/dotnet; install PowerShell manually: https://learn.microsoft.com/powershell/scripting/install"
  fi
  if has pwsh; then
    pwsh -NoProfile -Command 'foreach ($m in "PSScriptAnalyzer","Pester") { if (-not (Get-Module -ListAvailable $m)) { Install-Module $m -Scope CurrentUser -Force } }' \
      || warn "PSScriptAnalyzer/Pester install failed; run Install-Module manually"
  fi
fi

if selected dotnet; then
  if dotnet --list-sdks 2>/dev/null | grep -q '^10\.'; then
    echo "==> .NET 10 SDK present ($(dotnet --version))"
  elif [ "$(uname -s)" = Darwin ] && has brew; then
    echo "==> installing .NET 10 SDK via Homebrew"
    brew install --cask dotnet-sdk || warn ".NET SDK install failed; see https://dot.net"
  elif has apt-get && apt-cache policy dotnet-sdk-10.0 2>/dev/null | grep -q "Candidate:.*[0-9]"; then
    echo "==> installing .NET 10 SDK via apt (sudo)"
    sudo apt-get install -y dotnet-sdk-10.0 || warn ".NET SDK install failed; see https://dot.net"
  else
    echo "==> installing .NET 10 SDK to ~/.dotnet (user-local)"
    curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 10.0 || warn ".NET SDK install failed; see https://dot.net"
    export DOTNET_ROOT="$HOME/.dotnet" PATH="$HOME/.dotnet:$PATH"
    echo "    add to your shell profile: export DOTNET_ROOT=\$HOME/.dotnet PATH=\$HOME/.dotnet:\$PATH"
  fi
fi

if selected pyright-lsp; then
  if has pyright-langserver; then
    echo "==> pyright present"
  else
    echo "==> installing pyright"
    if [ -w "$(npm config get prefix)/lib/node_modules" ] 2>/dev/null; then npm install -g pyright
    else npm install -g --prefix "$HOME/.local" pyright; fi || warn "pyright install failed; run: npm i -g pyright"
  fi
fi

if selected terraform; then
  if has docker && docker info >/dev/null 2>&1; then
    echo "==> docker present (terraform MCP server runs as a container)"
  else
    warn "docker not running; the terraform plugin's MCP server needs docker: https://docs.docker.com/engine/install/"
  fi
fi

# --- startup auto-update hook -----------------------------------------------------
# SessionStart hook runs update-plugins.sh in the background: refreshes the marketplace,
# installs plugins added upstream, updates installed ones (throttled to every 6 h).
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/$NAME"
mkdir -p "$DATA"
local_copy="$(dirname "${BASH_SOURCE[0]:-/nonexistent}")/scripts/update-plugins.sh"
if [ -f "$local_copy" ]; then
  cp "$local_copy" "$DATA/update-plugins.sh"
elif ! curl -fsSL "https://raw.githubusercontent.com/$REPO/main/scripts/update-plugins.sh" -o "$DATA/update-plugins.sh"; then
  warn "could not fetch update-plugins.sh; startup auto-update hook not installed"
  DATA=""
fi
[ -z "$DATA" ] || chmod +x "$DATA/update-plugins.sh"
SETTINGS="$HOME/.claude/settings.json"
[ -s "$SETTINGS" ] || { mkdir -p "$HOME/.claude"; echo '{}' > "$SETTINGS"; }
if [ -z "$DATA" ]; then
  :
elif grep -q "$NAME/update-plugins.sh" "$SETTINGS"; then
  echo "==> startup auto-update hook already registered"
else
  echo "==> registering SessionStart auto-update hook in $SETTINGS"
  hook=$(jq -n --arg cmd "bash \"$DATA/update-plugins.sh\"" \
    '{matcher: "startup", hooks: [{type: "command", command: $cmd, async: true}]}')
  tmp=$(mktemp) && jq --argjson h "$hook" '.hooks.SessionStart = ((.hooks.SessionStart // []) + [$h])' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
fi

echo
echo "Done. Restart Claude Code to load the plugins."
[ "${#failed[@]}" -eq 0 ]
