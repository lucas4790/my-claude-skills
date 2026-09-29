#!/usr/bin/env bash
# Vendors the paths listed in sources.json from their upstream repos and records
# the synced commit of each source in UPSTREAM.lock.json, then regenerates SKILLS.md.
#
#   sync.sh                 sync every source at its configured ref
#   sync.sh --trust low     only sources whose "trust" matches (high|low)
#   sync.sh --locked        check out the exact SHAs from UPSTREAM.lock.json (reproducible rebuild)
#   sync.sh --only NAME     one source by name
#
# A copy entry may name a "patch" (a repo-relative unified diff); a source's patches are applied,
# in copy order, once all of its copies are written (see README). Every run also drops the lock
# entries of sources no longer in sources.json; those of sources that --only or --trust skip stay.
# Exit status: 0 all selected sources synced, 1 a source failed (its paths and lock entry stay as
# committed; the others are still synced) or a required tool is missing, 2 usage error (unknown
# option, a missing or empty --only/--trust value, a --trust other than high or low, or no source
# matches --only).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="$ROOT/sources.json"
LOCK="$ROOT/UPSTREAM.lock.json"
TMP="$ROOT/.sync-tmp"

usage_error() { echo "$*" >&2; exit 2; }

trust_filter="" locked=0 only=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --trust)  [ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "error: --trust needs a value"; trust_filter="$2"; shift 2 ;;
    --locked) locked=1; shift ;;
    --only)   [ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "error: --only needs a value"; only="$2"; shift 2 ;;
    *) usage_error "unknown option: $1" ;;
  esac
done
case "$trust_filter" in
  "" | high | low) ;;
  *) usage_error "error: --trust must be high or low, not: $trust_filter" ;;
esac

for tool in git rsync jq python3; do
  command -v "$tool" >/dev/null || { echo "error: $tool required" >&2; exit 1; }
done

# A misspelled --only name would otherwise sync nothing and exit 0.
if [ -n "$only" ] && [ "$(jq --arg n "$only" --arg t "$trust_filter" \
    '[.sources[] | select(.name == $n and ($t == "" or (.trust // "low") == $t))] | length' "$SOURCES")" = 0 ]; then
  usage_error "error: no source in sources.json matches --only $only${trust_filter:+ --trust $trust_filter}"
fi

cd "$ROOT" || exit 1
rm -rf "$TMP"; mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

lock=$( [ -f "$LOCK" ] && cat "$LOCK" || echo '{}' )
failed=()

# Applies a patch to the files a source just wrote: plain `git apply`, else a 3-way merge. The merge
# needs the patch's base blob in the local object store and runs in a scratch index seeded from the
# worktree (the real index holds the last committed, already patched file, so `--3way` there always
# stops at "does not match index"). It runs with --cached, so a conflict never reaches the worktree:
# the files are rewritten from that index, and the ones the patch deletes removed, only once it is clean.
apply_patch() {
  local patch="$1"; shift  # the rest: the source's `to` paths
  git apply --whitespace=nowarn "$patch" 2>/dev/null && { echo "    patch $patch"; return 0; }
  local -x GIT_INDEX_FILE="$TMP/patch.index"  # exported to the git commands below only
  rm -f "$GIT_INDEX_FILE"
  git add -A -- "$@" \
    && git apply --cached --3way --whitespace=nowarn "$patch" \
    && [ -z "$(git ls-files --unmerged)" ] \
    && git checkout-index -f -a && git clean -fq -- "$@" \
    && echo "    patch $patch (3-way merge)"
}

# below_root PATH: PATH (a copy's "to") names something below the repo root: no empty, . or .. part
below_root() { case "/$1/" in *//* | */./* | */../*) return 1 ;; esac; }

sync_source() {
  local i="$1" name repo ref trust clone sha n j from to src p
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

  local patches=() tos=()
  mapfile -t patches < <(jq -r ".sources[$i].copy[].patch // empty" "$SOURCES" | awk '!seen[$0]++')
  mapfile -t tos < <(jq -r ".sources[$i].copy[].to" "$SOURCES")
  for p in "${patches[@]}"; do
    [ -f "$ROOT/$p" ] || { echo "error: $name: patch file $p not found" >&2; return 1; }
  done

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
      local excludes=()
      mapfile -t excludes < <(jq -r ".sources[$i].copy[$j].exclude // [] | .[] | \"--exclude=/\" + ." "$SOURCES")
      mkdir -p "$ROOT/$to" && rsync -a --delete --exclude '.git' "${excludes[@]}" "$src/" "$ROOT/$to/"
    else
      # A folder where upstream now has a file (upstream turned it into one) gives way to the file;
      # cp alone would put the file inside it. Only below the root: never for "", "a/", "a/./b" etc.
      { [ ! -d "$ROOT/$to" ] || { below_root "$to" && rm -rf "${ROOT:?}/$to"; }; } \
        && mkdir -p "$(dirname "$ROOT/$to")" && cp "$src" "$ROOT/$to"
    fi || { echo "error: $name: copying $from to $to failed" >&2; return 1; }
    echo "    $from -> $to"
  done

  for p in "${patches[@]}"; do
    apply_patch "$p" "${tos[@]}" \
      || { echo "error: $p no longer applies to $name@${sha:0:7}; refresh it (see README)" >&2; return 1; }
  done

  lock=$(jq --arg n "$name" --arg r "$repo" --arg ref "$ref" --arg s "$sha" --arg t "$trust" \
    '.[$n] = {repo: $r, ref: $ref, sha: $s, trust: $t}' <<<"$lock")
}

# Puts a failed source's paths back to the last commit (its lock entry is not updated either), so a
# half-copied or unpatched upstream never reaches the sync PR, e.g. one that drops a local fix.
restore_paths() {
  local to
  for to in "$@"; do
    if git cat-file -e "HEAD:$to" 2>/dev/null; then git checkout -q HEAD -- "$to"; fi
    git clean -fdq -- "$to"
  done
}

count=$(jq '.sources | length' "$SOURCES")
for i in $(seq 0 $((count - 1))); do
  sync_source "$i" && continue
  failed+=("$(jq -r ".sources[$i].name" "$SOURCES")")
  mapfile -t tos < <(jq -r ".sources[$i].copy[].to" "$SOURCES")
  restore_paths "${tos[@]}"
done

# Drops the lock entries of sources no longer in sources.json, whatever the filter: --only and --trust
# choose which sources sync, not which entries are valid (CI syncs per --trust tier only).
names=$(jq -c '[.sources[].name]' "$SOURCES")
jq -r --argjson names "$names" 'keys - $names | .[] | "==> dropped \(.) from the lockfile (not in sources.json)"' <<<"$lock"
lock=$(jq --argjson names "$names" 'del(.[keys - $names | .[]])' <<<"$lock")

jq -S . <<<"$lock" > "$LOCK"
echo "==> wrote $(basename "$LOCK")"
python3 "$ROOT/scripts/gen-catalog.py"

if [ "${#failed[@]}" -gt 0 ]; then
  echo "==> FAILED sources: ${failed[*]}" >&2
  exit 1
fi
