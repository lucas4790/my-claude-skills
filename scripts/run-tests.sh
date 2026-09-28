#!/usr/bin/env bash
# Runs the repo's own test suites and prints a summary per suite.
#
#   run-tests.sh               everything
#   run-tests.sh bats pytest   only the named kinds (one or both)
#
# bats:   tests/bats/*.bats: sync.sh (copies, filters, --locked, failures, patches), update-plugins.sh,
#         bump-pinned.sh, and static checks of the installers and scripts (bash -n, shellcheck, and a
#         PowerShell parse check when pwsh is on PATH or PWSH=/path/to/pwsh is set).
# pytest: python3 -m pytest tests/: validate.py, gen-catalog.py and every other pytest suite under tests/.
#
# Needs bats-core >= 1.4, python3 with pytest, git, rsync and jq. Without shellcheck or pwsh those
# checks are skipped (and shown as skipped). No network access; every fixture lives in a temp dir.
# RUN_KNOWN_BUGS=1 also runs the tests that document open bugs in the scripts (they fail until fixed).
# Exit status: 0 all passed, 1 a test failed, 2 usage error or a required tool is missing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

run_bats=0 run_pytest=0
for arg in "$@"; do
  case "$arg" in
    bats) run_bats=1 ;;
    pytest) run_pytest=1 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "run-tests: unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done
[ "$#" -gt 0 ] || { run_bats=1; run_pytest=1; }

# --- prerequisites: fail loudly instead of silently skipping a suite ------------------------------
missing=()
for tool in git rsync jq python3; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "$run_bats" = 1 ]; then
  if ! command -v bats >/dev/null 2>&1; then
    missing+=("bats (bats-core >= 1.4: apt install bats | brew install bats-core | npm install -g bats)")
  else
    bats_version=$(bats --version | awk '{print $2}')
    if [ "$(printf '%s\n1.4.0\n' "$bats_version" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" != 1.4.0 ]; then
      missing+=("bats-core >= 1.4 (found $bats_version)")
    fi
  fi
fi
if [ "$run_pytest" = 1 ] && ! python3 -c 'import pytest' >/dev/null 2>&1; then
  missing+=("pytest for python3 (apt install python3-pytest | python3 -m pip install pytest)")
fi
if [ "${#missing[@]}" -gt 0 ]; then
  printf 'run-tests: missing required tool: %s\n' "${missing[@]}" >&2
  exit 2
fi
for tool in shellcheck pwsh; do
  if ! command -v "$tool" >/dev/null 2>&1 && ! { [ "$tool" = pwsh ] && [ -n "${PWSH:-}" ]; }; then
    echo "run-tests: note: $tool not found; its checks are skipped"
  fi
done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/run-tests.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT
export PYTHONDONTWRITEBYTECODE=1  # no __pycache__ in tests/ or scripts/

summary=()  # "label<TAB>passed<TAB>failed<TAB>skipped"
failed_suites=()

# --- bats: one run per file, so the summary has a line per suite ------------------------------------
if [ "$run_bats" = 1 ]; then
  for f in tests/bats/*.bats; do
    name=$(basename "$f")
    echo "=== bats $name"
    bats --tap "$f" | tee "$tmp/$name.tap"
    rc=${PIPESTATUS[0]}
    skipped=$(grep -c '^ok .* # skip' "$tmp/$name.tap")
    passed=$(( $(grep -c '^ok ' "$tmp/$name.tap") - skipped ))
    failed=$(grep -c '^not ok ' "$tmp/$name.tap")
    summary+=("bats   $name"$'\t'"$passed"$'\t'"$failed"$'\t'"$skipped")
    if [ "$rc" -ne 0 ] || [ "$failed" -gt 0 ]; then failed_suites+=("bats $name"); fi
  done
fi

# --- pytest: one run over tests/ (other suites there included), counted per file -------------------
if [ "$run_pytest" = 1 ]; then
  echo "=== pytest tests/"
  python3 -m pytest -q -rs -p no:cacheprovider --rootdir="$ROOT" --junitxml="$tmp/pytest.xml" tests/
  rc=$?
  if [ -f "$tmp/pytest.xml" ]; then
    while IFS= read -r line; do summary+=("$line"); done < <(python3 - "$tmp/pytest.xml" <<'PY'
import collections, sys, xml.etree.ElementTree as ET
counts = collections.OrderedDict()
for tc in ET.parse(sys.argv[1]).getroot().iter("testcase"):
    # a module skipped or broken at collection has no classname; its name is the module path
    parts = (tc.get("classname") or tc.get("name", "")).split(".")
    # tests.skill_examples.test_x.TestY -> tests/skill_examples/test_x.py (the module, not the class)
    start = 1 if parts[0] == "tests" else 0
    i = next((k for k in range(start, len(parts)) if parts[k].startswith("test") or parts[k].endswith("_test")),
             len(parts) - 1)
    label = "/".join(parts[: i + 1]) + ".py"
    c = counts.setdefault(label, [0, 0, 0])
    kinds = {child.tag for child in tc}
    c[1 if kinds & {"failure", "error"} else 2 if "skipped" in kinds else 0] += 1
for label, (p, f, s) in counts.items():
    print(f"pytest {label}\t{p}\t{f}\t{s}")
PY
    )
  fi
  if [ "$rc" -ne 0 ]; then failed_suites+=("pytest (exit $rc)"); fi
fi

# --- summary -------------------------------------------------------------------------------------------
echo
echo "=== summary"
total_p=0 total_f=0 total_s=0
printf '%-60s %7s %7s %8s\n' "suite" passed failed skipped
for row in "${summary[@]}"; do
  IFS=$'\t' read -r label p f s <<<"$row"
  printf '%-60s %7s %7s %8s\n' "$label" "$p" "$f" "$s"
  total_p=$((total_p + p)) total_f=$((total_f + f)) total_s=$((total_s + s))
done
printf '%-60s %7s %7s %8s\n' "total" "$total_p" "$total_f" "$total_s"

if [ "${#failed_suites[@]}" -gt 0 ]; then
  printf 'run-tests: FAILED: %s\n' "${failed_suites[*]}" >&2
  exit 1
fi
echo "run-tests: all suites passed"
