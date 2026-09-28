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

set -u

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if [ -z "${ATTRIB_RE:-}" ]; then
    [ -r "$here/patterns.ere" ] || { printf 'attribution-guard: %s/patterns.ere missing\n' "$here" >&2; exit 1; }
    ATTRIB_RE=$(sed -n '1p' "$here/patterns.ere")
fi
IDENT_RE='@anthropic\.com$' # matched against e-mail addresses only
export ATTRIB_RE IDENT_RE

die() { printf 'attribution-guard: %s\n' "$*" >&2; exit 1; }

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

    hits=$(head -n $((end - 1)) "$f" | norm | grep -n -E -i -e "$ATTRIB_RE" || true)
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

pre_push() {
    # $1 is the remote name; commits on ANY remote-tracking ref count as published.
    check_committer=$(git config --type=bool --get attributionguard.checkCommitter 2>/dev/null || echo false)
    status=0
    while read -r lref lsha _rref rsha; do
        case $lsha in *[!0]*) ;; *) continue ;; esac # branch deletion
        # Only commits that are on no remote yet. Commits already published by others (a merged
        # main, a fork's upstream) are not yours to rewrite and do not get worse by this push.
        if case $rsha in *[!0]*) git cat-file -e "$rsha^{commit}" 2>/dev/null ;; *) false ;; esac; then
            set -- "$lsha" "^$rsha" --not --remotes
        else
            set -- "$lsha" --not --remotes
        fi
        # \001 marks a commit header so message lines can never be mistaken for one.
        report=$(git log --format='%x01%h %ae %ce%n%B' "$@" | norm | CHECK_COMMITTER=$check_committer awk '
            BEGIN { re = tolower(ENVIRON["ATTRIB_RE"]); id = tolower(ENVIRON["IDENT_RE"])
                    cc = ENVIRON["CHECK_COMMITTER"] == "true" }
            substr($0, 1, 1) == "\001" {
                split(substr($0, 2), h, " "); sha = h[1]
                if (tolower(h[2]) ~ id) print sha ": authored as " h[2]
                if (cc && tolower(h[3]) ~ id) print sha ": committed as " h[3]
                next }
            tolower($0) ~ re { print sha ": " $0 }')
        # Annotated tags carry their own message and tagger; git log only sees the tagged commit.
        if [ "$(git cat-file -t "$lsha" 2>/dev/null)" = tag ]; then
            report="$report
$(git cat-file tag "$lsha" | norm | TAG="${lref#refs/tags/}" awk '
                BEGIN { re = tolower(ENVIRON["ATTRIB_RE"]); id = tolower(ENVIRON["IDENT_RE"]); t = "tag " ENVIRON["TAG"] }
                !body && /^tagger / { e = $0; sub(/^[^<]*</, "", e); sub(/>.*$/, "", e)
                                      if (tolower(e) ~ id) print t ": tagged as " e; next }
                !body && /^$/ { body = 1; next }
                body && tolower($0) ~ re { print t ": " $0 }')"
        fi
        # git notes live in blobs under refs/notes/*.
        case $lref in
            refs/notes/*) report="$report
$(git grep -I -h -E -i -e "$ATTRIB_RE" "$lsha" -- 2>/dev/null | sed "s|^|${lref}: |")" ;;
        esac
        report=$(printf '%s\n' "$report" | sed '/^$/d')
        if [ -n "$report" ]; then
            printf 'attribution-guard: refusing to push %s; AI attribution found:\n%s\n' "$lref" "$report" >&2
            status=1
        fi
    done
    if [ "$status" -ne 0 ]; then
        cat >&2 <<'EOF'
attribution-guard: only commits that are on no remote yet are checked, so these are your own
unpublished commits. Rewrite them (the commit-msg hook in strip mode cleans each message):
  git rebase -r --exec 'git commit --amend --no-edit --reset-author' <upstream>
Re-create a tag with a clean message: git tag -f -a <name> <commit>
EOF
    fi
    return "$status"
}

case ${1:-} in
    commit-msg) shift; commit_msg "$@" ;;
    pre-push) shift; pre_push "$@" ;;
    check) shift; if cat "${1:--}" | norm | grep -E -i -n -e "$ATTRIB_RE"; then exit 1; fi ;;
    *) die "usage: $0 commit-msg <file> | pre-push <remote> [<url>] | check [<file>]" ;;
esac
