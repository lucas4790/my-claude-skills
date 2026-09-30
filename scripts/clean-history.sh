#!/usr/bin/env bash
# Rewrites a bare clone of this repository so that no commit message carries AI attribution
# (tools/attribution-guard/patterns.ere) and no author or committer is the vendor identity, then
# verifies the result. It never pushes: it prints the push commands. The whole procedure (freeze,
# branch protection, push, clones on other machines, GitHub Support) is in docs/HISTORY-CLEANUP.md.
#
#   clean-history.sh --owner 'Name <email>' [options] BARE_REPO
#
#   --owner 'Name <email>'  identity that replaces the vendor author/committer (required)
#   --mailmap FILE          extra git-mailmap lines, e.g. old personal addresses -> your noreply address
#   --drop-coauthor EMAIL   drop "Co-authored-by: ... <EMAIL>" lines (yourself under another address)
#   --replace-text FILE     git filter-repo --replace-text rules for file contents ("old==>new" per line)
#   --forbid TEXT           text that must not remain anywhere: messages, identities, file contents
#   --report-dir DIR        where the reports go (default: <BARE_REPO>.clean-history next to it)
#
# BARE_REPO must be a fresh `git clone --bare` (git filter-repo refuses anything else). Needs git,
# git-filter-repo and python3. Exit status: 0 rewritten and verified, 1 verification failed or the
# rewrite stopped (e.g. attribution in a subject line, which must be reworded by hand), 2 usage.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
guard="$here/tools/attribution-guard/attribution-guard.sh"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
die() { echo "clean-history: $*" >&2; exit 1; }
bad() { echo "clean-history: $*" >&2; usage >&2; exit 2; }

owner='' mailmap='' replace='' report=''
drop=() forbid=()
while [ "$#" -gt 0 ]; do
  case $1 in
    --owner) owner=${2:?}; shift 2 ;;
    --mailmap) mailmap=${2:?}; shift 2 ;;
    --drop-coauthor) drop+=("${2:?}"); shift 2 ;;
    --replace-text) replace=${2:?}; shift 2 ;;
    --forbid) forbid+=("${2:?}"); shift 2 ;;
    --report-dir) report=${2:?}; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    -*) bad "unknown option: $1" ;;
    *) break ;;
  esac
done
[ "$#" -eq 1 ] || bad "give exactly one BARE_REPO"
repo=$(cd "$1" 2>/dev/null && pwd) || bad "no such directory: $1"
case $owner in *' <'*'>') ;; *) bad "--owner must look like 'Name <email>'" ;; esac
owner_name=${owner% <*} owner_email=${owner##*<}; owner_email=${owner_email%>}
case $owner_email in *@anthropic.com) bad "--owner is the vendor identity" ;; esac
[ -z "$mailmap" ] || [ -f "$mailmap" ] || bad "no such mailmap file: $mailmap"
[ -z "$replace" ] || [ -f "$replace" ] || bad "no such replace-text file: $replace"
# absolute: git filter-repo runs inside BARE_REPO, where a relative path would point elsewhere
abs() { printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")"; }
[ -z "$mailmap" ] || mailmap=$(abs "$mailmap")
[ -z "$replace" ] || replace=$(abs "$replace")
[ -f "$guard" ] || die "attribution guard not found at $guard"
git filter-repo --version >/dev/null 2>&1 || die "git filter-repo is not installed (apt/brew install git-filter-repo, or pip install git-filter-repo)"
command -v python3 >/dev/null || die "python3 is required"
[ "$(git -C "$repo" rev-parse --is-bare-repository 2>/dev/null)" = true ] || die "$repo is not a bare repository (use git clone --bare)"
[ -z "$(git -C "$repo" for-each-ref refs/pull)" ] || die "$repo has refs/pull/*: use git clone --bare, not --mirror"
report=${report:-$repo.clean-history}
mkdir -p "$report"
report=$(cd "$report" && pwd)
url=$(git -C "$repo" config --get remote.origin.url || true)

# --- before ---------------------------------------------------------------------------------------
git -C "$repo" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags >"$report/refs-before.txt"
[ -s "$report/refs-before.txt" ] || die "no branches or tags in $repo"
git -C "$repo" rev-list --all --format='%H %T' | grep -v '^commit ' >"$report/trees-before.txt"
# Commits whose message carries attribution: the list GitHub Support needs for the old SHAs.
: >"$report/attribution-commits.txt"
while read -r c _; do
  if ! git -C "$repo" log -1 --format=%B "$c" | sh "$guard" check >/dev/null; then
    echo "$c $(git -C "$repo" log -1 --format='%cs %s' "$c")" >>"$report/attribution-commits.txt"
  fi
done <"$report/trees-before.txt"
before_count=$(wc -l <"$report/trees-before.txt" | tr -d ' ')
echo "==> $before_count commits, $(wc -l <"$report/attribution-commits.txt" | tr -d ' ') with attribution in the message, $(wc -l <"$report/refs-before.txt" | tr -d ' ') refs"

# --- rewrite --------------------------------------------------------------------------------------
{
  printf '%s <%s> <noreply@anthropic.com>\n' "$owner_name" "$owner_email"
  [ -z "$mailmap" ] || cat "$mailmap"
} >"$report/mailmap.txt"

callback='
import os, re, subprocess, tempfile
drop = [e.encode() for e in os.environ.get("CLEAN_HISTORY_DROP", "").split("\n") if e]
if drop:
    rx = re.compile(rb"^[ \t]*co-authored-by:[^\n]*<(?:" + b"|".join(re.escape(e) for e in drop) + rb")>[ \t]*$", re.I)
    message = b"\n".join(l for l in message.split(b"\n") if not rx.match(l))
