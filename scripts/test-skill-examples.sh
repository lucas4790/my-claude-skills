#!/usr/bin/env bash
# Tests the fenced code blocks ("examples") of SKILL.md files, per language of the fence:
#   powershell, pwsh, ps1   parsed with the PowerShell parser; or, for skills whose powershell runner is 'pester',
#                           run as Pester 6 tests (see scripts/skill-examples/pester-driver.ps1 for the transforms)
#   bash, shell / sh        bash -n / sh -n, then shellcheck (dialect from the fence or a #! line)
#   (`<name>` placeholders in shell and parsed PowerShell blocks become a plain word first, unless the skill sets
#   "placeholders": false)
#   python, py              compiled; run with python3 only when the config lists the block as runnable
#   yaml, yml               parsed with PyYAML (every document), then yamllint (scripts/skill-examples/yamllint.yaml)
#   json                    parsed
#   anything else           not tested (counted in the summary)
#
#   test-skill-examples.sh                  every skill in tests/skill-examples.json
#   test-skill-examples.sh SKILL.md ...     only these files; a file that is not in the config is tested in
#                                           enforce mode with the defaults (static checks only, nothing runs)
#   test-skill-examples.sh --config FILE    use another configuration file
#
# tests/skill-examples.json sets per skill a mode, blocks to skip (by number or heading, each with a reason), the
# excluded shellcheck codes, runnable python blocks, and the Pester runner with its stubs, fixtures and expectations.
# Mode enforce: any failure fails the run. Mode report: failures are printed as warnings and never change the exit
# status. Repo-controlled skills (repo-owned, or vendored with a patch in patches/) are enforce; vendored skills
# without a patch are report, since their fixes go through patches/, never through edits.
#
# The examples are executed (Pester runner, runnable python blocks): only run this on SKILL.md files you trust.
# The CI sync job runs it as a throwaway user on a copy of the tree.
#
# Exit status: 0 every enforce-mode skill passed; 1 an enforce-mode example failed (or the config no longer matches
# the file, e.g. a skip rule matches no block); 2 usage, configuration or environment error, including a tool an
# enforce-mode skill needs (pwsh, Pester 6, shellcheck, yamllint, PyYAML) being missing.
# Environment:
#   SKILL_EXAMPLES_ALLOW_MISSING_TOOLS=1  a missing tool is a warning instead of exit 2 (local use; never in CI)
#   SKILL_EXAMPLES_REQUIRE_TOOLS=1        a missing tool is exit 2 for report-mode skills too (CI); wins over ALLOW
#   SKILL_EXAMPLES_NO_INSTALL=1           never install Pester 6 from the PowerShell Gallery (no network)
#   TEST_SKILL_EXAMPLES_KEEP=1            keep the generated files and print where they are
set -euo pipefail

# Parameter expansion rather than dirname: the script must work with nothing but bash and python3 on PATH.
case ${BASH_SOURCE[0]} in
  */*) here=${BASH_SOURCE[0]%/*} ;;
  *) here=. ;;
esac
if ! command -v python3 >/dev/null 2>&1; then
  echo "test-skill-examples: python3 (3.10 or newer) is required but was not found on PATH." >&2
  exit 2
fi
exec python3 "$here/skill-examples/skill_examples.py" "$@"
