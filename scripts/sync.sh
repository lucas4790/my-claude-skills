#!/usr/bin/env bash
# Vendors the paths listed in sources.json from their upstream repos and records
# the synced commit of each source in UPSTREAM.lock.json, then regenerates SKILLS.md.
#
#   sync.sh                 sync every source at its configured ref
#   sync.sh --trust low     only sources whose "trust" matches (high|low)
#   sync.sh --locked        check out the exact SHAs from UPSTREAM.lock.json (reproducible rebuild)
#   sync.sh --only NAME     one source by name
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="$ROOT/sources.json"
LOCK="$ROOT/UPSTREAM.lock.json"
TMP="$ROOT/.sync-tmp"

trust_filter="" locked=0 only=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --trust)  trust_filter="$2"; shift 2 ;;
    --locked) locked=1; shift ;;
    --only)   only="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

for tool in git rsync jq python3; do
  command -v "$tool" >/dev/null || { echo "error: $tool required" >&2; exit 1; }
done

cd "$ROOT" || exit 1
rm -rf "$TMP"; mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

lock=$( [ -f "$LOCK" ] && cat "$LOCK" || echo '{}' )
failed=()

sync_source() {
  local i="$1" name repo ref trust clone sha n j from to src
  name=$(jq -r ".sources[$i].name" "$SOURCES")
  repo=$(jq -r ".sources[$i].repo" "$SOURCES")
  ref=$(jq -r ".sources[$i].ref // \"main\"" "$SOURCES")
  trust=$(jq -r ".sources[$i].trust // \"low\"" "$SOURCES")
  clone="$TMP/$name"

  [ -z "$trust_filter" ] || [ "$trust" = "$trust_filter" ] || return 0
  [ -z "$only" ] || [ "$name" = "$only" ] || return 0

  local froms=()
  mapfile -t froms < <(jq -r ".sources[$i].copy[].from | \"/\" + ." "$SOURCES")
  [ "${#froms[@]}" -gt 0 ] || { echo "error: $name has no copy entries" >&2; return 1; }

  if [ "$locked" = 1 ]; then
    sha=$(jq -r --arg n "$name" '.[$n].sha // empty' <<<"$lock")
    [ -n "$sha" ] || { echo "error: $name missing from lockfile" >&2; return 1; }
    echo "==> $name ($repo @ ${sha:0:7}, locked)"
    git init -q "$clone" && git -C "$clone" remote add origin "$repo" \
      && git -C "$clone" fetch -q --depth 1 --filter=blob:none origin "$sha" \
      && git -C "$clone" sparse-checkout set --no-cone "${froms[@]}" \
      && git -C "$clone" checkout -q FETCH_HEAD || return 1
  else
    echo "==> $name ($repo @ $ref, $trust trust)"
    git clone --quiet --depth 1 --filter=blob:none --sparse --branch "$ref" "$repo" "$clone" || return 1
    git -C "$clone" sparse-checkout set --no-cone "${froms[@]}" || return 1
    sha=$(git -C "$clone" rev-parse HEAD)
  fi

  n=$(jq ".sources[$i].copy | length" "$SOURCES")
  for j in $(seq 0 $((n - 1))); do
    from=$(jq -r ".sources[$i].copy[$j].from" "$SOURCES")
    to=$(jq -r ".sources[$i].copy[$j].to" "$SOURCES")
    src="$clone/$from"
    [ -e "$src" ] || { echo "error: $from not found in $name" >&2; return 1; }
    if [ -d "$src" ]; then
      mkdir -p "$ROOT/$to"
      rsync -a --delete --exclude '.git' "$src/" "$ROOT/$to/"
    else
      mkdir -p "$(dirname "$ROOT/$to")"
      cp "$src" "$ROOT/$to"
    fi
    echo "    $from -> $to"
  done

  lock=$(jq --arg n "$name" --arg r "$repo" --arg ref "$ref" --arg s "$sha" --arg t "$trust" \
    '.[$n] = {repo: $r, ref: $ref, sha: $s, trust: $t}' <<<"$lock")
}

count=$(jq '.sources | length' "$SOURCES")
for i in $(seq 0 $((count - 1))); do
  sync_source "$i" || failed+=("$(jq -r ".sources[$i].name" "$SOURCES")")
done

jq -S . <<<"$lock" > "$LOCK"
echo "==> wrote $(basename "$LOCK")"
python3 "$ROOT/scripts/gen-catalog.py"

if [ "${#failed[@]}" -gt 0 ]; then
  echo "==> FAILED sources: ${failed[*]}" >&2
  exit 1
fi
