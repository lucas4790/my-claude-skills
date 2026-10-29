#!/bin/bash
# Cloud environment setup script for lucas4790/my-claude-skills (claude.ai/code, Anthropic-hosted, Ubuntu 24.04).
#
# Turns off AI attribution in ~/.claude/settings.json (every session of the environment, any repository) and
# installs the tools AGENTS.md "Checks before a PR" needs that the base image lacks:
#   rsync, bats (>= 1.4), shellcheck, yamllint (>= 1.30), pytest + PyYAML for the python3 on PATH,
#   git-filter-repo, pwsh, Pester (>= 6) and PSScriptAnalyzer (CurrentUser module path of root).
#
# - Idempotent: every step checks first and skips what is already there.
# - Quiet: one line per step; full output goes to $LOG.
# - Fails soft: always exits 0 (a non-zero exit stops the session from starting); a failed step prints
#   "FAILED" and the repo's checks that need that tool skip themselves (or fail under SKILL_EXAMPLES_REQUIRE_TOOLS).
# - Fast: apt (one transaction) runs in parallel with pip; modules come as plain .nupkg downloads, no
#   PowerShellGet round trips. Stays well under the ~5 min environment-cache limit.
# - Self-contained: needs nothing from the clone, no secrets and no environment variables (the environment's
#   variables are not set yet when the setup script runs).
# - Network: Trusted access covers Ubuntu, packages.microsoft.com, PyPI, nuget.org and GitHub release assets.
#   The PowerShell Gallery is not on the Trusted list: it is tried first and the script falls back to
#   nuget.org (Pester) and a pinned GitHub release asset (PSScriptAnalyzer).
set -u
export DEBIAN_FRONTEND=noninteractive
LOG=/var/log/cloud-setup.log
{ : >"$LOG"; } 2>/dev/null || LOG=/tmp/cloud-setup.log
# pwsh's CurrentUser module path (the session runs as root too). Not AllUsers: a pytest case hides Pester 6 by
# overriding HOME/XDG_DATA_HOME and skips itself when Pester is installed for all users.
PS_MODULES=${XDG_DATA_HOME:-${HOME:-/root}/.local/share}/powershell/Modules
PSSA_PINNED=1.24.0                             # GitHub-release fallback for PSScriptAnalyzer
T=$(mktemp -d) || exit 0
trap 'rm -rf "$T"' EXIT

say() { printf 'cloud-setup: %s\n' "$*"; }
run() { "$@" >>"$LOG" 2>&1; } # quiet; output kept in $LOG
have() { command -v "$1" >/dev/null 2>&1; }
dl() { [ -n "$1" ] && curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 -o "$2" "$1" >>"$LOG" 2>&1; }

# --- apt: rsync bats shellcheck yamllint unzip powershell (one update, one install) --------------------------
apt_step() {
  local pkgs=()
  have rsync || pkgs+=(rsync)
  have bats || pkgs+=(bats)             # Ubuntu 24.04: 1.10
  have shellcheck || pkgs+=(shellcheck) # 0.9
  have yamllint || pkgs+=(yamllint)     # 1.33 (the yaml-hooks hook needs >= 1.30)
  have unzip || pkgs+=(unzip)
  if ! have pwsh; then
    if [ ! -f /etc/apt/sources.list.d/microsoft-prod.list ] &&
      dl https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb "$T/ms.deb"; then
      run dpkg -i "$T/ms.deb"
    fi
    pkgs+=(powershell)
  fi
  [ "${#pkgs[@]}" -gt 0 ] || { say "apt: nothing to install"; return 0; }
  run apt-get update -qq
  if run apt-get install -y -qq --no-install-recommends "${pkgs[@]}"; then
    say "apt: installed ${pkgs[*]}"
  else # one by one, so one bad package does not take the others down
    local p ok=() bad=()
    for p in "${pkgs[@]}"; do
      if run apt-get install -y -qq --no-install-recommends "$p"; then ok+=("$p"); else bad+=("$p"); fi
    done
    say "apt: installed ${ok[*]:-nothing}; FAILED ${bad[*]} (see $LOG)"
  fi
}

# --- pip: pytest + PyYAML for the python3 on PATH, git-filter-repo ------------------------------------------
pip_step() {
  local mods=()
  python3 -c 'import pytest' 2>/dev/null || mods+=(pytest)
  python3 -c 'import yaml' 2>/dev/null || mods+=(pyyaml)
  git filter-repo --version >/dev/null 2>&1 || mods+=(git-filter-repo)
  [ "${#mods[@]}" -gt 0 ] || { say "pip: nothing to install"; return 0; }
  # --break-system-packages only matters for a PEP 668 (Debian-managed) python; the VM is throwaway
  if run python3 -m pip install -q --disable-pip-version-check --root-user-action=ignore "${mods[@]}" ||
    run python3 -m pip install -q --disable-pip-version-check --root-user-action=ignore \
      --break-system-packages "${mods[@]}"; then
    say "pip: installed ${mods[*]}"
  else
    say "pip: FAILED ${mods[*]} (see $LOG)"
  fi
}

