"""Tests for scripts/test-skill-examples.sh (the per-language checks of SKILL.md code blocks).

Self-contained: no conftest, no network (Pester is never installed from here: SKILL_EXAMPLES_NO_INSTALL=1).
Tests that need a tool (pwsh, Pester 6, shellcheck, yamllint, PyYAML) are skipped when it is missing, unless
SKILL_EXAMPLES_REQUIRE_TOOLS=1 is set (CI), which turns a missing tool into a failure. The two runs of the
repository's real config are skipped unless SKILL_EXAMPLES_REAL_CONFIG=1: scripts/test-skill-examples.sh runs it.
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
from functools import lru_cache
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "test-skill-examples.sh"
MODULE = REPO / "scripts" / "skill-examples" / "skill_examples.py"
REAL_CONFIG = REPO / "tests" / "skill-examples.json"
FIXTURES = Path(__file__).resolve().parent / "fixtures"
REQUIRE_TOOLS = os.environ.get("SKILL_EXAMPLES_REQUIRE_TOOLS", "") not in ("", "0")
BASH = shutil.which("bash") or "/bin/bash"


# ------------------------------------------------------------------------------------------------ helpers

def load_module():
    spec = importlib.util.spec_from_file_location("skill_examples_under_test", MODULE)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    previous, sys.dont_write_bytecode = sys.dont_write_bytecode, True
    try:
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = previous
    return module


def _pwsh_has_pester6(env: dict | None = None) -> bool:
    pwsh = shutil.which("pwsh")
    if not pwsh:
        return False
    probe = ("if (Get-Module -ListAvailable -Name Pester | Where-Object Version -GE ([version] '6.0.0')) "
             "{ exit 0 } else { exit 1 }")
    p = subprocess.run([pwsh, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", probe],
                       env=env, capture_output=True, timeout=120, check=False)
    return p.returncode == 0


@lru_cache(maxsize=None)
def have(tool: str) -> bool:
    if tool == "pyyaml":
        return importlib.util.find_spec("yaml") is not None
    if tool == "pester":
        return _pwsh_has_pester6()
    return shutil.which(tool) is not None


def need(*tools: str) -> None:
    missing = [t for t in tools if not have(t)]
    if missing:
        message = f"missing tool(s): {', '.join(missing)}"
        if REQUIRE_TOOLS:
            pytest.fail(f"{message} (SKILL_EXAMPLES_REQUIRE_TOOLS is set)")
        pytest.skip(message)


def run_script(*args, env: dict | None = None, path: str | None = None, timeout: int = 900) -> tuple[int, str]:
    full = dict(os.environ)
    # CI sets SKILL_EXAMPLES_REQUIRE_TOOLS for this suite; the script under test must not inherit it, nor the
    # host's SHELLCHECK_OPTS (the checker drops it too; a test passes it through `env` to check that).
    for name in ("SKILL_EXAMPLES_ALLOW_MISSING_TOOLS", "SKILL_EXAMPLES_REQUIRE_TOOLS", "TEST_SKILL_EXAMPLES_KEEP",
                 "SHELLCHECK_OPTS"):
        full.pop(name, None)
    full["SKILL_EXAMPLES_NO_INSTALL"] = "1"
    full["PYTHONDONTWRITEBYTECODE"] = "1"
    if path is not None:
        full["PATH"] = path
    full.update(env or {})
    p = subprocess.run([BASH, str(SCRIPT), *map(str, args)], cwd=REPO, env=full, capture_output=True, text=True,
                       timeout=timeout, check=False)
    return p.returncode, p.stdout + p.stderr


def write_skill(directory: Path, blocks: list[tuple[str | None, str, str]], name: str = "SKILL.md") -> Path:
    """blocks: (heading line or None, fence language, code)."""
    parts = ["---", "name: test", "description: test fixture", "---", "", "# Test", ""]
    for heading, lang, code in blocks:
        if heading:
            parts += [heading, ""]
        parts += [f"```{lang}", code.rstrip("\n"), "```", ""]
    path = directory / name
    path.write_text("\n".join(parts), encoding="utf-8")
    return path


def write_config(directory: Path, skills: dict[Path, dict], defaults: dict | None = None) -> Path:
    data: dict = {"skills": {str(p): conf for p, conf in skills.items()}}
    if defaults is not None:
        data["defaults"] = defaults
    path = directory / "config.json"
    path.write_text(json.dumps(data, indent=1), encoding="utf-8")
    return path


def summary(output: str) -> str:
    return output.split("== test-skill-examples summary ==", 1)[-1]


# ---------------------------------------------------------------------------------------------- extraction

def test_extract_blocks_languages_headings_and_fences():
    se = load_module()
    blocks = se.extract_blocks((FIXTURES / "all-languages.md").read_text(encoding="utf-8"))
    got = [(b.index, b.tag, b.lang, b.headings[-1]) for b in blocks]
    assert got == [
        (1, "bash", "bash", "Shell"),
        (2, "sh", "sh", "Shell"),
        (3, "python", "python", "Python"),
        (4, "yaml", "yaml", "YAML"),
        (5, "json", "json", "JSON"),
        (6, "powershell", "powershell", "PowerShell"),
        (7, "csharp", None, "Not tested"),
        (8, "", None, "Not tested"),
        (9, "markdown", None, "Not tested"),
    ]
    assert blocks[3].headings == ["All languages", "Data", "YAML"]
    # The '# a comment' line inside the bash block is not a heading.
    assert blocks[2].headings == ["All languages", "Python"]
    # Content of an indented fence loses the fence's indentation; the line points at the first content line.
    assert blocks[5].text == "$items = @(1, 2, 3)\n$items | ForEach-Object { $_ * 2 }"
    lines = (FIXTURES / "all-languages.md").read_text(encoding="utf-8").splitlines()
    assert lines[blocks[5].line - 1].strip() == "$items = @(1, 2, 3)"
    # A longer fence keeps a shorter inner fence as content.
    assert "```bash" in blocks[8].text and blocks[8].text.endswith("```")


def test_extract_blocks_edge_cases():
    se = load_module()
    text = "\n".join([
        "---", "name: x", "# frontmatter comment, not a heading", "---",
        "## Closing hashes ##",
        "```bash``` is inline code, not a fence",
        "~~~ YAML title=x",
        "a: 1",
        "~~~",
        "```json",
        '{"unclosed": true}',
    ])
    blocks = se.extract_blocks(text)
    assert [(b.tag, b.lang, b.headings, b.text) for b in blocks] == [
        ("yaml", "yaml", ["Closing hashes"], "a: 1"),
        ("json", "json", ["Closing hashes"], '{"unclosed": true}'),
    ]


# ---------------------------------------------------------------------------------------- per language

GOOD = {
    "bash": ("bash", 'name="a b"\nprintf "%s\\n" "$name"\n', ("shellcheck",)),
    "sh": ("sh", 'if [ -n "${HOME:-}" ]; then echo home; fi\n', ("shellcheck",)),
    "python": ("python", "print(sum([1, 2]))\n", ()),
    "yaml": ("yaml", "a: 1\nb: [x, y]\n", ("pyyaml", "yamllint")),
    "json": ("json", '{"a": [1, 2]}\n', ()),
    "powershell": ("powershell", "$x = 1\nif ($x) { 'one' }\n", ("pwsh",)),
}

BROKEN = {
    "bash-syntax": ("bash", "if true; then\n  echo 'no fi'\n", "bash -n: line", ("shellcheck",)),
    "bash-shellcheck": ("bash", 'files="a b"\nls $files\n', "SC2086", ("shellcheck",)),
    "sh-dialect": ("sh", '[[ -n "$HOME" ]] && echo yes\n', "SC3010", ("shellcheck",)),
    "python": ("python", "def broken(:\n    pass\n", "python compile: line", ()),
    "yaml-syntax": ("yaml", "key: [unclosed\n", "yaml parse: line", ("pyyaml", "yamllint")),
    "yaml-yamllint": ("yaml", "a: 1\na: 2\n", "key-duplicates", ("pyyaml", "yamllint")),
    "json": ("json", '{"a": 1,}\n', "json parse: line", ()),
    "powershell-parse": ("powershell", "function Broken {\n    'no closing brace'\n", "PowerShell parser: line",
                         ("pwsh",)),
}


@pytest.mark.parametrize("case", sorted(GOOD))
def test_valid_block_passes_in_enforce_mode(tmp_path, case):
    lang, code, tools = GOOD[case]
    need(*tools)
    skill = write_skill(tmp_path, [("## Good", lang, code)])
    rc, out = run_script("--config", write_config(tmp_path, {skill: {"mode": "enforce"}}))
    assert rc == 0, out
    assert "1 block(s) tested: 1 passed, 0 failed" in summary(out), out
    assert "result: PASS" in out


@pytest.mark.parametrize("case", sorted(BROKEN))
def test_broken_block_fails_in_enforce_mode(tmp_path, case):
    lang, code, marker, tools = BROKEN[case]
    need(*tools)
    skill = write_skill(tmp_path, [("## Broken", lang, code)])
    rc, out = run_script("--config", write_config(tmp_path, {skill: {"mode": "enforce"}}))
    assert rc == 1, out
    text = summary(out)
    assert text.lstrip().startswith("FAIL "), out
    assert marker in text, out
    assert 'block 1 (' in text and 'under "Broken"' in text
    assert "result: FAIL (exit 1)" in out


def test_shellcheck_opts_of_the_host_do_not_change_the_result(tmp_path):
    lang, code, marker, tools = BROKEN["bash-shellcheck"]
    need(*tools)
    skill = write_skill(tmp_path, [("## Broken", lang, code)])
    rc, out = run_script("--config", write_config(tmp_path, {skill: {"mode": "enforce"}}),
                         env={"SHELLCHECK_OPTS": f"-e {marker}"})
    assert rc == 1, out
    assert marker in summary(out), out


@pytest.mark.parametrize("case", sorted(BROKEN))
def test_broken_block_only_warns_in_report_mode(tmp_path, case):
    lang, code, marker, tools = BROKEN[case]
    need(*tools)
    skill = write_skill(tmp_path, [("## Broken", lang, code)])
    rc, out = run_script("--config", write_config(tmp_path, {skill: {"mode": "report"}}))
    assert rc == 0, out
    text = summary(out)
    assert text.lstrip().startswith("WARN "), out
    assert marker in text, out
    assert "result: PASS (exit 0)" in out


def test_problem_line_numbers_point_into_the_skill_file(tmp_path):
    need("shellcheck")
    skill = write_skill(tmp_path, [(None, "bash", "echo ok\nif true; then\n  echo 'no fi'\n")])
    rc, out = run_script("--config", write_config(tmp_path, {skill: {"mode": "enforce"}}))
    assert rc == 1, out
    lines = skill.read_text(encoding="utf-8").splitlines()
    fence = lines.index("```bash") + 1  # 1-based line of the fence
    # bash reports the end of file (line 4 of the block, after the trailing newline) as the error line.
    assert f"bash -n: line {fence + 4}:" in out or f"bash -n: line {fence + 3}:" in out, out


def test_all_languages_fixture_passes(tmp_path):
    need("shellcheck", "pyyaml", "yamllint", "pwsh")
    fixture = FIXTURES / "all-languages.md"
    rc, out = run_script("--config", write_config(tmp_path, {fixture: {"mode": "enforce"}}))
    assert rc == 0, out
    assert "6 block(s) tested: 6 passed, 0 failed; 3 not tested (csharp 1, markdown 1, unlabeled 1)" in out, out
    assert "1 <placeholder>(s) replaced" in out


# ------------------------------------------------------------------------------------------- placeholders

def test_placeholders_are_replaced_unless_disabled(tmp_path):
    need("shellcheck")
    skill = write_skill(tmp_path, [(None, "bash", "helm -n <ns> get values <release>   # deployed values\n")])
    rc, out = run_script("--config", write_config(tmp_path, {skill: {"mode": "enforce"}}))
    assert rc == 0, out
    assert "2 <placeholder>(s) replaced" in out
    rc, out = run_script("--config", write_config(tmp_path, {skill: {"mode": "enforce", "placeholders": False}}))
    assert rc == 1, out
    assert "bash -n" in summary(out)


# ------------------------------------------------------------------------------------------------- skips

def test_skip_by_block_number(tmp_path):
    skill = write_skill(tmp_path, [(None, "json", '{"ok": true}'), (None, "json", '{"broken": }')])
    conf = {"mode": "enforce", "skip": [{"block": 2, "reason": "shows a syntax error on purpose"}]}
    rc, out = run_script("--config", write_config(tmp_path, {skill: conf}))
    assert rc == 0, out
    assert "block 2 (json, line" in out and "skipped (shows a syntax error on purpose)" in out
    assert "1 block(s) tested: 1 passed, 0 failed; 1 skipped by config" in summary(out)


def test_skip_by_heading_covers_subsections(tmp_path):
    skill = write_skill(tmp_path, [
        ("## Valid", "json", '{"ok": true}'),
        ("## Anti-patterns", "json", "{broken"),
        ("### Deeper", "json", "[1, 2,]"),
        ("## Valid again", "json", "[1, 2]"),
    ])
    conf = {"mode": "enforce", "skip": [{"heading": "## Anti-patterns", "reason": "counter-examples"}]}
    rc, out = run_script("--config", write_config(tmp_path, {skill: conf}))
    assert rc == 0, out
    assert out.count("skipped (counter-examples)") == 2, out
    assert "2 block(s) tested: 2 passed, 0 failed; 2 skipped by config" in summary(out)


def test_stale_skip_rule_fails(tmp_path):
    skill = write_skill(tmp_path, [(None, "json", "{}")])
    conf = {"mode": "enforce", "skip": [{"block": 9, "reason": "gone"}, {"heading": "Nowhere", "reason": "gone"}]}
    rc, out = run_script("--config", write_config(tmp_path, {skill: conf}))
    assert rc == 1, out
    assert "skip rule for block 9 matches no block" in out
    assert 'skip rule for heading "Nowhere" matches no block' in out


@pytest.mark.parametrize("bad", [
    {"mode": "enforce", "skip": [{"block": 1}]},
    {"mode": "enforce", "skip": [{"block": 1, "heading": "x", "reason": "both"}]},
    {"mode": "enforce", "shellcheck": {"exclude": ["SC2086"]}},
    {"mode": "enforce", "shellcheck": {"exclude": ["2086x"], "reason": "r"}},
    {"mode": "strict"},
    {"mode": "enforce", "unknown": 1},
    {"mode": "enforce", "powershell": {"runner": "parse", "stubs": "x.ps1"}},
])
def test_invalid_config_is_a_usage_error(tmp_path, bad):
    skill = write_skill(tmp_path, [(None, "json", "{}")])
    rc, out = run_script("--config", write_config(tmp_path, {skill: bad}))
    assert rc == 2, out
    assert "config.json:" in out


def test_invalid_json_config_and_missing_file(tmp_path):
    config = tmp_path / "config.json"
    config.write_text("{", encoding="utf-8")
    rc, out = run_script("--config", config)
    assert rc == 2 and "invalid JSON" in out, out
    rc, out = run_script(tmp_path / "missing.md")
    assert rc == 2 and "no such file" in out, out


# ------------------------------------------------------------------------------------------------ python

def test_python_runs_only_when_runnable(tmp_path):
    skill = write_skill(tmp_path, [(None, "python", "raise SystemExit('boom at runtime')\n")])
    rc, out = run_script("--config", write_config(tmp_path, {skill: {"mode": "enforce"}}))
    assert rc == 0, out
    assert "ok (compile)" in out
    rc, out = run_script("--config", write_config(tmp_path, {skill: {"mode": "enforce", "python": {"runnable": [1]}}}))
    assert rc == 1, out
    assert "python run: exit 1" in out and "boom at runtime" in out


def test_runnable_must_name_a_python_block(tmp_path):
    skill = write_skill(tmp_path, [(None, "json", "{}")])
    rc, out = run_script("--config", write_config(tmp_path, {skill: {"mode": "enforce", "python": {"runnable": [1]}}}))
    assert rc == 1, out
    assert "python.runnable lists block 1, which is not a python block" in out


# ------------------------------------------------------------------------------------------ missing tools

def _path_without_linters(tmp_path: Path) -> str:
    """A PATH with bash, sh and python3 only (no shellcheck, yamllint, pwsh)."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name, target in (("bash", BASH), ("sh", shutil.which("sh")), ("python3", sys.executable)):
        if target:
            (bin_dir / name).symlink_to(target)
    return str(bin_dir)


