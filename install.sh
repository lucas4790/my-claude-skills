#!/usr/bin/env bash
# Installs Claude Code if missing, adds the my-claude-skills marketplace, installs its plugins,
# and installs the CLI tools some plugins depend on (agent-browser, uv, pwsh, .NET SDK, pyright,
# yaml-language-server, yamllint).
# Usage: install.sh                           (every plugin in the marketplace)
#        install.sh --profile cloud,dotnet    (the plugins of these profiles in profiles.json; the updater then
#                                              installs only new plugins of them and lists the others as available)
#        install.sh dotnet powershell         (explicit plugins; combinable with --profile)
#        curl -fsSL https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/install.sh | bash -s -- --profile cloud
set -euo pipefail

REPO="lucas4790/my-claude-skills"
NAME="my-claude-skills"
MANIFEST_URL="https://raw.githubusercontent.com/$REPO/main/.claude-plugin/marketplace.json"
# The directory this script runs from (a checkout, or "/" under `curl | bash`). Resolved at top
# level: inside a function BASH_SOURCE[0] would be "main" when the script is piped to bash.
HERE="$(dirname "${BASH_SOURCE[0]:-/nonexistent}")"
# This script's path; empty under `curl | bash`.
SRC="${BASH_SOURCE[0]:-}"
YAMLLINT_MIN="1.30"   # yaml-hooks' default config uses the anchors rule (1.30) and --list-files (1.29)

warn() { echo "warning: $*" >&2; }
die()  { echo "error: $*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }
selected() { printf '%s\n' "${plugins[@]}" | grep -qx "$1"; }
# version_ge A B: true when dotted version A >= B
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]; }
# yamllint_version: the version of the yamllint on PATH, empty when there is none
yamllint_version() { { yamllint --version 2>/dev/null || true; } | grep -oE '[0-9]+(\.[0-9]+)+' | head -1 || true; }

# profiles.json of the checkout this script runs from, else of the repo's main branch. A checkout is recognised
# by its marketplace manifest, so a stray profiles.json elsewhere is never used. (Copied from install-copilot.sh,
# which cannot be sourced under `curl | bash`: keep the two in step; the installers.bats parity test checks it.)
profiles_json() {
  if [ -n "$SRC" ] && [ -f "$HERE/.claude-plugin/marketplace.json" ] && [ -f "$HERE/profiles.json" ]; then
    cat "$HERE/profiles.json"
  else
    curl -fsSL "https://raw.githubusercontent.com/$REPO/main/profiles.json"
  fi
}

usage() {
  if [ -n "$SRC" ] && [ -f "$SRC" ]; then sed -n '5,9p' "$SRC"
  else echo "Usage: install.sh [--profile NAME[,NAME...]] [plugin ...]  (profiles: https://raw.githubusercontent.com/$REPO/main/profiles.json)"; fi
}

