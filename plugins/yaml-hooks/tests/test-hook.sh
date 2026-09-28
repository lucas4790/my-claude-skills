#!/bin/sh
# Self-contained test for scripts/yamllint-hook.sh: feeds PostToolUse JSON on stdin and checks what the
# hook prints. No network. The lint cases need yamllint on PATH and are skipped (with a notice) without it.
# Usage: sh plugins/yaml-hooks/tests/test-hook.sh        HOOK_SHELL=bash runs the hook under bash instead of sh

here=$(cd "$(dirname "$0")" && pwd)
hook=$here/../scripts/yamllint-hook.sh
hook_sh=$(command -v "${HOOK_SHELL:-sh}") || { echo "error: ${HOOK_SHELL:-sh} not found" >&2; exit 1; }
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' INT TERM
cd "$tmp" || exit 1

# isolate from the caller's yamllint configuration (HOME stays: a pip --user yamllint needs it)
unset YAMLLINT_CONFIG_FILE YAML_HOOKS_WARNINGS
XDG_CONFIG_HOME=$tmp/xdg
export XDG_CONFIG_HOME

pass=0
fail=0
skip=0
have_yamllint=no
command -v yamllint >/dev/null 2>&1 && have_yamllint=yes
have_python=no
command -v python3 >/dev/null 2>&1 && have_python=yes

ok() { pass=$((pass + 1)); echo "ok   - $1"; }
not_ok() { fail=$((fail + 1)); echo "FAIL - $1"; [ -z "${2:-}" ] || printf '       %s\n' "$2"; }

# payload TOOL FILE: a PostToolUse event whose content mentions another file_path, which must not be picked
payload() {
  printf '{"session_id":"t","transcript_path":"/dev/null","cwd":"%s","permission_mode":"default",' "$tmp"
  printf '"hook_event_name":"PostToolUse","tool_name":"%s","tool_input":{"content":' "$1"
  printf '"x: \\"file_path\\": \\"%s/decoy.yaml\\"\\n","file_path":"%s"},' "$tmp" "$2"
  printf '"tool_response":{"filePath":"%s","type":"update"},"tool_use_id":"toolu_1"}' "$2"
}

# run_hook NAME [VAR=value ...]: runs the hook with $tmp/in on stdin and the extra environment; sets
# $out and fails NAME unless the hook exits 0
run_hook() {
  name=$1
  shift
  out=$(env "$@" "$hook_sh" "$hook" <"$tmp/in")
  rc=$?
  [ "$rc" -eq 0 ] || not_ok "$name: exit code $rc (want 0)"
  return "$rc"
}

# check_silent NAME / check_report NAME TEXT: $out must be empty / valid hook JSON containing TEXT
check_silent() {
  if [ -z "$out" ]; then ok "$1"; else not_ok "$1: expected no output" "$out"; fi
}
check_report() {
  if [ -z "$out" ]; then not_ok "$1: expected a report, got nothing"; return; fi
  case $out in
    *"$2"*) ;;
    *) not_ok "$1: report lacks '$2'" "$out"; return ;;
  esac
  if [ "$have_python" = yes ] && ! printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)["hookSpecificOutput"]
assert d["hookEventName"] == "PostToolUse" and d["additionalContext"].startswith("yamllint: ")' 2>/dev/null; then
    not_ok "$1: output is not valid PostToolUse hook JSON" "$out"
    return
  fi
  ok "$1"
}

# expect_silent NAME TOOL FILE [VAR=value ...] / expect_report NAME TEXT TOOL FILE [VAR=value ...]
expect_silent() {
  n=$1 t=$2 f=$3
  shift 3
  payload "$t" "$f" >"$tmp/in"
  run_hook "$n" "$@" && check_silent "$n"
}
expect_report() {
  n=$1 x=$2 t=$3 f=$4
  shift 4
  payload "$t" "$f" >"$tmp/in"
  run_hook "$n" "$@" && check_report "$n" "$x"
}

# raw TEXT: writes TEXT as the hook input
raw() { printf '%s' "$1" >"$tmp/in"; }

needs_yamllint() {
  [ "$have_yamllint" = yes ] && return 0
  skip=$((skip + 1))
  echo "skip - $1 (yamllint not installed)"
  return 1
}

# --- fixtures -------------------------------------------------------------------------------
w=$tmp/work
mkdir -p "$w/chart/templates" "$w/chart/charts/sub/templates" "$w/lib/templates" "$w/.github/workflows" \
  "$w/proj/k8s" "$w/proj/ignored" "$w/with space" "$w/rel"
printf 'name: web\nitems:\n  - a\n  - b\n' >"$w/valid.yaml"
printf 'a: 1\n  b: 2\n' >"$w/bad.yaml"
cp "$w/bad.yaml" "$tmp/decoy.yaml"
printf 'a: 1\nb: 2\na: 3\n' >"$w/dupe.yml"
printf 'apiVersion: v2\nname: demo\nversion: 0.1.0\n' >"$w/chart/Chart.yaml"
printf 'metadata:\n  labels:\n    {{- include "demo.labels" . | nindent 4 }}\n' >"$w/chart/templates/deploy.yaml"
printf 'a: 1\n  b: 2\n' >"$w/chart/templates/plain-bad.yaml"
cp "$w/chart/Chart.yaml" "$w/chart/charts/sub/Chart.yaml"
printf 'a: 1\n  b: 2\n' >"$w/chart/charts/sub/templates/x.yaml"
printf 'a: 1\n  b: 2\n' >"$w/lib/templates/no-chart.yaml"
printf 'kind: List\nitems:\n{{- range .Values.items }}\n  - {{ . }}\n{{- end }}\n' >"$w/helmfile-like.yaml"
long=$(printf '%0120d' 0)
cat >"$w/.github/workflows/ci.yml" <<EOF
name: ci
on:
  push:
    branches: [ main ]
