#!/bin/sh
# attribution-guard: keep AI attribution and chat/session links out of git history.
#
# Matches attribution patterns only (patterns.ere next to this file), never the bare word "claude":
# "-by:" trailers naming Claude/Anthropic or an @anthropic.com address, noreply@anthropic.com,
# Claude-Session: trailers, claude.ai session/share/chat/artifact links, claude.site,
# claude.com/claude-code, "Generated/Built/... with/by/via Claude (Code)". Zero-width characters are
# removed before matching. Repo and plugin names such as claude-security or claude-plugins-official
# do not match.
#
# POSIX sh (dash, bash, busybox, Git for Windows sh.exe). Needs git, grep, sed, awk.
#
#   attribution-guard.sh commit-msg <message-file>   strip (default) or reject
#   attribution-guard.sh pre-push <remote> [<url>]   reject; ref list on stdin
#   attribution-guard.sh check [<file>]              print hits, exit 1 when the text has attribution
#
# git config (or env) knobs:
#   attributionguard.mode           strip | reject (env ATTRIBUTION_GUARD_MODE). pre-push always rejects.
#   attributionguard.checkCommitter true | false (default false). Cloud sessions force the committer
#                                   to the vendor identity; GitHub only credits commit *authors* on a
#                                   squash merge, so the author is what must never be the vendor.
#   attributionguard.trustRemotes   remote names (multi-valued) whose published history pre-push skips,
#                                   e.g. a fork's upstream. The push destination is always trusted.

set -u
# Byte semantics: a stray non-UTF-8 byte must not turn grep's output into "binary file matches".
LC_ALL=C
export LC_ALL

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if [ -z "${ATTRIB_RE:-}" ]; then
    [ -r "$here/patterns.ere" ] || { printf 'attribution-guard: %s/patterns.ere missing\n' "$here" >&2; exit 1; }
    ATTRIB_RE=$(sed -n '1p' "$here/patterns.ere")
fi
IDENT_RE='@anthropic\.com$' # matched against e-mail addresses only
export ATTRIB_RE IDENT_RE

die() { printf 'attribution-guard: %s\n' "$*" >&2; exit 1; }

# A pattern that does not compile would make every check pass: refuse instead (fail closed).
[ -n "$ATTRIB_RE" ] || die "empty attribution pattern"
printf 'x\n' | grep -E -i -e "$ATTRIB_RE" >/dev/null 2>&1
[ $? -le 1 ] || die "the attribution pattern does not compile (grep -E)"
printf 'x\n' | awk 'BEGIN { re = tolower(ENVIRON["ATTRIB_RE"]) } { if ($0 ~ re) n++ }' >/dev/null 2>&1 \
    || die "the attribution pattern does not compile (awk)"

# Remove zero-width characters (U+200B-U+200D, U+2060, U+FEFF) that would split a pattern.
norm() {
    sed -e "s/$(printf '\342\200\213')//g" -e "s/$(printf '\342\200\214')//g" -e "s/$(printf '\342\200\215')//g" \
        -e "s/$(printf '\342\201\240')//g" -e "s/$(printf '\357\273\277')//g"
}

guard_mode() {
    m=${ATTRIBUTION_GUARD_MODE:-$(git config --get attributionguard.mode 2>/dev/null || true)}
    case $m in reject) echo reject ;; *) echo strip ;; esac
}