# --- PowerShell modules: unpack a .nupkg into $PS_MODULES/<Name>/<Version> ----------------------------------
ps_has() { # name minimum-version
  pwsh -NoLogo -NoProfile -NonInteractive -Command \
    "if (Get-Module -ListAvailable -Name $1 | Where-Object Version -GE ([version] '$2')) { exit 0 } else { exit 1 }" \
    >/dev/null 2>&1
}
nupkg_install() { # name file; PSGallery packages hold the module at the root, nuget.org's Pester under tools/
  local name=$1 pkg=$2 x="$T/x-$1" src ver
  rm -rf "$x" && mkdir -p "$x" && run unzip -q -o "$pkg" -d "$x" || return 1
  ver=$(sed -n 's:.*<version>\([^<]*\)</version>.*:\1:p' "$x"/*.nuspec | head -1)
  ver=${ver%%-*} # the module folder is the numeric version, without a prerelease tag
  [ -n "$ver" ] || return 1
  if [ -f "$x/$name.psd1" ]; then src=$x; elif [ -f "$x/tools/$name.psd1" ]; then src=$x/tools; else return 1; fi
  rm -rf "$x/_rels" "$x/package" "$x/[Content_Types].xml" "$x"/*.nuspec "$x/.signature.p7s"
  mkdir -p "$PS_MODULES/$name" && rm -rf "${PS_MODULES:?}/$name/$ver" && mv "$src" "$PS_MODULES/$name/$ver"
}
nuget_url() { # id minimum-major: newest stable version on nuget.org with at least that major
  curl -fsSL --max-time 30 "https://api.nuget.org/v3-flatcontainer/$1/index.json" 2>>"$LOG" |
    python3 -I -c 'import json, sys
v = [x for x in json.load(sys.stdin)["versions"] if "-" not in x and int(x.split(".")[0]) >= int(sys.argv[2])]
print(f"https://api.nuget.org/v3-flatcontainer/{sys.argv[1]}/{v[-1]}/{sys.argv[1]}.{v[-1]}.nupkg" if v else "")' \
      "$1" "$2" 2>>"$LOG"
}
module_step() { # name minimum-version url...
  local name=$1 min=$2 url host
  shift 2
  ps_has "$name" "$min" && { say "$name: already >= $min"; return 0; }
  for url in "$@"; do
    if dl "$url" "$T/$name.nupkg" && nupkg_install "$name" "$T/$name.nupkg" && ps_has "$name" "$min"; then
      host=${url#https://}
      say "$name: installed from ${host%%/*}"
      return 0
    fi
  done
  say "$name: FAILED (no source reachable? see $LOG)"
}

# --- Claude Code user settings: no AI attribution in any repository of this environment --------------------
# The repo's .claude/settings.json covers only this repository; ~/.claude/settings.json covers every cloud
# session started in the environment. Merged into an existing file; a file that is not a JSON object is left alone.
settings_step() {
  local f=${CLAUDE_CONFIG_DIR:-${HOME:-/root}/.claude}/settings.json
  mkdir -p "$(dirname "$f")" 2>/dev/null
  if python3 -I - "$f" >>"$LOG" 2>&1 <<'PY'; then
import json, os, sys
path = sys.argv[1]
data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        sys.exit("not a JSON object")
data["attribution"] = {"commit": "", "pr": "", "sessionUrl": False}
data["includeCoAuthoredBy"] = False  # the older setting, for older Claude Code versions
with open(path, "w", encoding="utf-8") as fh:  # write in place: keeps a symlinked settings.json
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
    say "settings: AI attribution off in $f"
  else
    say "settings: FAILED to update $f (see $LOG)"
  fi
}

start=$SECONDS
say "log: $LOG"
settings_step
apt_step >"$T/apt.out" 2>&1 &
pip_step >"$T/pip.out" 2>&1 &
wait
cat "$T/apt.out" "$T/pip.out"
if have pwsh; then
  module_step Pester 6.0.0 https://www.powershellgallery.com/api/v2/package/Pester \
    "$(nuget_url pester 6)" >"$T/pester.out" 2>&1 &
  module_step PSScriptAnalyzer 1.21.0 https://www.powershellgallery.com/api/v2/package/PSScriptAnalyzer \
    "https://github.com/PowerShell/PSScriptAnalyzer/releases/download/$PSSA_PINNED/PSScriptAnalyzer.$PSSA_PINNED.nupkg" \
    >"$T/pssa.out" 2>&1 &
  wait
  cat "$T/pester.out" "$T/pssa.out"
else
  say "pwsh: FAILED, so Pester and PSScriptAnalyzer were skipped"
fi

# one-line inventory of what the checks will find
ver() { "$@" 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1; }
say "done in $((SECONDS - start))s: rsync=$(ver rsync --version) bats=$(ver bats --version)" \
  "shellcheck=$(ver shellcheck --version) yamllint=$(ver yamllint --version)" \
  "pytest=$(ver python3 -m pytest --version) pwsh=$(ver pwsh --version)"
exit 0
