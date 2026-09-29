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
#   attributionguard.trustUrl       URLs (multi-valued) whose published history pre-push skips, e.g. a
#                                   fork's upstream. What the push destination advertises is always
#                                   skipped. URLs, not remote names: a remote's URL is easy to repoint.

set -u
# Byte semantics: a stray non-UTF-8 byte must not turn grep's output into "binary file matches".
LC_ALL=C
export LC_ALL

# Replacement objects (git replace) would let the checks read other text than the push sends.
GIT_NO_REPLACE_OBJECTS=1
export GIT_NO_REPLACE_OBJECTS

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# Always the file next to this script: an ATTRIB_RE from the environment would let a caller
# (ATTRIB_RE=x git push) switch the guard off.
[ -r "$here/patterns.ere" ] || { printf 'attribution-guard: %s/patterns.ere missing\n' "$here" >&2; exit 1; }
ATTRIB_RE=$(sed -n '1p' "$here/patterns.ere")
IDENT_RE='@anthropic\.com$' # matched against e-mail addresses only
export ATTRIB_RE IDENT_RE

die() { printf 'attribution-guard: %s\n' "$*" >&2; exit 1; }

# A pattern that does not compile would make every check pass: refuse instead (fail closed).
[ -n "$ATTRIB_RE" ] || die "empty attribution pattern"
printf 'x\n' | grep -E -i -e "$ATTRIB_RE" >/dev/null 2>&1
[ $? -le 1 ] || die "the attribution pattern does not compile (grep -E)"
printf 'x\n' | awk 'BEGIN { re = tolower(ENVIRON["ATTRIB_RE"]) } { if ($0 ~ re) n++ }' >/dev/null 2>&1 \
    || die "the attribution pattern does not compile (awk)"
# Self-test, because some awks (busybox) treat a pattern that does not compile as one that never
# matches: a known trailer must match and a plain word must not.
awk_hit() { printf '%s\n' "$1" | awk 'BEGIN { re = tolower(ENVIRON["ATTRIB_RE"]) } { if (tolower($0) ~ re) h = 1 } END { exit !h }'; }
if ! awk_hit 'Co-Authored-By: Claude <noreply@anthropic.com>' || awk_hit x; then
    die "the attribution pattern fails its self-test (awk)"
fi

# Remove zero-width and invisible characters that would split a pattern: U+00AD, U+034F, U+180E,
# U+200B-U+200D, U+2060-U+2064 and U+FEFF, as UTF-8 bytes (the same list as match.awk).
NORM_SED=$(printf 's/\302\255//g;s/\315\217//g;s/\341\240\216//g;s/\342\200\213//g;s/\342\200\214//g;s/\342\200\215//g
s/\342\201\240//g;s/\342\201\241//g;s/\342\201\242//g;s/\342\201\243//g;s/\342\201\244//g;s/\357\273\277//g')
norm() { sed -e "$NORM_SED"; }

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
    # Below the scissors line of git commit -v comes the diff, which git discards; do not scan it.
    # Only when a diff really follows: a literal scissors line in -m/-F text is kept by git.
    end=$(grep -n -e "^$cc -\{24\} >8 -\{24\}\$" "$f" 2>/dev/null | head -n 1 | cut -d: -f1)
    if [ -n "$end" ] && ! tail -n "+$end" "$f" | grep -q '^diff --git '; then end=; fi
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

# A URL without the user:password@ part, for messages.
anon() { printf '%s' "$1" | sed 's#//[^/@]*@#//#'; }

# The ssh command git would run, with connect and keep-alive timeouts, so a stalled SSH connection
# cannot hang the push. Only for OpenSSH; empty for plink and other GIT_SSH programs.
ssh_bounded() {
    c=${GIT_SSH_COMMAND:-$(git config --get core.sshCommand 2>/dev/null)}
    [ -n "$c" ] || [ -n "${GIT_SSH:-}" ] || c=ssh
    case ${c%% *} in
        ssh | ssh.exe | */ssh | */ssh.exe)
            printf '%s -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=2\n' "$c" ;;
    esac
}

# Branch and tag tips a URL publishes, as the remote advertises them now. Refuses (status 2) when an
# insteadOf rewrite would send the listing to a different repository than the URL names.
advertised() {
    [ "$(git ls-remote --get-url "$1" 2>/dev/null)" = "$1" ] || return 2
    (
        s=$(ssh_bounded)
        [ -z "$s" ] || { GIT_SSH_COMMAND=$s; export GIT_SSH_COMMAND; }
        GIT_TERMINAL_PROMPT=0 git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 \
            ls-remote --heads --tags "$1" 2>/dev/null
    )
}