@pytest.mark.parametrize("lang, code, tool", [
    ("bash", "echo ok\n", "shellcheck"),
    ("yaml", "a: 1\n", "yamllint"),
    ("powershell", "'ok'\n", "pwsh"),
])
def test_missing_tool_is_an_error_in_enforce_mode(tmp_path, lang, code, tool):
    skill = write_skill(tmp_path, [(None, lang, code)])
    path = _path_without_linters(tmp_path)
    rc, out = run_script("--config", write_config(tmp_path, {skill: {"mode": "enforce"}}), path=path)
    assert rc == 2, out
    assert f"MISSING TOOL: {tool}" in out and "result: ERROR (exit 2)" in out, out

    rc, out = run_script("--config", write_config(tmp_path, {skill: {"mode": "enforce"}}), path=path,
                         env={"SKILL_EXAMPLES_ALLOW_MISSING_TOOLS": "1"})
    assert rc == 0, out
    assert summary(out).lstrip().startswith("WARN "), out

    rc, out = run_script("--config", write_config(tmp_path, {skill: {"mode": "report"}}), path=path)
    assert rc == 0, out
    assert summary(out).lstrip().startswith("WARN "), out


def test_require_tools_makes_a_missing_tool_fatal_in_report_mode(tmp_path):
    skill = write_skill(tmp_path, [(None, "bash", "echo ok\n")])
    config = write_config(tmp_path, {skill: {"mode": "report"}})
    env = {"SKILL_EXAMPLES_REQUIRE_TOOLS": "1", "SKILL_EXAMPLES_ALLOW_MISSING_TOOLS": "1"}
    rc, out = run_script("--config", config, path=_path_without_linters(tmp_path), env=env)
    assert rc == 2, out
    assert "MISSING TOOL: shellcheck (an error because SKILL_EXAMPLES_REQUIRE_TOOLS is set)" in out, out


