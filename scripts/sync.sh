#!/usr/bin/env bash
# Vendors the paths listed in sources.json from their upstream repos and
# records the synced commit of each source in UPSTREAM.lock.json.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="$ROOT/sources.json"
LOCK="$ROOT/UPSTREAM.lock.json"
TMP="$ROOT/.sync-tmp"

cd "$ROOT"
rm -rf "$TMP"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

lock='{}'

for i in $(jq -r '.sources | keys[]' "$SOURCES"); do
  name=$(jq -r ".sources[$i].name" "$SOURCES")
  repo=$(jq -r ".sources[$i].repo" "$SOURCES")
  ref=$(jq -r ".sources[$i].ref // \"main\"" "$SOURCES")
  clone="$TMP/$name"

  echo "==> $name ($repo @ $ref)"
  git clone --quiet --depth 1 --filter=blob:none --sparse --branch "$ref" "$repo" "$clone"

  mapfile -t froms < <(jq -r ".sources[$i].copy[].from | \"/\" + .)" "$SOURCES")
  git -C "$clone" sparse-checkout set --no-cone "${froms[@]}"
  sha=$(git -C "$clone" rev-parse HEAD)

  n=$(jq ".sources[$i].copy | length" "$SOURCES")
  for j in $(seq 0 $((n - 1))); do
    from=$(jq -r ".sources[$i].copy[$j].from" "$SOURCES")
    to=$(jq -r ".sources[$i].copy[$j].to" "$SOURCES")
    src="$clone/$from"
    [ -e "$src" ] || { echo "error: $from not found in $name" >&2; exit 1; }

    if [ -d "$src" ]; then
      mkdir -p "$ROOT/$to"
      rsync -a --delete --exclude '.git' "$src/" "$ROOT/$to/"
    else
      mkdir -p "$(dirname "$ROOT/$to")"
      cp "$src" "$ROOT/$to"
    fi
    echo "    $from -> $to"
  done

  lock=$(jq --arg n "$name" --arg r "$repo" --arg ref "$ref" --arg s "$sha" \
    '.[$n] = {repo: $r, ref: $ref, sha: $s}' <<<"$lock")
done

jq -S . <<<"$lock" > "$LOCK"
echo "==> wrote $(basename "$LOCK")"