pre_push() {
    remote=${1:-origin} url=${2:-${1:-origin}}
    check_committer=$(git config --type=bool --get attributionguard.checkCommitter 2>/dev/null || echo false)
    t=$(mktemp -d 2>/dev/null || { mkdir -p "${TMPDIR:-/tmp}/ag.$$" && echo "${TMPDIR:-/tmp}/ag.$$"; })
    # Commits the destination (or a trusted URL) already has are published: other people's work (a
    # merged main, a fork's upstream) is not yours to rewrite and does not get worse by this push.
    # Only what the remote advertises right now counts; local refs/remotes/* can be written by anyone.
    if ! advertised "$url" >"$t/ls"; then
        printf 'attribution-guard: could not list what %s already has; checking every commit being pushed.\n' "$(anon "$remote")" >&2
        : >"$t/ls"
    fi
    for u in $(git config --get-all attributionguard.trustUrl 2>/dev/null); do
        advertised "$u" >>"$t/ls" || printf 'attribution-guard: could not list trusted URL %s.\n' "$(anon "$u")" >&2
    done
    awk '{ print $1 }' "$t/ls" | sort -u | git cat-file --batch-check='%(objectname) %(objecttype)' 2>/dev/null \
        | awk '$2 == "commit" || $2 == "tag" { print "^" $1 }' >"$t/not"

    # Read the whole push first, then walk everything the destination lacks once.
    : >"$t/refs"
    cp "$t/not" "$t/revs"
    while read -r lref lsha rref rsha; do
        case $lsha in *[!0]*) ;; *) continue ;; esac # deletion
        case $rsha in *[!0]*) git cat-file -e "$rsha" 2>/dev/null || rsha=0 ;; *) rsha=0 ;; esac
        echo "$lref $lsha $rref $rsha" >>"$t/refs"
        echo "$lsha" >>"$t/revs"
        [ "$rsha" = 0 ] || echo "^$rsha" >>"$t/revs"
    done
    [ -s "$t/refs" ] || { rm -rf "$t"; return 0; }
    : >"$t/report"
    # \001 marks a commit header so message lines can never be mistaken for one. --encoding keeps
    # i18n.logOutputEncoding (from config or git -c on the push) from re-encoding the messages.
    git log --encoding=UTF-8 --stdin --format='%x01%h %ae %ce%n%B' <"$t/revs" >"$t/log" 2>/dev/null \
        || echo "could not list the commits being pushed" >>"$t/report"
    norm <"$t/log" | CHECK_COMMITTER=$check_committer awk '
        BEGIN { re = tolower(ENVIRON["ATTRIB_RE"]); id = tolower(ENVIRON["IDENT_RE"])
                cc = ENVIRON["CHECK_COMMITTER"] == "true" }
        substr($0, 1, 1) == "\001" {
            split(substr($0, 2), h, " "); sha = h[1]
            if (tolower(h[2]) ~ id) print sha ": authored as " h[2]
            if (cc && tolower(h[3]) ~ id) print sha ": committed as " h[3]
            next }
        tolower($0) ~ re { print sha ": " $0 }' >>"$t/report" \
        || echo "could not scan the commits being pushed" >>"$t/report"

    while read -r lref lsha rref rsha; do
        # Annotated tags carry their own message and tagger, and may wrap further tags.
        obj=$lsha depth=0
        while [ "$(git cat-file -t "$obj" 2>/dev/null)" = tag ]; do
            if [ "$depth" -ge 10 ]; then echo "$lref: tags nested deeper than 10" >>"$t/report"; break; fi
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
        # git notes live in blobs. Check every blob in the notes history being pushed (an edited
        # note keeps the old blob in history), read directly: no diff, textconv or attributes.
        # Decided by the DESTINATION ref, whatever the local ref is called.
        case $rref in
            refs/notes/*)
                { echo "$lsha"; cat "$t/not"; [ "$rsha" = 0 ] || echo "^$rsha"; } \
                    | git rev-list --objects --stdin 2>/dev/null | awk '{ print $1 }' \
                    | git cat-file --batch-check='%(objectname) %(objecttype)' 2>/dev/null \
                    | awk '$2 == "blob" { print $1 }' >"$t/blobs"
                while read -r b; do
                    git cat-file blob "$b" 2>/dev/null | tr '\000' '\n' | norm \
                        | awk -v w="$rref blob ${b%"${b#???????}"}" '{ print w "\001" $0 }' | scan_lines
                done <"$t/blobs" >>"$t/report" ;;
        esac
    done <"$t/refs"

    status=0
    if [ -s "$t/report" ]; then
        printf 'attribution-guard: refusing to push to %s; AI attribution found:\n' "$(anon "$remote")" >&2
        cat "$t/report" >&2
        cat >&2 <<'EOF'
attribution-guard: only what the destination does not have yet is checked. If these are your own
commits, rewrite them (the commit-msg hook in strip mode cleans each message):
  git rebase -r --exec 'git commit --amend --no-edit --reset-author' <upstream>
Re-create a tag with a clean message: git tag -f -a <name> <commit>. Notes: rewrite the notes ref.
If they are other people's published commits from another repository (a fork's upstream), trust
its URL once (the owner, by hand): git config attributionguard.trustUrl <url>
EOF
        status=1
    fi
    rm -rf "$t"
    return "$status"
}

case ${1:-} in
    commit-msg) shift; commit_msg "$@" ;;
    pre-push) shift; pre_push "$@" ;;
    check) shift
        # A file that cannot be read must not pass as clean text (sh has no pipefail to tell).
        case ${1:--} in
            -) ;;
            *) { [ -r "$1" ] && [ ! -d "$1" ]; } || die "cannot read $1"
               exec <"$1" ;;
        esac
        hits=$(norm | grep -a -E -i -n -e "$ATTRIB_RE")
        rc=$?
        [ "$rc" -le 1 ] || die "could not scan the text"
        [ -z "$hits" ] || { printf '%s\n' "$hits"; exit 1; } ;;
    *) die "usage: $0 commit-msg <file> | pre-push <remote> [<url>] | check [<file>]" ;;
esac