check_identity() {
    vars=GIT_AUTHOR_IDENT
    [ "$(git config --type=bool --get attributionguard.checkCommitter 2>/dev/null || echo false)" = true ] \
        && vars="$vars GIT_COMMITTER_IDENT"
    for v in $vars; do
        id=$(git var "$v" 2>/dev/null) || continue
        mail=${id#*<}; mail=${mail%%>*}
        if printf '%s\n' "$mail" | grep -Eiq "$IDENT_RE"; then
            die "$v is '${id% * *}'. Commit as yourself:
  git config user.name 'Your Name'; git config user.email 'ID+user@users.noreply.github.com'
or set GIT_AUTHOR_NAME and GIT_AUTHOR_EMAIL."
        fi
    done
}

commit_msg() {
    f=${1:?message file}
    [ -f "$f" ] || die "no message file: $f"
    check_identity

    cc=$(git config --get core.commentChar 2>/dev/null || true)
    case $cc in '' | auto) cc='#' ;; esac
    # Everything below the scissors line (git commit -v diff) is discarded by git; never scan it.
    end=$(grep -n -e "^$cc -\{24\} >8 -\{24\}\$" "$f" 2>/dev/null | head -n 1 | cut -d: -f1)
    [ -n "$end" ] || end=$(awk 'END { print NR + 1 }' "$f") # NR counts a last line without newline

    hits=$(head -n $((end - 1)) "$f" | norm | grep -a -n -E -i -e "$ATTRIB_RE")
    [ $? -le 1 ] || die "could not scan the commit message"
    [ -n "$hits" ] || return 0

    subject=$(awk 'NF { print NR; exit }' "$f")
    first_hit=${hits%%:*}
    if [ "$(guard_mode)" = reject ] || [ "$first_hit" = "$subject" ]; then
        printf 'attribution-guard: commit message contains AI attribution:\n%s\n' "$hits" >&2
        [ "$first_hit" = "$subject" ] && echo 'attribution-guard: the subject line itself matches; reword it.' >&2
        exit 1
    fi

    lines=$(printf '%s\n' "$hits" | cut -d: -f1 | tr '\n' ' ')
    tmp="$f.attribution-guard.$$"
    # Drop the matched lines, then trim the blank lines and '---' separators they leave at the
    # end of the message body (git's own cleanup does not run with --cleanup=verbatim).
    LINES_TO_DROP=" $lines" END_LINE=$end awk '
        BEGIN { n = split(ENVIRON["LINES_TO_DROP"], d, " "); for (i = 1; i <= n; i++) drop[d[i]] = 1
                end = ENVIRON["END_LINE"] + 0 }
        NR < end { if (!(NR in drop)) body[++b] = $0; next }
        { tail[++t] = $0 }
        END {
            while (b > 0 && (body[b] ~ /^[ \t]*$/ || body[b] ~ /^[ \t]*---+[ \t]*$/)) b--
            for (i = 1; i <= b; i++) print body[i]
            if (t > 0) { print ""; for (i = 1; i <= t; i++) print tail[i] }
        }' "$f" >"$tmp" && cat "$tmp" >"$f"
    rm -f "$tmp"
    printf 'attribution-guard: removed %s attribution line(s) from the commit message.\n' \
        "$(printf '%s\n' "$hits" | wc -l | tr -d ' ')" >&2
}

# Scan text on stdin (already prefixed "<where>\001<line>" per line) and print "<where>: <line>".
scan_lines() {
    awk -F "$(printf '\001')" 'BEGIN { re = tolower(ENVIRON["ATTRIB_RE"]) } tolower($2) ~ re { print $1 ": " $2 }'
}

