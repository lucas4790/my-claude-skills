#!/usr/bin/env bash
# Updates the pinned "sha" of every url/github-sourced plugin in marketplace.json to the
# current tip of its ref. Run by the low-trust sync job; result lands in a PR for review.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MP="$ROOT/.claude-plugin/marketplace.json"

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
  else
    echo "==> $name: ${old:0:7} unchanged"
  fi
done