fd, path = tempfile.mkstemp(prefix="clean-history.")
with os.fdopen(fd, "wb") as f:
    f.write(message)
env = dict(os.environ, ATTRIBUTION_GUARD_MODE="strip",
           GIT_AUTHOR_NAME=os.environ["CLEAN_HISTORY_OWNER_NAME"], GIT_AUTHOR_EMAIL=os.environ["CLEAN_HISTORY_OWNER_EMAIL"])
r = subprocess.run(["sh", os.environ["CLEAN_HISTORY_GUARD"], "commit-msg", path], env=env, capture_output=True)
with open(path, "rb") as f:
    cleaned = f.read()
os.unlink(path)
if r.returncode != 0:
    raise SystemExit("clean-history: the attribution guard refused a message (" + r.stderr.decode(errors="replace").strip()
                     + "); subject: " + message.split(b"\n")[0].decode(errors="replace"))
lines = re.sub(rb"\n{3,}", b"\n\n", cleaned).split(b"\n")
while lines and re.fullmatch(rb"[ \t]*(-{3,})?[ \t]*", lines[-1]):  # blank lines and a dangling "---------"
    lines.pop()
cleaned = b"\n".join(lines) + b"\n"
return cleaned
'
args=(--mailmap "$report/mailmap.txt" --message-callback "$callback")
[ -z "$replace" ] || args+=(--replace-text "$replace")
echo "==> rewriting (git filter-repo)"
CLEAN_HISTORY_GUARD=$guard CLEAN_HISTORY_OWNER_NAME=$owner_name CLEAN_HISTORY_OWNER_EMAIL=$owner_email \
  CLEAN_HISTORY_DROP=$(printf '%s\n' "${drop[@]+"${drop[@]}"}") \
  git -C "$repo" filter-repo --quiet "${args[@]}" || die "git filter-repo stopped; nothing was pushed"
# some filter-repo versions keep the origin remote of a bare clone; it must not survive, so a stray push is impossible
git -C "$repo" remote remove origin 2>/dev/null || true

# --- verify ---------------------------------------------------------------------------------------
fail=0
problem() { echo "  FAIL: $*"; fail=1; }
echo "==> verifying"
git -C "$repo" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags >"$report/refs-after.txt"
cut -d' ' -f1 "$report/refs-before.txt" | cmp -s - <(cut -d' ' -f1 "$report/refs-after.txt") \
  || problem "the set of branches and tags changed"
after_count=$(git -C "$repo" rev-list --all | wc -l | tr -d ' ')
[ "$after_count" = "$before_count" ] || problem "commit count changed: $before_count -> $after_count"

# every message, all refs, with the same patterns the required check uses
if hits=$(git -C "$repo" log --all --format='%H%n%B' | sh "$guard" check); then :; else
  problem "attribution left in commit messages:"; printf '%s\n' "$hits" | head -n 20 | sed 's/^/    /'
fi
ids=$(git -C "$repo" log --all --format='%an <%ae>%n%cn <%ce>' | sort -u)
if printf '%s\n' "$ids" | grep -Ei '@anthropic\.com>|^claude <' >/dev/null; then
  problem "vendor identity left: $(printf '%s\n' "$ids" | grep -Ei '@anthropic\.com>|^claude <' | tr '\n' ' ')"
fi
for t in "${forbid[@]+"${forbid[@]}"}"; do
  n_msg=$(git -C "$repo" log --all --format='%B' | grep -Fic -- "$t" || true)
  n_id=$(printf '%s\n' "$ids" | grep -Fic -- "$t" || true)
  n_blob=$(git -C "$repo" log --all --format=%H -S"$t" | wc -l | tr -d ' ')
  [ "$n_msg$n_id$n_blob" = 000 ] || problem "'$t' still present: $n_msg message line(s), $n_id identity(ies), $n_blob commit(s) touching it in files"
done

# content: every rewritten commit keeps its tree unless --replace-text changed file contents
changed=0
while read -r old new; do
  [ "$old" = old ] && continue # header line
  otree=$(grep "^$old " "$report/trees-before.txt" | cut -d' ' -f2)
  [ -n "$otree" ] || continue
  [ "$otree" = "$(git -C "$repo" rev-parse "$new^{tree}")" ] || changed=$((changed + 1))
done <"$repo/filter-repo/commit-map"
if [ "$changed" -gt 0 ] && [ -z "$replace" ]; then
  problem "$changed commit(s) have a different tree although no --replace-text was given"
fi
echo "  commits: $after_count (unchanged); trees changed by --replace-text: $changed"
echo "  identities now:"; printf '%s\n' "$ids" | sed 's/^/    /'

cp "$repo/filter-repo/commit-map" "$report/commit-map.txt"
if [ "$fail" -ne 0 ]; then
  echo "clean-history: verification FAILED; do not push. Reports: $report" >&2
  exit 1
fi

echo "==> verification passed. Reports: $report"
echo
echo "Push commands (after lifting branch protection; see docs/HISTORY-CLEANUP.md). git filter-repo"
echo "removed the origin remote on purpose, so it is added back here:"
echo
echo "  git -C '$repo' remote add origin '${url:-https://github.com/<owner>/<repo>.git}'"
while read -r ref new; do
  old=$(grep "^$ref " "$report/refs-before.txt" | cut -d' ' -f2)
  if [ "$old" = "$new" ]; then echo "  # $ref unchanged"; continue; fi
  echo "  git -C '$repo' push --force-with-lease='$ref:$old' origin '$ref:$ref'"
done <"$report/refs-after.txt"
