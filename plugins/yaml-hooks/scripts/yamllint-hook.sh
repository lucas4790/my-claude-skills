#!/bin/sh
# yaml-hooks: Claude Code PostToolUse hook for Write/Edit/MultiEdit.
#
# Runs yamllint on the .yaml/.yml file the tool just wrote and, when yamllint reports errors, prints
#   {"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"..."}}
# and exits 0: Claude Code adds that text next to the tool result without treating the edit as failed.
# The hook never blocks and never fails: no yamllint, not a YAML file, file gone, Helm or Jinja
# template, unexpected input or any internal error all end in a silent exit 0. A yamllint that stops
# with a usage or config error instead of linting (older than 1.30, or a broken config) gets one line
# of additionalContext saying the hook is inactive and why, also with exit 0.
#
# Config, in yamllint's own order of preference:
#   1. .yamllint / .yamllint.yaml / .yamllint.yml in the file's directory or above (up to $HOME or /);
#      yamllint then runs from that directory, and files its ignore / ignore-from-file excludes are skipped
#   2. $YAMLLINT_CONFIG_FILE, else ${XDG_CONFIG_HOME:-~/.config}/yamllint/config
#   3. yamllint-default.yaml next to this script (errors: syntax, duplicate keys, undeclared aliases;
#      every style rule is a warning or off)
# Errors are listed (at most 20 lines); warnings are only counted unless YAML_HOOKS_WARNINGS=1.
#
# Input: the hook JSON on stdin. The file comes from tool_input.file_path (Claude Code), or path /
# filePath (other harnesses; a relative path is resolved against "cwd").

unset CDPATH
MAX_LINES=20
MAX_BYTES=1048576
SOH=$(printf '\001')
TAB=$(printf '\t')

here=$(dirname "$0")
case $here in /* | [A-Za-z]:*) ;; *) here=$(pwd)/$here ;; esac
default_config=$here/yamllint-default.yaml

input=$(cat 2>/dev/null) || exit 0
[ -n "$input" ] || exit 0

# json_string KEY: the first string value of "KEY" in $input, with \\ \" \/ unescaped. A key inside a
# string value never matches, because its quotes are escaped there (\"KEY\").
json_string() {
  printf '%s' "$input" | tr '\n\r' '  ' |
    grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"([^\"\\\\]|\\\\.)*\"" | head -n 1 |
    sed -e "s/^\"$1\"[[:space:]]*:[[:space:]]*\"//" -e 's/"$//' \
      -e "s/\\\\\\\\/$SOH/g" -e 's/\\"/"/g' -e 's#\\/#/#g' -e "s/$SOH/\\\\/g"
}

# to_slashes PATH: C:\x\y -> C:/x/y (Windows paths arrive with backslashes; Git Bash and Python take /)
to_slashes() {
  case $1 in
    [A-Za-z]:\\* | \\\\*) printf '%s' "$1" | tr '\134' / ;;
    *) printf '%s' "$1" ;;
  esac
}

# json_escape: stdin -> body of a JSON string (control characters dropped, newlines as \n)
json_escape() {
  tr -d '\000-\010\013-\037' |
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$TAB/\\\\t/g" -e 's/$/\\n/' | tr -d '\n'
}

# cannot_lint ARGS...: `yamllint ARGS` stopped with a usage or config error instead of linting: yamllint
# is older than 1.30 (--list-files is new in 1.29, the default config's anchors rule in 1.30), or the
# config is broken (the last line yamllint writes to stderr says how). One line of context; exit 0.
cannot_lint() {
  [ -f "$file" ] || exit 0
  ver=$(yamllint --version 2>/dev/null)
  ver=${ver##* }
  case $ver in
    0.* | 1.[0-9].* | 1.[12][0-9].*) why="yamllint $ver is older than 1.30" ;;
    *) why="$(cd -- "$workdir" 2>/dev/null && yamllint "$@" 2>&1 >/dev/null | tail -n 1) (config: $label)" ;;
  esac
  ctx=$(printf 'yaml-hooks: YAML lint hook inactive: %s\n' "$why" | json_escape)
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$ctx"
  exit 0
}

case $(json_string tool_name) in
  Write | Edit | MultiEdit | create | edit) ;;
  *) exit 0 ;;
esac

file=$(json_string file_path)
[ -n "$file" ] || file=$(json_string filePath)
[ -n "$file" ] || file=$(json_string path)
case $file in
  *.[yY][aA][mM][lL] | *.[yY][mM][lL]) ;;
  *) exit 0 ;;
esac
file=$(to_slashes "$file")
case $file in
  /* | [A-Za-z]:/*) ;;
  *)
    cwd=$(to_slashes "$(json_string cwd)")
    [ -n "$cwd" ] || exit 0
    file=$cwd/$file
    ;;
esac

[ -f "$file" ] || exit 0
command -v yamllint >/dev/null 2>&1 || exit 0
size=$(wc -c <"$file" 2>/dev/null | tr -d ' ')
case $size in '' | *[!0-9]*) exit 0 ;; esac
[ "$size" -le "$MAX_BYTES" ] || exit 0

# Go/Helm or Jinja template: a line that starts with {{ {% or {# is not YAML until it is rendered
if grep -Eq '^[[:space:]]*\{[{%#]' "$file" 2>/dev/null; then exit 0; fi

dir=$(dirname "$file")

# Helm chart template: <chart>/templates/** next to <chart>/Chart.yaml (subcharts included)
d=$dir
while :; do
  if [ "${d##*/}" = templates ] && [ -f "$(dirname "$d")/Chart.yaml" ]; then exit 0; fi
  parent=$(dirname "$d")
  case $parent in "$d" | .) break ;; esac # at / or at a Windows drive (dirname C: is .)
  d=$parent
