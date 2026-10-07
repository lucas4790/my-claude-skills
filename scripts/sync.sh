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
# in copy order, once all of its copies are written (see README). Then every vendored plugin manifest
# that carries a version gets "<upstream version>+<7 hex of a hash of the plugin's files>", so an
# installed plugin refreshes exactly when its content changed. A path that a copy entry excludes is
# removed from the destination too, and a symlink in what a source copies, or on the way to it, fails
# that source.
# Every run also drops the lock entries of sources no longer in sources.json; those of sources that
# --only or --trust skip stay.
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
    --trust)  if [ "$#" -lt 2 ] || [ -z "$2" ]; then usage_error "error: --trust needs a value"; fi; trust_filter="$2"; shift 2 ;;
    --locked) locked=1; shift ;;
    --only)   if [ "$#" -lt 2 ] || [ -z "$2" ]; then usage_error "error: --only needs a value"; fi; only="$2"; shift 2 ;;
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

# printable TEXT: TEXT without control characters (a link's name and target come from upstream and end up
# in a log and a PR comment)
printable() { printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177'; }

# no_symlinks NAME FROM DIR: fails (an error line per link, at most 10) when DIR, where a directory copy
# of FROM just landed, holds a symlink. A link is never vendored: Claude Code puts one that resolves
# elsewhere in the marketplace into a plugin's cache as a regular file with that content, and an
# absolute or escaping one reads outside the plugin. `exclude` the path to drop it (see SECURITY.md).
# Python, not find: a name with a newline stays one entry, and a directory that cannot be read fails.
no_symlinks() {
  python3 - "$@" <<'PY'
import os, re, sys

name, src, dest = sys.argv[1:]


def unreadable(err):  # what a directory that cannot be listed holds is unknown
    sys.exit("error: %s: cannot scan %s for symlinks: %s" % (name, src, err))


def printable(s):  # a link's name and target come from upstream and end up in a log and a PR comment
    return re.sub(r"[\x00-\x1f\x7f-\x9f]", "", s)


links = []
for top, dirs, files in os.walk(dest, onerror=unreadable):
    links += [os.path.join(top, n) for n in dirs + files if os.path.islink(os.path.join(top, n))]
for link in sorted(links)[:10]:
    rel = printable(os.path.relpath(link, dest))
    print('error: %s: %s/%s is a symlink (-> %s); vendored content holds none: add "%s" to that copy entry\'s "exclude" (see SECURITY.md)'
          % (name, src.rstrip("/"), rel, printable(os.readlink(link)), rel), file=sys.stderr)
if len(links) > 10:
    print("error: %s: plus %d more symlinks under %s" % (name, len(links) - 10, src), file=sys.stderr)
sys.exit(1 if links else 0)
PY
}

# stamp_versions NAME TO...: rewrites "version" in the plugin manifests a source vendored (see README,
# "Stamped versions"). Python, for a hash that is the same on macOS and Linux; the hash covers the files
# git would commit under plugins/<plugin> (tracked or not, .gitignore applied), with the version of the
# manifests left out, so running it twice or on a --locked rebuild gives the same bytes.
stamp_versions() {
  local name="$1" others=()
  shift
  mapfile -t others < <(jq -r --arg n "$name" '.sources[] | select(.name != $n) | .copy[].to' "$SOURCES")
  python3 - "$ROOT" "$name" "$@" -- ${others[@]+"${others[@]}"} <<'PY'
import hashlib, json, os, re, subprocess, sys

root, name = sys.argv[1], sys.argv[2]
args = sys.argv[3:]
# normpath: "./plugins/x//y" and "plugins/x/y" are one path (what plugin_of and under compare)
tos = [os.path.normpath(t) for t in args[:args.index("--")]]
others = [os.path.normpath(t) for t in args[args.index("--") + 1:]]
MANIFESTS = (".claude-plugin/plugin.json", "plugin.json", ".codex-plugin/plugin.json")  # Claude Code, Copilot, Codex
TOKEN = re.compile(r'"(?:[^"\\]|\\.)*"|[\[\]{}]')  # a string, or a bracket outside one
VALUE = re.compile(r'\s*:\s*("(?:[^"\\]|\\.)*")')


def under(path, base):
    return path == base or path.startswith(base + "/")


def plugin_of(to):
    parts = to.split("/")
    return "/".join(parts[:2]) if parts[0] == "plugins" and len(parts) > 1 else None


def load(path):  # (text, object) of a manifest that is a JSON object, else None
    try:
        with open(os.path.join(root, path), "rb") as f:
            text = f.read().decode("utf-8")
        obj = json.loads(text)
    except (OSError, ValueError, RecursionError):  # RecursionError: nested too deep for the parser
        return None
    return (text, obj) if isinstance(obj, dict) else None


def shown(s):  # a version is upstream's text and the log is read by tools (workflow commands, the PR body): no control characters
    return re.sub(r"[\x00-\x1f\x7f-\x9f]", "", s).encode("utf-8", "backslashreplace").decode("utf-8")


def version_span(text):  # where the string value of the last literal "version" key of the top-level object sits, in one pass
    depth, span = 0, None
    for m in TOKEN.finditer(text):
        t = m.group()
        if t in ("{", "["):
            depth += 1
        elif t in ("}", "]"):
            depth -= 1
        elif depth == 1 and t == '"version"':
            v = VALUE.match(text, m.end())
            if v:
                span = v.span(1)
    return span


def content_hash(plugin):
    # only the .gitignore files in the tree count: .git/info/exclude and a global ignore file are this
    # clone's own, and CI, which commits what a run leaves, does not have them
    git = subprocess.run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-per-directory=.gitignore", "--", plugin],
                         cwd=root, stdout=subprocess.PIPE)
    if git.returncode != 0:
        sys.exit("error: %s: git ls-files failed under %s; cannot stamp its version" % (name, plugin))
    listed = git.stdout.split(b"\0")
    h = hashlib.sha256()
    for rel in sorted(set(f for f in listed if f)):
        path = os.path.join(os.fsencode(root), rel)
        inner = os.fsdecode(rel)[len(plugin) + 1:]
        if os.path.islink(path):
            kind, data = b"l", os.readlink(path)
        elif os.path.isfile(path):
            kind, data = (b"x" if os.stat(path).st_mode & 0o100 else b"f"), None
            loaded = load(os.fsdecode(rel)) if inner in MANIFESTS else None
            if loaded:  # the version is what gets stamped: leave it out
                data = json.dumps({k: v for k, v in loaded[1].items() if k != "version"},
                                  sort_keys=True, separators=(",", ":")).encode()
            else:
                with open(path, "rb") as f:
                    data = f.read()
        else:
            continue  # tracked, deleted by the sync
        h.update(os.fsencode(inner) + b"\0" + kind + b"\0" + str(len(data)).encode() + b"\0" + data)
    return h.hexdigest()[:7]


status, seen = 0, []
for to in tos:
    plugin = plugin_of(to)
    if plugin is None or plugin in seen:
        continue
    seen.append(plugin)
    found = []
    for m in MANIFESTS:
        path = plugin + "/" + m
        if not any(under(path, t) for t in tos) or os.path.islink(os.path.join(root, path)) \
                or not os.path.isfile(os.path.join(root, path)):
            continue  # not vendored by this source (repo-owned or absent): never rewritten
        loaded = load(path)
        if loaded is None:
            print("warning: %s: %s is not a JSON object; its version is not stamped" % (name, path), file=sys.stderr)
        elif isinstance(loaded[1].get("version"), str) and loaded[1]["version"]:
            found.append((path, loaded[0], loaded[1]))
    if not found:
        continue
    if any(under(o, plugin) for o in others):
        print("warning: %s: %s also receives files from another source; its version is not stamped" % (name, plugin),
              file=sys.stderr)
        continue
    tag = content_hash(plugin)
    for path, text, obj in found:
        old = obj["version"]
        new = old + ("." if "+" in old else "+") + tag
        span, out = version_span(text), None  # only the top-level key may change, and the parse proves it did
        if span:
            out = text[:span[0]] + json.dumps(new) + text[span[1]:]
            try:
                if json.loads(out) != dict(obj, version=new):
                    out = None
            except (ValueError, RecursionError):
                out = None
        if out is None:
            print("error: %s: cannot rewrite the version in %s" % (name, path), file=sys.stderr)
            status = 1
            continue
        with open(os.path.join(root, path), "wb") as f:
            f.write(out.encode("utf-8"))
        print("    version %s: %s -> %s" % (path, shown(old), shown(new)))
sys.exit(status)
PY
}