def test_missing_python3_in_wrapper(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    rc, out = run_script("--help", path=str(bin_dir))
    assert rc == 2 and "python3" in out, out


# --------------------------------------------------------------------------------------------------- Pester

def _pester_skill(tmp_path: Path, code: str, **powershell) -> tuple[Path, Path]:
    skill = write_skill(tmp_path, [("## Tests", "powershell", code)])
    conf = {"mode": "enforce", "powershell": {"runner": "pester", **powershell}}
    return skill, write_config(tmp_path, {skill: conf})


def test_pester_runner_passes_and_checks_required_tests(tmp_path):
    need("pwsh", "pester")
    code = "Describe 'math' {\n    It 'adds <a>' -ForEach @(@{ a = 1 }) { $a + 1 | Should -Be 2 }\n}\n"
    _, config = _pester_skill(tmp_path, code, required_passing=["adds 1"])
    rc, out = run_script("--config", config)
    assert rc == 0, out
    assert "pester: 1 passed, 0 failed" in out

    _, config = _pester_skill(tmp_path, code, required_passing=["adds 2"])
    rc, out = run_script("--config", config)
    assert rc == 1, out
    assert "expected a passing test named 'adds 2'" in out


def test_pester_runner_failing_test_fails_enforce_and_warns_report(tmp_path):
    need("pwsh", "pester")
    skill, config = _pester_skill(tmp_path, "Describe 'd' {\n    It 'is wrong' { 1 | Should -Be 2 }\n}\n")
    rc, out = run_script("--config", config)
    assert rc == 1, out
    assert "test 'd.is wrong' (block 1, SKILL.md line" in out, out
    assert "1 block(s) tested: 0 passed, 1 failed" in out

    conf = json.loads(config.read_text(encoding="utf-8"))
    conf["skills"][str(skill)]["mode"] = "report"
    config.write_text(json.dumps(conf), encoding="utf-8")
    rc, out = run_script("--config", config)
    assert rc == 0, out
    assert summary(out).lstrip().startswith("WARN "), out


def test_pester_runner_skips_need_an_allowed_skip(tmp_path):
    need("pwsh", "pester")
    code = "It 'skipped always' -Skip { }\nIt 'runs' { $true | Should -BeTrue }\n"
    _, config = _pester_skill(tmp_path, code)
    rc, out = run_script("--config", config)
    assert rc == 1 and "unexpected skip" in out, out
    _, config = _pester_skill(tmp_path, code, allowed_skips=[{"test": "skipped always", "when": "always", "reason": "demo"}])
    rc, out = run_script("--config", config)
    assert rc == 0, out
    assert "skipped as expected" in out and "(demo)" in out


def test_pester_runner_uses_stubs_and_fixtures(tmp_path):
    need("pwsh", "pester")
    stubs = tmp_path / "stubs.ps1"
    stubs.write_text("function global:Get-Answer { 42 }\n", encoding="utf-8")
    fixtures = tmp_path / "fixtures"
    fixtures.mkdir()
    (fixtures / "data.json").write_text('{"value": 7}', encoding="utf-8")
    code = ("Describe 'd' {\n"
            "    It 'uses the stub' { Get-Answer | Should -Be 42 }\n"
            "    It 'reads the fixture' { (Get-Content \"$PSScriptRoot/data.json\" | ConvertFrom-Json).value | Should -Be 7 }\n"
            "}\n")
    _, config = _pester_skill(tmp_path, code, stubs=str(stubs), fixtures=str(fixtures))
    rc, out = run_script("--config", config)
    assert rc == 0, out
    assert "pester: 2 passed, 0 failed" in out


def test_missing_pester_is_a_missing_tool(tmp_path):
    need("pwsh")
    home = tmp_path / "home"
    home.mkdir()
    env = {"HOME": str(home), "XDG_DATA_HOME": str(home / ".local/share"), "XDG_CONFIG_HOME": str(home / ".config"),
           "XDG_CACHE_HOME": str(home / ".cache"), "PSModulePath": ""}
    probe_env = {**os.environ, **env}
    if _pwsh_has_pester6(probe_env):
        pytest.skip("Pester 6 is installed for all users, so it cannot be hidden")
    _, config = _pester_skill(tmp_path, "Describe 'd' { It 'x' { } }\n")
    rc, out = run_script("--config", config, env=env)
    assert rc == 2, out
    assert "MISSING TOOL: Pester 6" in out and "SKILL_EXAMPLES_NO_INSTALL" in out, out


# ------------------------------------------------------------------------------------------ command line

def test_help():
    rc, out = run_script("--help")
    assert rc == 0 and "usage: test-skill-examples.sh" in out and "SKILL_EXAMPLES_ALLOW_MISSING_TOOLS" in out
    rc, out = run_script("--bogus")
    assert rc == 2, out


def test_file_not_in_config_uses_enforce_defaults(tmp_path):
    listed = write_skill(tmp_path, [(None, "json", "{}")], name="listed.md")
    other = write_skill(tmp_path, [(None, "json", "{broken")], name="other.md")
    rc, out = run_script("--config", write_config(tmp_path, {listed: {"mode": "report"}}), other)
    assert rc == 1, out
    assert "(enforce, not in the config)" in summary(out)
    assert "listed.md" not in out


def test_keep_prints_the_work_directory(tmp_path):
    skill = write_skill(tmp_path, [(None, "json", "{}")])
    rc, out = run_script("--config", write_config(tmp_path, {skill: {"mode": "enforce"}}),
                         env={"TEST_SKILL_EXAMPLES_KEEP": "1"})
    assert rc == 0, out
    kept = Path(out.split("kept the generated files in ", 1)[1].split()[0])
    try:
        assert kept.is_dir()
    finally:
        shutil.rmtree(kept, ignore_errors=True)


# ------------------------------------------------------------------------------- the repository's config

def _classify(skill: str, sources: dict) -> str:
    """'repo' (repo-owned), 'patched' (vendored, with a patch that touches this file) or 'vendored'."""
    for source in sources["sources"]:
        for copy in source.get("copy", []):
            to = copy["to"].rstrip("/")
            if skill == to or skill.startswith(to + "/"):
                patch = copy.get("patch")
                if patch and f"+++ b/{skill}" in (REPO / patch).read_text(encoding="utf-8"):
                    return "patched"
                return "vendored"
    return "repo"


def test_repo_config_modes_follow_the_vendoring_rules():
    se = load_module()
    _, configured = se.load_config(REAL_CONFIG)
    sources = json.loads((REPO / "sources.json").read_text(encoding="utf-8"))
    for path, (key, conf) in configured.items():
        assert path.is_file(), f"{key}: no such file"
        kind = _classify(key, sources)
        expected = "report" if kind == "vendored" else "enforce"
        assert conf["mode"] == expected, f"{key} is {kind}: its mode must be {expected}"
    # Every repo-controlled skill with a testable block is in the config, in enforce mode.
    for skill in sorted(REPO.glob("plugins/**/SKILL.md")):
        rel = skill.relative_to(REPO).as_posix()
        if _classify(rel, sources) == "vendored":
            continue
        if any(b.lang for b in se.extract_blocks(skill.read_text(encoding="utf-8"))):
            assert skill.resolve() in configured, f"{rel} is repo-controlled and has code blocks: add it to {REAL_CONFIG.name}"


def real_config_opt_in() -> None:
    """The real config runs in scripts/test-skill-examples.sh (CI's "Skill examples" step, right after
    run-tests.sh); running it here too would report one broken example twice."""
    if os.environ.get("SKILL_EXAMPLES_REAL_CONFIG", "") in ("", "0"):
        pytest.skip("the real config runs in scripts/test-skill-examples.sh; SKILL_EXAMPLES_REAL_CONFIG=1 runs it here")


def test_repo_config_passes():
    real_config_opt_in()
    need("pwsh", "pester", "shellcheck", "pyyaml", "yamllint")
    rc, out = run_script()
    assert rc == 0, out
    text = summary(out)
    se = load_module()
    _, configured = se.load_config(REAL_CONFIG)
    for _, (key, conf) in configured.items():
        if conf["mode"] == "enforce":
            assert f"PASS  {key} (enforce)" in text, out
    assert "result: PASS (exit 0)" in out


def test_pester_skill_path_argument_still_works():
    real_config_opt_in()
    need("pwsh", "pester")
    rc, out = run_script("plugins/powershell/skills/pester/SKILL.md")
    assert rc == 0, out
    assert "PASS  plugins/powershell/skills/pester/SKILL.md (enforce)" in out
    assert "skipped as expected" in out
