#!/usr/bin/env bash
# Updates the pinned "sha" of every url/github-sourced plugin in marketplace.json to the
# current tip of its ref. Run by the low-trust sync job; result lands in a PR for review.
#
# Each bump is followed by what it pulls in, indented under its "==>" line: a compare link and, from a
# blobless clone of the upstream repo (commits and trees, no file contents but the two manifests), the number
# of commits and files, the manifest version, whether the manifest's hooks changed and the changed hook files.
# That part is information for the reviewer: a clone that fails is a warning, never an error, and the bump is
# kept.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MP="$ROOT/.claude-plugin/marketplace.json"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bump-pinned.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# `timeout` is not on stock macOS; without it the command simply runs unbounded.
limited() { if command -v timeout >/dev/null 2>&1; then timeout 180 "$@"; else "$@"; fi; }

# Text that comes from the upstream repository (versions, file names) reaches the PR body: keep printable
# ASCII without backticks (newlines separate lines), at most $1 characters per line.
safe() { LC_ALL=C tr -cd '\n\040-\137\141-\176' | cut -c1-"$1"; }

# manifest_version CLONE SHA: the "version" of .claude-plugin/plugin.json (or plugin.json) at SHA, if any
manifest_version() {
  local f v
  for f in .claude-plugin/plugin.json plugin.json; do
    v=$(limited git -C "$1" show "$2:$f" 2>/dev/null | head -c 1000000 \
      | jq -r 'if (.version | type) == "string" then .version else empty end' 2>/dev/null | head -n 1 \
      | LC_ALL=C tr -cd 'A-Za-z0-9._+-' | cut -c1-40) || v=""
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done
}

# manifest_hooks CLONE SHA OUT: the "hooks" key of the plugin manifest at SHA as sorted compact JSON in the file OUT
# (empty: no hooks), so that two commits compare with cmp. A plugin registers its hooks here, inline or by path.
manifest_hooks() {
  local f
  : > "$3"
  for f in .claude-plugin/plugin.json plugin.json; do
    limited git -C "$1" show "$2:$f" 2>/dev/null | head -c 1000000 | jq -S -c '.hooks // empty' > "$3" 2>/dev/null || : > "$3"
    [ ! -s "$3" ] || return 0
  done
}

# hook_events OLD NEW: the events (keys of the hooks object) whose registration differs between two manifest_hooks files
hook_events() {
  jq -rn --slurpfile a "$1" --slurpfile b "$2" '
    ($a[0] | if type == "object" then . else {} end) as $x | ($b[0] | if type == "object" then . else {} end) as $y
    | [$x, $y] | map(keys[]) | unique | map(select($x[.] != $y[.])) | .[]' 2>/dev/null \
    | safe 40 | head -n 10 | paste -sd, - | sed 's/,/, /g'
}

# named_paths FILE...: the files that a manifest_hooks value names (a path, or a list of paths), "./" dropped
named_paths() {
  jq -r 'if type == "string" then . elif type == "array" then .[] | strings else empty end' "$@" 2>/dev/null | sed 's|^\./||'
}

# paths that are docs or tests rather than code that runs: listed after the hook scripts
WEAK_HOOK_PATH='(^|/)(docs?|tests?|__tests__|specs?|examples?|fixtures?)/|\.(md|mdx|markdown|txt|rst)$|\.(test|spec)\.[a-z0-9]+$|_test\.[a-z0-9]+$'

# plural N WORD: "1 file", "2 files"
plural() { if [ "$1" = 1 ]; then echo "$1 $2"; else echo "$1 $2s"; fi; }

