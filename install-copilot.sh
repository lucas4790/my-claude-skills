#!/usr/bin/env bash
# Installs the my-claude-skills marketplace for GitHub Copilot: Copilot CLI, and through it VS Code
# (VS Code discovers plugins installed by Copilot CLI in ~/.copilot/installed-plugins).
# Claude Code keeps using install.sh; both read the same .claude-plugin/marketplace.json.
# Usage: install-copilot.sh                      (profiles in profiles.json "copilotDefault": cloud)
#        install-copilot.sh --profile cloud,dotnet
#        install-copilot.sh terraform pyright-lsp  (explicit plugins; claude-only ones allowed)
#        curl -fsSL https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/install-copilot.sh | bash
set -euo pipefail

REPO="lucas4790/my-claude-skills"
NAME="my-claude-skills"
RAW="https://raw.githubusercontent.com/$REPO/main"
MIN_COPILOT="1.0.70"   # first release that honours the sha pin on url sources (caveman)

warn() { echo "warning: $*" >&2; }
die()  { echo "error: $*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

# version_ge A B: true when dotted version A >= B
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]; }

profiles_json() {
  local here
  here="$(dirname "${BASH_SOURCE[0]:-/nonexistent}")"
  if [ -f "$here/profiles.json" ]; then cat "$here/profiles.json"; else curl -fsSL "$RAW/profiles.json"; fi
}

main() {
  local profile="" explicit=() p
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --profile) profile="${2:-}"; shift 2 ;;
      --profile=*) profile="${1#--profile=}"; shift ;;
      -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}"; exit 0 ;;
      -*) die "unknown option $1" ;;
      *) explicit+=("$1"); shift ;;
    esac
  done

  has jq  || die "jq is required (apt/dnf/brew install jq)"
  has git || die "git is required"

  # --- Copilot CLI ---------------------------------------------------------------
  if ! has copilot; then
    has npm || die "Copilot CLI not found and npm is missing; install Node.js 22+ or see https://docs.github.com/copilot/how-tos/copilot-cli"
    echo "==> installing GitHub Copilot CLI (npm -g @github/copilot)"
    if [ -w "$(npm config get prefix)/lib/node_modules" ] 2>/dev/null; then
      npm install -g @github/copilot
    else
      npm install -g --prefix "$HOME/.local" @github/copilot
      export PATH="$HOME/.local/bin:$PATH"
    fi
    has copilot || die "copilot still not on PATH; open a new shell and re-run"
  fi
  local ver
  ver=$(copilot --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  echo "==> copilot ${ver:-unknown}"
  if [ -n "$ver" ] && ! version_ge "$ver" "$MIN_COPILOT"; then
    warn "Copilot CLI $ver is older than $MIN_COPILOT (sha-pinned sources such as caveman need it); run: copilot update"
  fi

  # --- plugin list -----------------------------------------------------------------
  local pj plugins=()
  pj=$(profiles_json) || die "could not read profiles.json"
  if [ "${#explicit[@]}" -gt 0 ]; then
    plugins=("${explicit[@]}")
  else
    local sel
    if [ -n "$profile" ]; then sel=$(jq -cn --arg p "$profile" '$p | split(",")')
    else sel=$(jq -c '.copilotDefault' <<<"$pj"); fi
    local unknown
    unknown=$(jq -r --argjson s "$sel" '. as $r | [$s[] as $x | select($r.profiles | has($x) | not) | $x] | join(" ")' <<<"$pj")
    [ -z "$unknown" ] || die "unknown profile(s): $unknown (see profiles.json)"
    while IFS= read -r p; do [ -n "$p" ] && plugins+=("$p"); done < <(
      jq -r --argjson s "$sel" '. as $r | $s[] | select(. != "claude-only") | $r.profiles[.][]' <<<"$pj")
    if jq -e --argjson s "$sel" '$s | index("claude-only")' >/dev/null <<<"$pj"; then
      warn "skipping profile claude-only (needs Claude Code); name its plugins explicitly to install them anyway"
    fi
  fi
  [ "${#plugins[@]}" -gt 0 ] || die "no plugins selected"

  # --- marketplace + plugins ------------------------------------------------------
  if copilot plugin marketplace list 2>/dev/null | grep -q "$NAME"; then
    echo "==> updating marketplace $NAME"
    copilot plugin marketplace update "$NAME" || warn "marketplace update failed"
  else
    echo "==> adding marketplace $NAME"
    copilot plugin marketplace add "$REPO"
  fi

  local failed=()
  for p in "${plugins[@]}"; do
    echo "==> installing $p"
    copilot plugin install "$p@$NAME" || failed+=("$p")
  done
  echo "Installed ${#plugins[@]} plugin(s) from $NAME into Copilot CLI."
  [ "${#failed[@]}" -eq 0 ] || warn "failed plugins: ${failed[*]}"

  # --- auto-update ------------------------------------------------------------------
  # Copilot CLI refreshes a user-added marketplace at session start only with autoUpdate: true.
  local cfg="${COPILOT_HOME:-$HOME/.copilot}/settings.json" tmp
  if [ -f "$cfg" ] && jq -e . "$cfg" >/dev/null 2>&1; then
    tmp=$(mktemp)
    jq --arg n "$NAME" --arg r "$REPO" \
      '.extraKnownMarketplaces[$n] = ((.extraKnownMarketplaces[$n] // {source: {source: "github", repo: $r}}) + {autoUpdate: true})' \
      "$cfg" > "$tmp" && cat "$tmp" > "$cfg" && rm -f "$tmp"   # cat keeps a symlinked settings.json intact
    echo "==> enabled autoUpdate for $NAME in $cfg"
  else
    warn "$cfg missing or not plain JSON; set extraKnownMarketplaces.$NAME.autoUpdate = true by hand"
  fi

  cat <<EOF

Done. Copilot CLI: start a new session, then check with 'copilot plugin list' and 'copilot skill list'.

VS Code (GitHub Copilot Chat, VS Code 1.110+) picks these plugins up automatically. Once:
  1. Settings: make sure "chat.plugins.enabled" is on (locked if your organisation manages it).
  2. Settings: "chat.plugins.marketplaces" -> Add Item -> $REPO  (keep the default entries).
  3. Developer: Reload Window, then Extensions view -> @agentPlugins to see and manage them.
  Template with the other useful settings: settings/vscode-settings.jsonc in $REPO.
  WSL: VS Code on Windows with Remote-WSL may read the Windows-side ~/.copilot; run install-copilot.ps1 there too.
EOF
  [ "${#failed[@]}" -eq 0 ]
}

main "$@"