# Everything runs from main, called on the last line: a download cut off halfway runs nothing.
main() {
  local profile="" profile_given=0 explicit=() p
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --profile) [ "$#" -ge 2 ] || die "--profile needs a value (e.g. --profile cloud,dotnet)"; profile="${profile:+$profile,}$2"; profile_given=1; shift 2 ;;
      --profile=*) profile="${profile:+$profile,}${1#--profile=}"; profile_given=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) die "unknown option $1" ;;
      *) explicit+=("$1"); shift ;;
    esac
  done

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

  # --- plugin list --------------------------------------------------------------
  # Resolved before anything is installed but the base dependencies: an unknown profile stops here.
  # (The profile part is the same as install-copilot.sh's, minus its claude-only and default handling.)
  plugins=() members=() chosen=()
  if [ "$profile_given" = 1 ]; then
    # names split at commas, trimmed, without duplicates, in the order given
    sel=$(jq -cn --arg p "$profile" '[$p | split(",")[] | gsub("^\\s+|\\s+$"; "") | select(. != "")] | reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end)') \
      || die "could not read the profile names"
    [ "$sel" != "[]" ] || die "--profile needs a value (e.g. --profile cloud,dotnet)"
    pj=$(profiles_json) || die "could not read profiles.json"
    unknown=$(jq -r --argjson s "$sel" '. as $r | [$s[] as $x | select($r.profiles | has($x) | not) | $x] | join(" ")' <<<"$pj") \
      || die "profiles.json has no profiles"
    [ -z "$unknown" ] || die "unknown profile(s): $unknown (available: $(jq -r '.profiles | keys_unsorted | join(", ")' <<<"$pj"))"
    while IFS= read -r p; do [ -n "$p" ] && members+=("$p"); done < <(jq -r --argjson s "$sel" '. as $r | $s[] | $r.profiles[.][]' <<<"$pj")
    while IFS= read -r p; do [ -n "$p" ] && chosen+=("$p"); done < <(jq -r '.[]' <<<"$sel")
    plugins=(${members[@]+"${members[@]}"})
    echo "==> profiles $(IFS=,; echo "${chosen[*]}"): ${#members[@]} plugin(s)"
  fi
  for p in ${explicit[@]+"${explicit[@]}"}; do
    # `--profile cloud dotnet` (no comma) names the plugin dotnet, not the profile
    if [ "$profile_given" = 1 ] && jq -e --arg p "$p" '.profiles | has($p)' >/dev/null <<<"$pj"; then
      warn "$p is also a profile name; it is installed as the plugin of that name. For the profile too: --profile $profile,$p"
    fi
    printf '%s\n' ${plugins[@]+"${plugins[@]}"} | grep -qxF -- "$p" || plugins+=("$p")
  done
  if [ "$profile_given" = 0 ] && [ "${#explicit[@]}" -eq 0 ]; then
    # while-read, not mapfile: macOS still ships bash 3.2
    names=$(curl -fsSL "$MANIFEST_URL" | jq -r '.plugins[].name') \
      || die "could not read the plugin list from $MANIFEST_URL (or pass plugin names as arguments)"
    while IFS= read -r p; do [ -n "$p" ] && plugins+=("$p"); done <<<"$names"
  fi
  [ "${#plugins[@]}" -gt 0 ] || die "no plugins to install"

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
      # Ask the terminal: under `curl | bash` stdin is this script itself.
      if ! (true </dev/tty) 2>/dev/null; then
        echo "error: no terminal to ask whether to continue; set MY_CLAUDE_SKILLS_YES=1 to skip the question" >&2
        exit 1
      fi
      read -r -p "    Continue installing/updating plugins via the CLI, shared with the desktop app? [y/N] " reply </dev/tty || reply=""
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
  # With profiles the updater retries a failed plugin of the profiles; a named one outside them is only offered as available.
  lost=()
  if [ "$profile_given" = 1 ]; then
    for p in ${failed[@]+"${failed[@]}"}; do
      printf '%s\n' ${members[@]+"${members[@]}"} | grep -qxF -- "$p" || lost+=("$p")
    done
    [ "${#lost[@]}" -eq 0 ] || warn "the updater does not retry ${lost[*]} (outside the profiles); re-run this installer to retry"
  fi

  # The updater's list of known plugins for this Claude config dir (see update-plugins.sh). A first
  # install records every plugin in the marketplace but the failed ones: plugins left out stay out,
  # and the next update retries a failed one (with --profile: only a failed plugin of the profiles).
  # A re-run adds the plugins it installed and takes the failed ones out.
  claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  known_file="$claude_dir/plugins/$NAME-known-plugins"
  if [ -s "$known_file" ]; then
    known=$(cat "$known_file"; printf '%s\n' "${plugins[@]}") || known=""
  else
    known=$(jq -r '.plugins[].name' "$claude_dir/plugins/marketplaces/$NAME/.claude-plugin/marketplace.json" 2>/dev/null) || known=""
  fi
  if [ -n "$known" ] && ! { printf '%s\n' "$known" \
    | awk -v failed=" ${failed[*]:-} " 'NF && !seen[$0]++ && !index(failed, " " $0 " ")' > "$known_file.$$" \
    && mv -f "$known_file.$$" "$known_file"; }; then
    rm -f "$known_file.$$"
    warn "could not write $known_file; the updater's first run records the plugins instead"
  fi

  # The profiles this config dir follows (see update-plugins.sh): with --profile, the profiles and a snapshot
  # of their plugins without the failed ones (the next update retries those; the file stays, empty, when
  # every one failed: a missing file means no snapshot yet); without --profile and plugin names, everything
  # was installed and the record goes; plugin names alone leave it as it is.
  profiles_file="$claude_dir/plugins/$NAME-profiles"
  pknown_file="$claude_dir/plugins/$NAME-profile-plugins"
  if [ "$profile_given" = 1 ]; then
    mkdir -p "$claude_dir/plugins" 2>/dev/null || true
    if printf '%s\n' "${chosen[@]}" > "$profiles_file.$$" && mv -f "$profiles_file.$$" "$profiles_file"; then
      pknown=$(printf '%s\n' ${members[@]+"${members[@]}"} \
        | awk -v failed=" ${failed[*]:-} " 'NF && !seen[$0]++ && !index(failed, " " $0 " ")') || pknown=""
      if ! { { [ -z "$pknown" ] || printf '%s\n' "$pknown"; } > "$pknown_file.$$" && mv -f "$pknown_file.$$" "$pknown_file"; }; then
        rm -f "$pknown_file.$$"
        warn "could not write $pknown_file; the updater keeps the earlier snapshot, or records the plugins of the profiles at its first run"
      fi
    else
      rm -f "$profiles_file.$$"
      warn "could not write $profiles_file; the updater keeps following the earlier record, or installs every new plugin, until you re-run with --profile"
    fi
  elif [ "${#explicit[@]}" -eq 0 ]; then
    rm -f "$profiles_file" "$pknown_file"
  fi

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
      # Pester 6 unless one is present (an older Pester does not count), as install.ps1 does;
      # -SkipPublisherCheck: an older Pester may be signed with another certificate
      pwsh -NoProfile -Command 'if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { Install-Module PSScriptAnalyzer -Scope CurrentUser -Force }; if (-not (Get-Module -ListAvailable Pester | Where-Object Version -ge 6.0.0)) { Install-Module Pester -MinimumVersion 6.0.0 -Scope CurrentUser -Force -SkipPublisherCheck }' \
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

  if selected yaml-lsp; then
    if has yaml-language-server; then
      echo "==> yaml-language-server present"
    else
      echo "==> installing yaml-language-server"
      if [ -w "$(npm config get prefix)/lib/node_modules" ] 2>/dev/null; then npm install -g yaml-language-server
      else npm install -g --prefix "$HOME/.local" yaml-language-server; fi || warn "yaml-language-server install failed; run: npm i -g yaml-language-server"
    fi
  fi

  if selected yaml-hooks; then
    yl=$(yamllint_version)
    if [ -n "$yl" ] && version_ge "$yl" "$YAMLLINT_MIN"; then
      echo "==> yamllint present ($yl)"
    else
      # an older yamllint (e.g. a distro package) is replaced by a current one from pipx or uv
      [ -z "$yl" ] || echo "==> yamllint $yl is older than $YAMLLINT_MIN, which the yaml-hooks hook needs"
      if has pipx; then
        echo "==> installing yamllint via pipx"
        pipx install --force yamllint || warn "yamllint install failed; run: pipx install yamllint"
        export PATH="$HOME/.local/bin:$PATH"
      elif has uv; then
        echo "==> installing yamllint via uv tool"
        uv tool install --force --upgrade yamllint || warn "yamllint install failed; run: uv tool install yamllint"
        export PATH="$HOME/.local/bin:$PATH"
      elif [ -z "$yl" ]; then
        echo "==> installing yamllint via the system package manager"
        pkg_install yamllint || python3 -m pip install --user yamllint \
          || warn "yamllint install failed; run: pipx install yamllint (the yaml-hooks hook does nothing without it)"
      fi
      yl=$(yamllint_version)
      if [ -n "$yl" ] && ! version_ge "$yl" "$YAMLLINT_MIN"; then
        warn "yamllint $yl ($(command -v yamllint)) is older than $YAMLLINT_MIN: the yaml-hooks hook does not lint with it (it only reports that it is inactive)." \
          "Install a current one first on PATH: pipx install yamllint (or uv tool install yamllint)"
      fi
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
  # installs plugins added upstream since its last run, updates installed ones (throttled to every 6 h).
  DATA="${XDG_DATA_HOME:-$HOME/.local/share}/$NAME"
  mkdir -p "$DATA"
  local_copy="$HERE/scripts/update-plugins.sh"
  if [ -f "$local_copy" ]; then
    cp "$local_copy" "$DATA/update-plugins.sh"
  elif ! curl -fsSL "https://raw.githubusercontent.com/$REPO/main/scripts/update-plugins.sh" -o "$DATA/update-plugins.sh"; then
    warn "could not fetch update-plugins.sh; startup auto-update hook not installed"
    DATA=""
  fi
  [ -z "$DATA" ] || chmod +x "$DATA/update-plugins.sh"
  SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
  [ -s "$SETTINGS" ] || { mkdir -p "$(dirname "$SETTINGS")"; echo '{}' > "$SETTINGS"; }
  if [ -z "$DATA" ]; then
    :
  elif grep -q "$NAME/update-plugins.sh" "$SETTINGS"; then
    echo "==> startup auto-update hook already registered"
  else
    hook=$(jq -nc --arg cmd "bash \"$DATA/update-plugins.sh\"" \
      '{matcher: "startup", hooks: [{type: "command", command: $cmd, async: true}]}')
    if jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1; then
      echo "==> registering SessionStart auto-update hook in $SETTINGS"
      tmp=$(mktemp)   # cat, not mv: keeps a symlinked settings.json intact
      if ! { jq --argjson h "$hook" '.hooks.SessionStart = ((.hooks.SessionStart // []) + [$h])' "$SETTINGS" > "$tmp" \
        && cat "$tmp" > "$SETTINGS"; }; then
        warn "could not register the startup auto-update hook in $SETTINGS"
      fi
      rm -f "$tmp"
    else
      warn "$SETTINGS is not plain JSON; startup auto-update hook not registered. Add to hooks.SessionStart by hand: $hook"
    fi
  fi

  # --- no AI attribution -------------------------------------------------------------
  # Claude Code: no co-author trailers, PR footers or session links; git: a global commit-msg/pre-push
  # guard for every repository. See docs/ATTRIBUTION.md. MY_CLAUDE_SKILLS_ATTRIBUTION=keep skips this.
  if [ "${MY_CLAUDE_SKILLS_ATTRIBUTION:-}" != keep ]; then
    if jq -e . "$SETTINGS" >/dev/null 2>&1; then
      tmp=$(mktemp) && jq '.attribution = {commit: "", pr: "", sessionUrl: false}' "$SETTINGS" > "$tmp" \
        && cat "$tmp" > "$SETTINGS" && rm -f "$tmp"
      echo "==> AI attribution off in $SETTINGS"
    else
      warn "$SETTINGS is not plain JSON; add \"attribution\": {\"commit\": \"\", \"pr\": \"\", \"sessionUrl\": false} by hand"
    fi
    guard_dir="$HERE/tools/attribution-guard"
    if [ ! -f "$guard_dir/install.sh" ]; then
      guard_dir=$(mktemp -d)
      for f in attribution-guard.sh patterns.ere claude-pretooluse.sh dispatch install.sh; do
        curl -fsSL "https://raw.githubusercontent.com/$REPO/main/tools/attribution-guard/$f" -o "$guard_dir/$f" \
          || { warn "could not fetch tools/attribution-guard/$f; git attribution guard not installed"; guard_dir=""; break; }
      done
    fi
    if [ -n "$guard_dir" ]; then
      sh "$guard_dir/install.sh" || warn "git attribution guard not installed; run: sh tools/attribution-guard/install.sh"
    fi
  fi

  echo
  echo "Done. Restart Claude Code to load the plugins."
  [ "${#failed[@]}" -eq 0 ]
}

main "$@"