pre_push() {
    remote=${1:-origin} url=${2:-${1:-origin}}
    check_committer=$(git config --type=bool --get attributionguard.checkCommitter 2>/dev/null || echo false)
    t=$(mktemp -d 2>/dev/null || { mkdir -p "${TMPDIR:-/tmp}/ag.$$" && echo "${TMPDIR:-/tmp}/ag.$$"; })
    # Commits the destination (or a trusted remote) already has are published: other people's work
    # (a merged main, a fork's upstream) is not yours to rewrite and does not get worse by this push.
    # Only what the remotes advertise right now counts; local refs/remotes/* can be written by anyone.
    if ! git ls-remote --heads --tags "$url" >"$t/ls" 2>/dev/null; then
        printf 'attribution-guard: could not list what %s already has; checking every commit being pushed.\n' "$remote" >&2
        : >"$t/ls"
    fi
    for r in $(git config --get-all attributionguard.trustRemotes 2>/dev/null); do
        git ls-remote --heads --tags "$r" >>"$t/ls" 2>/dev/null \
            || printf 'attribution-guard: could not list trusted remote %s.\n' "$r" >&2
    done
    awk '{ print $1 }' "$t/ls" | sort -u | git cat-file --batch-check='%(objectname) %(objecttype)' 2>/dev/null \
        | awk '$2 == "commit" || $2 == "tag" { print "^" $1 }' >"$t/not"
    status=0
    while read -r lref lsha rref rsha; do
        case $lsha in *[!0]*) ;; *) continue ;; esac # branch deletion
        : >"$t/report"
        # The remote's current tip of this ref is published too.
        { echo "$lsha"; cat "$t/not"
          case $rsha in *[!0]*) git cat-file -e "$rsha^{commit}" 2>/dev/null && echo "^$rsha" ;; esac
        } >"$t/revs"
        # \001 marks a commit header so message lines can never be mistaken for one.
        git log --stdin --format='%x01%h %ae %ce%n%B' <"$t/revs" >"$t/log" 2>/dev/null \
            || { echo "$lref: could not list the commits being pushed" >>"$t/report"; }
        norm <"$t/log" | CHECK_COMMITTER=$check_committer awk '
            BEGIN { re = tolower(ENVIRON["ATTRIB_RE"]); id = tolower(ENVIRON["IDENT_RE"])
                    cc = ENVIRON["CHECK_COMMITTER"] == "true" }
            substr($0, 1, 1) == "\001" {
                split(substr($0, 2), h, " "); sha = h[1]
                if (tolower(h[2]) ~ id) print sha ": authored as " h[2]
                if (cc && tolower(h[3]) ~ id) print sha ": committed as " h[3]
                next }
            tolower($0) ~ re { print sha ": " $0 }' >>"$t/report" \
            || echo "$lref: could not scan the commits being pushed" >>"$t/report"
        # Annotated tags carry their own message and tagger, and may wrap further tags.
        obj=$lsha depth=0
        while [ "$(git cat-file -t "$obj" 2>/dev/null)" = tag ] && [ "$depth" -lt 10 ]; do
            git cat-file tag "$obj" >"$t/tag"
            norm <"$t/tag" | TAG="tag ${lref#refs/tags/}" awk '
                BEGIN { re = tolower(ENVIRON["ATTRIB_RE"]); id = tolower(ENVIRON["IDENT_RE"]); t = ENVIRON["TAG"] }
                !body && /^tagger / { e = $0; sub(/^[^<]*</, "", e); sub(/>.*$/, "", e)
                                      if (tolower(e) ~ id) print t ": tagged as " e; next }
                !body && /^$/ { body = 1; next }
                body && tolower($0) ~ re { print t ": " $0 }' >>"$t/report"
            obj=$(sed -n 's/^object //p' "$t/tag" | head -n 1)
            depth=$((depth + 1))
        done
        # git notes live in blobs; check every note line added in the history being pushed, not only
        # the tip (an edited note keeps the old blob in history). Decided by the DESTINATION ref.
        case $rref in
            refs/notes/*)
                git log --stdin -p --no-color --format='%x01%h' <"$t/revs" 2>/dev/null \
                    | norm | awk -v where="$rref" '
                        substr($0, 1, 1) == "\001" { sha = substr($0, 2); next }
                        /^\+\+\+ / { next }
                        /^\+/ { print where " " sha "\001" substr($0, 2) }' | scan_lines >>"$t/report" ;;
        esac
        if [ -s "$t/report" ]; then
            printf 'attribution-guard: refusing to push %s; AI attribution found:\n' "$lref" >&2
            cat "$t/report" >&2
            status=1
        fi
    done
    rm -rf "$t"
    if [ "$status" -ne 0 ]; then
        cat >&2 <<'EOF'
attribution-guard: only commits the destination does not have yet are checked. If these are your
own commits, rewrite them (the commit-msg hook in strip mode cleans each message):
  git rebase -r --exec 'git commit --amend --no-edit --reset-author' <upstream>
Re-create a tag with a clean message: git tag -f -a <name> <commit>. Notes: rewrite the notes ref.
If they are other people's published commits from another remote (a fork's upstream), trust it:
  git config attributionguard.trustRemotes <remote>
EOF
    fi
    return "$status"
}

case ${1:-} in
    commit-msg) shift; commit_msg "$@" ;;
    pre-push) shift; pre_push "$@" ;;
    check) shift
        hits=$(cat "${1:--}" | norm | grep -a -E -i -n -e "$ATTRIB_RE")
        rc=$?
        [ "$rc" -le 1 ] || die "could not scan the text"
        [ -z "$hits" ] || { printf '%s\n' "$hits"; exit 1; } ;;
    *) die "usage: $0 commit-msg <file> | pre-push <remote> [<url>] | check [<file>]" ;;
esac