done

home=${HOME:-/nonexistent}
if command -v cygpath >/dev/null 2>&1; then home=$(cygpath -m "$home" 2>/dev/null || printf '%s' "$home"); fi

confdir=
d=$dir
while [ -z "$confdir" ]; do
  for n in .yamllint .yamllint.yaml .yamllint.yml; do
    if [ -f "$d/$n" ]; then
      confdir=$d
      label=$d/$n
      break
    fi
  done
  [ -z "$confdir" ] || break
  [ "$d" != "$home" ] || break
  parent=$(dirname "$d")
  case $parent in "$d" | .) break ;; esac # at / or at a Windows drive (dirname C: is .)
  d=$parent
done

if [ -n "$confdir" ]; then
  workdir=$confdir
  if [ "$confdir" = / ]; then rel=${file#/}; else rel=${file#"$confdir"/}; fi
  # --list-files prints nothing for a file the project config ignores
  listed=$(cd -- "$workdir" 2>/dev/null && yamllint --list-files -- "$rel" 2>/dev/null) ||
    cannot_lint --list-files -- "$rel"
  [ -n "$listed" ] || exit 0
  set --
else
  workdir=$dir
  rel=${file##*/}
  if [ -n "${YAMLLINT_CONFIG_FILE:-}" ]; then
    user_config=$YAMLLINT_CONFIG_FILE
  else
    user_config=${XDG_CONFIG_HOME:-$home/.config}/yamllint/config
  fi
  case $user_config in \~/*) user_config=$home/${user_config#\~/} ;; esac
  if [ -f "$user_config" ]; then label=$user_config; else user_config=$default_config; label="plugin default (relaxed)"; fi
  [ -f "$user_config" ] || exit 0
  set -- -c "$user_config"
fi

out=$(cd -- "$workdir" 2>/dev/null && yamllint -f parsable "$@" -- "$rel" 2>/dev/null)
case $? in 0 | 1) ;; *) cannot_lint -f parsable "$@" -- "$rel" ;; esac # 1: problems found
[ -n "$out" ] || exit 0

nerr=$(printf '%s\n' "$out" | grep -c ': \[error\] ')
nwarn=$(printf '%s\n' "$out" | grep -c ': \[warning\] ')
if [ "${YAML_HOOKS_WARNINGS:-}" = 1 ]; then
  shown=$(printf '%s\n' "$out" | grep -E ': \[(error|warning)\] ')
  summary="$nerr error(s), $nwarn warning(s)"
else
  shown=$(printf '%s\n' "$out" | grep ': \[error\] ')
  summary="$nerr error(s)"
  [ "$nwarn" -eq 0 ] || summary="$summary (+$nwarn warning(s) not shown)"
fi
[ -n "$shown" ] || exit 0
total=$(printf '%s\n' "$shown" | wc -l | tr -d ' ')

ctx=$(
  {
    printf 'yamllint: %s in %s (config: %s):\n' "$summary" "$file" "$label"
    printf '%s\n' "$shown" | head -n "$MAX_LINES" | while IFS= read -r line; do
      printf '%s\n' "${line#"$rel":}"
    done
    [ "$total" -le "$MAX_LINES" ] || printf '... and %s more\n' "$((total - MAX_LINES))"
    printf 'Fix the problems your change introduced; leave pre-existing ones elsewhere in the file unless the user asked for them.\n'
  } | json_escape
)
[ -n "$ctx" ] || exit 0
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$ctx"
exit 0