jobs:
  build:
    if: \${{ github.event_name == 'push' }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "\${{ github.sha }} $long"
        continue-on-error: yes
EOF
printf '{"a": [1, 2' >"$w/not-yaml.json"
printf 'a: 1   \nb: 2\n' >"$w/warn-only.yaml"
printf 'a: 1\n  b: 2\n' >"$w/with space/bad.yaml"
printf 'a: 1\n  b: 2\n' >"$w/rel/bad.yaml"
mkdir -p "$tmp/C:/work" # a Windows drive path is relative on POSIX: the hook runs from $tmp, so it resolves
printf 'a: 1\n  b: 2\n' >"$tmp/C:/work/bad.yaml"
i=0
: >"$w/many.yaml"
while [ "$i" -lt 30 ]; do printf 'k%s: 1\nk%s: 2\n' "$i" "$i" >>"$w/many.yaml"; i=$((i + 1)); done
printf 'extends: default\nrules:\n  document-start:\n    present: true\n    level: error\nignore: |\n  ignored/\n' \
  >"$w/proj/.yamllint"
printf 'name: web\n' >"$w/proj/k8s/no-doc-start.yaml"
printf 'a: 1\n  b: 2\n' >"$w/proj/ignored/bad.yaml"
printf 'description: longer than ten characters\n' >"$w/longline.yaml"
printf 'extends: default\nrules:\n  line-length:\n    max: 10\n' >"$tmp/user-yamllint.yaml"

# --- cases that need no yamllint --------------------------------------------------------------
expect_silent "non-YAML file is ignored" Write "$w/not-yaml.json"
expect_silent "missing file is ignored" Write "$w/gone.yaml"
expect_silent "Read tool is ignored" Read "$w/bad.yaml"
raw ""
run_hook "empty stdin" && check_silent "empty stdin"
raw "not json at all"
run_hook "garbage stdin" && check_silent "garbage stdin"
raw '{"tool_name":"Write","tool_input":{"file_path":"C:\\Users\\me\\x.yaml"}}'
run_hook "Windows path" && check_silent "Windows path (absent here) exits 0 quietly"

nobin=$tmp/nobin
mkdir -p "$nobin"
for t in cat tr grep head sed dirname wc; do
  p=$(command -v "$t") && ln -s "$p" "$nobin/$t"
done
payload Write "$w/bad.yaml" >"$tmp/in"
run_hook "yamllint missing" PATH="$nobin" && check_silent "yamllint missing: exit 0, no output"

# --- lint cases -------------------------------------------------------------------------------
if needs_yamllint "lint cases"; then
  expect_silent "valid YAML: no output" Write "$w/valid.yaml"
  expect_report "syntax error is reported" "syntax error" Write "$w/bad.yaml"
  expect_report "Edit tool is linted too" "syntax error" Edit "$w/bad.yaml"
  expect_report "duplicate key is reported" "(key-duplicates)" Write "$w/dupe.yml"
  expect_report "report names the plugin default config" "plugin default (relaxed)" Write "$w/bad.yaml"
  expect_silent "Helm template under chart/templates is skipped" Write "$w/chart/templates/deploy.yaml"
  expect_silent "invalid file under chart/templates is skipped" Write "$w/chart/templates/plain-bad.yaml"
  expect_silent "subchart template is skipped" Write "$w/chart/charts/sub/templates/x.yaml"
  expect_report "templates/ without Chart.yaml is linted" "syntax error" Write "$w/lib/templates/no-chart.yaml"
  expect_silent "file with line-start {{ template actions is skipped" Write "$w/helmfile-like.yaml"
  expect_silent "GitHub workflow (on:, \${{ }}, yes, long line) passes the default config" Write "$w/.github/workflows/ci.yml"
  expect_silent "warnings only: no output by default" Write "$w/warn-only.yaml"
  expect_report "YAML_HOOKS_WARNINGS=1 lists warnings" "(trailing-spaces)" Write "$w/warn-only.yaml" YAML_HOOKS_WARNINGS=1
  expect_report "path with a space" "syntax error" Write "$w/with space/bad.yaml"
  expect_report "project .yamllint is used" "(document-start)" Write "$w/proj/k8s/no-doc-start.yaml"
  expect_report "report names the project config" "$w/proj/.yamllint" Write "$w/proj/k8s/no-doc-start.yaml"
  expect_silent "file ignored by the project config is skipped" Write "$w/proj/ignored/bad.yaml"
  expect_silent "a 40-character line passes the default config" Write "$w/longline.yaml"
  expect_report "YAMLLINT_CONFIG_FILE is used when the project has no config" "(line-length)" Write "$w/longline.yaml" \
    YAMLLINT_CONFIG_FILE="$tmp/user-yamllint.yaml"
  expect_report "long reports are cut at 20 lines" "... and 10 more" Write "$w/many.yaml"
  raw "{\"cwd\":\"$w\",\"tool_name\":\"edit\",\"tool_input\":{\"path\":\"rel/bad.yaml\"}}"
  run_hook "relative path" && check_report "relative path (path key) resolved against cwd" "syntax error"
  raw '{"tool_name":"Write","tool_input":{"file_path":"C:\\work\\bad.yaml"}}'
  run_hook "Windows drive path" && check_report "Windows drive path with backslashes is linted" "in C:/work/bad.yaml"
fi

echo "yaml-hooks hook test: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