# summarize INDEX NAME URL OLD NEW: the lines under a bump's "==>" line. Never fails.
summarize() {
  local i=$1 name=$2 url=$3 old=$4 new=$5 slug="" c commits behind changes na nm nd v0 v1 ev hp hooks nh
  case $url in https://github.com/*) slug=${url#https://github.com/}; slug=${slug%.git}; slug=${slug%/} ;; esac
  [[ $slug =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || slug=""
  if [ -z "$old" ]; then echo "    no previous pin to compare with"; return 0; fi
  if ! [[ $old =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then echo "    the old pin is not a full commit sha: no counts"; return 0; fi
  [ -z "$slug" ] || echo "    compare: https://github.com/$slug/compare/$old...$new"
  c="$WORK/clone-$i"
  if ! GIT_TERMINAL_PROMPT=0 limited git clone -q --filter=blob:none --no-checkout -- "$url" "$c" >/dev/null 2>&1; then
    echo "warning: could not clone $url to summarize the bump of $name" >&2
    return 0
  fi
  if ! git -C "$c" cat-file -e "$old^{commit}" 2>/dev/null || ! git -C "$c" cat-file -e "$new^{commit}" 2>/dev/null; then
    echo "    the old pin is not in the upstream history any more (rewritten?): no counts"
    return 0
  fi
  commits=$(git -C "$c" rev-list --count "$old..$new" 2>/dev/null) || commits=""
  behind=$(git -C "$c" rev-list --count "$new..$old" 2>/dev/null) || behind=0
  # -z: odd file names are not C-quoted; "status NUL path NUL ..." becomes alternating lines. A newline inside a
  # name becomes "?" first (in the same tr, so the NULs it makes stay), or it would shift every later line.
  changes=$(git -C "$c" diff --name-status --no-renames -z "$old" "$new" 2>/dev/null | tr '\n\0' '?\n') || changes=""
  na=$(awk 'NR % 2 == 1 && /^A/' <<<"$changes" | grep -c . || true)
  nm=$(awk 'NR % 2 == 1 && /^[MT]/' <<<"$changes" | grep -c . || true)
  nd=$(awk 'NR % 2 == 1 && /^D/' <<<"$changes" | grep -c . || true)
  if [ -n "$commits" ]; then
    echo "    $(plural "$commits" commit), $(plural $((na + nm + nd)) file) changed ($na added, $nm modified, $nd removed)"
  fi
  [ "$behind" = 0 ] || echo "    note: $(plural "$behind" commit) in the old pin, not in the new history (force-push or rewind)"
  v0=$(manifest_version "$c" "$old"); v1=$(manifest_version "$c" "$new")
  if [ "$v0" != "$v1" ]; then echo "    manifest version: ${v0:-none} -> ${v1:-none}"
  elif [ -n "$v1" ]; then echo "    manifest version: $v1 (unchanged)"; fi
  # Hooks run on every prompt or session: say whether the manifest's registration changed, and list the changed
  # files that are hooks (their path says "hook", or the manifest names them), scripts before docs and tests.
  manifest_hooks "$c" "$old" "$WORK/hooks-old"; manifest_hooks "$c" "$new" "$WORK/hooks-new"
  if ! cmp -s "$WORK/hooks-old" "$WORK/hooks-new"; then
    ev=$(hook_events "$WORK/hooks-old" "$WORK/hooks-new") || ev=""
    echo "    manifest hooks: changed${ev:+ (events: $ev)}"
  elif [ -s "$WORK/hooks-new" ]; then echo "    manifest hooks: unchanged"; fi
  named_paths "$WORK/hooks-old" "$WORK/hooks-new" > "$WORK/hooks-named" || : > "$WORK/hooks-named"
  hp=$(awk 'NR % 2 == 0' <<<"$changes")
  hp=$({ grep -i hook <<<"$hp" || true; [ ! -s "$WORK/hooks-named" ] || grep -Fx -f "$WORK/hooks-named" <<<"$hp" || true; } | awk '!seen[$0]++')
  hooks=$({ grep -Eiv "$WEAK_HOOK_PATH" <<<"$hp" || true; grep -Ei "$WEAK_HOOK_PATH" <<<"$hp" || true; } | grep . | safe 80 || true)
  nh=$(grep -c . <<<"$hooks" || true)
  if [ "$nh" -gt 0 ]; then
    echo "    hook files changed ($nh): $(head -n 10 <<<"$hooks" | paste -sd, - | sed 's/,/, /g')$([ "$nh" -le 10 ] || echo ", and $((nh - 10)) more")"
  fi
  rm -rf "$c"
}

n=$(jq '.plugins | length' "$MP")
for i in $(seq 0 $((n - 1))); do
  type=$(jq -r ".plugins[$i].source | if type==\"object\" then .source else \"path\" end" "$MP")
  [ "$type" = url ] || [ "$type" = github ] || continue
  name=$(jq -r ".plugins[$i].name" "$MP")
  ref=$(jq -r ".plugins[$i].source.ref // \"HEAD\"" "$MP")
  old=$(jq -r ".plugins[$i].source.sha // \"\"" "$MP")
  if [ "$type" = url ]; then
    url=$(jq -r ".plugins[$i].source.url" "$MP")
  else
    url="https://github.com/$(jq -r ".plugins[$i].source.repo" "$MP").git"
  fi
  # Exact ref only (a pattern like "main" also matches refs/heads/<x>/main), a tag peeled to its
  # commit, and an unreachable repo is a warning like an unknown ref, not the end of the run.
  # (ref may be short, "v1", or fully qualified, "refs/tags/v1"; a branch wins over a tag of the same name)
  new=$(git ls-remote "$url" "$ref" "$ref^{}" | awk -v r="$ref" '
    $2 == "refs/heads/" r || ($2 == r && r !~ /^refs\/tags\//) { if (head == "") head = $1 }
    $2 == "refs/tags/" r || $2 == r { tag = $1 }
    $2 == "refs/tags/" r "^{}" || $2 == r "^{}" { peeled = $1 }
    END { print (head != "" ? head : (peeled != "" ? peeled : tag)) }') || new=""
  [ -n "$new" ] || { echo "warning: could not resolve $ref for $name" >&2; continue; }
  if [ "$new" != "$old" ]; then
    echo "==> $name: ${old:0:7} -> ${new:0:7}"
    tmp=$(mktemp); jq --argjson i "$i" --arg s "$new" '.plugins[$i].source.sha = $s' "$MP" > "$tmp" && mv "$tmp" "$MP"
    summarize "$i" "$name" "$url" "$old" "$new" || true
  else
    echo "==> $name: ${old:0:7} unchanged"
  fi
done