sync_source() {
  local i="$1" name repo ref trust clone sha n j from to src p lnk rel part parts=()
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
    # cp and rsync follow a link anywhere on the way to what they copy (see no_symlinks), not only at its
    # end: a trailing slash on from, or a link in the middle of it, hides it from a test of $src alone
    lnk="" rel=""
    IFS=/ read -r -a parts <<<"${from%/}"
    for part in ${parts[@]+"${parts[@]}"}; do
      [ -n "$part" ] || continue
      rel="${rel:+$rel/}$part"
      if [ -L "$clone/$rel" ]; then lnk="$rel"; break; fi
    done
    if [ -n "$lnk" ]; then
      echo "error: $name: $lnk is a symlink (-> $(printable "$(readlink "$clone/$lnk")")); vendored content holds none: point \"from\" at what it names (see SECURITY.md)" >&2
      return 1
    fi
    [ -e "$src" ] || { echo "error: $from not found in $name" >&2; return 1; }
    if [ -d "$src" ]; then
      local excludes=()
      # --delete-excluded also removes what an earlier sync vendored at a path the entry now excludes
      # (only those paths: rsync's other deletions are unchanged). Hence the guard on "to": a folder
      # like "" or ".." must never be the root of a --delete.
      below_root "${to%/}" || {
        echo "error: $name: cannot copy $from to \"$to\": a folder copy needs a clean path below the repo root (no empty, . or .. part)" >&2
        return 1
      }
      mapfile -t excludes < <(jq -r ".sources[$i].copy[$j].exclude // [] | .[] | \"--exclude=/\" + ." "$SOURCES")
      mkdir -p "$ROOT/$to" \
        && rsync -a --delete --delete-excluded --exclude '.git' "${excludes[@]}" "$src/" "$ROOT/$to/"
    else
      # A folder where upstream now has a file (upstream turned it into one) gives way to the file;
      # cp alone would put the file inside it. Only below the root: never for "", "a/", "a/./b" etc.
      { [ ! -d "$ROOT/$to" ] || { below_root "$to" && rm -rf "${ROOT:?}/$to"; }; } \
        && mkdir -p "$(dirname "$ROOT/$to")" && cp "$src" "$ROOT/$to"
    fi || { echo "error: $name: copying $from to $to failed" >&2; return 1; }
    if [ -d "$src" ]; then no_symlinks "$name" "$from" "$ROOT/${to%/}" || return 1; fi
    echo "    $from -> $to"
  done

  for p in "${patches[@]}"; do
    apply_patch "$p" "${tos[@]}" \
      || { echo "error: $p no longer applies to $name@${sha:0:7}; refresh it (see README)" >&2; return 1; }
  done

  stamp_versions "$name" "${tos[@]}" || return 1

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
