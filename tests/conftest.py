"""Fixtures for tests/test_script_*.py (scripts/validate.py and scripts/gen-catalog.py).

Each test gets a throwaway copy of the repo layout in tmp_path with the real scripts copied in. Both
scripts derive ROOT from their own location, so they validate and rewrite the copy, never the checkout.
Only plain (non-autouse) fixtures live here, so other suites under tests/ are unaffected.
"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent

SKILL_MD = """---
name: alpha-skill
description: Formats alpha reports. Use when the user asks for an alpha report.
---
# Alpha skill

Explain the report format.
"""

COMMAND_MD = """---
description: Runs the beta check. Use when the user asks to check beta.
---
Run the beta check.
"""


def _env() -> dict:
    env = {k: v for k, v in os.environ.items()
           if k not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_PREFIX")}
    env.update(GIT_AUTHOR_NAME="test", GIT_AUTHOR_EMAIL="test@example.invalid",
               GIT_COMMITTER_NAME="test", GIT_COMMITTER_EMAIL="test@example.invalid",
               PYTHONIOENCODING="utf-8", PYTHONDONTWRITEBYTECODE="1")
    return env


class FakeRepo:
    """A minimal repo layout: marketplace.json, profiles.json, plugins/, SKILLS.md, scripts/."""

    def __init__(self, root: Path):
        self.root = root

    def path(self, rel: str) -> Path:
        return self.root / rel

    def write(self, rel: str, text: str) -> Path:
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
        return p

    def append(self, rel: str, text: str) -> None:
        with (self.root / rel).open("a", encoding="utf-8") as f:
            f.write(text)

    def read(self, rel: str) -> str:
        return (self.root / rel).read_text(encoding="utf-8")

    def write_json(self, rel: str, data) -> None:
        self.write(rel, json.dumps(data, indent=2) + "\n")

    def read_json(self, rel: str):
        return json.loads(self.read(rel))

    def edit_json(self, rel: str, fn) -> None:
        data = self.read_json(rel)
        fn(data)
        self.write_json(rel, data)

    def script(self, name: str, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(self.root / "scripts" / name), *args], cwd=self.root,
                              env=_env(), capture_output=True, text=True, encoding="utf-8")

    def validate(self, *args: str) -> "Result":
        return Result(self.script("validate.py", *args))

    def gen_catalog(self) -> subprocess.CompletedProcess:
        res = self.script("gen-catalog.py")
        assert res.returncode == 0, res.stderr
        return res

    def git(self, *args: str) -> str:
        res = subprocess.run(["git", *args], cwd=self.root, env=_env(), capture_output=True, text=True,
                             encoding="utf-8")
        assert res.returncode == 0, f"git {' '.join(args)}: {res.stderr}"
        return res.stdout

    def commit(self, message: str = "fixture") -> None:
        self.git("add", "-A")
        self.git("commit", "-qm", message)


class Result:
    """validate.py's exit code and its output split by marker."""

    def __init__(self, proc: subprocess.CompletedProcess):
        self.rc = proc.returncode
        self.out = proc.stdout
        self.err = proc.stderr
        lines = proc.stdout.splitlines()
        self.problems = [x[2:] for x in lines if x.startswith("✗ ")]
        self.warnings = [x[2:] for x in lines if x.startswith("⚠ ")]
        self.hits = [x[2:] for x in lines if x.startswith("‼ ")]

    def __repr__(self) -> str:  # shown by pytest when an assert on the result fails
        return f"<validate.py exit {self.rc}\n{self.out}{self.err}>"


def _base_layout(repo: FakeRepo) -> None:
    (repo.root / "scripts").mkdir(parents=True)
    for s in ("validate.py", "gen-catalog.py", "skill_descriptions.py"):
        shutil.copy2(REPO / "scripts" / s, repo.root / "scripts" / s)
    repo.write_json(".claude-plugin/marketplace.json", {
        "name": "fixture", "owner": {"name": "test"},
        "plugins": [
            {"name": "alpha", "source": "./plugins/alpha", "description": "Alpha plugin"},
            {"name": "beta", "source": "./plugins/beta", "description": "Beta plugin"},
        ]})
    repo.write_json("plugins/alpha/.claude-plugin/plugin.json", {"name": "alpha"})
    repo.write("plugins/alpha/skills/alpha-skill/SKILL.md", SKILL_MD)
    repo.write_json("plugins/beta/.claude-plugin/plugin.json", {"name": "beta"})
    repo.write("plugins/beta/commands/check-beta.md", COMMAND_MD)
    repo.write_json("profiles.json", {"profiles": {"core": ["alpha"], "extra": ["beta"]}, "copilotDefault": ["core"]})


@pytest.fixture
def repo(tmp_path: Path) -> FakeRepo:
    """A valid layout with two plugins (a skill, a command), a current SKILLS.md and one git commit."""
    r = FakeRepo(tmp_path / "repo")
    _base_layout(r)
    r.gen_catalog()
    r.git("init", "-q", "-b", "main")
    r.commit("base")
    return r


@pytest.fixture
def bare_layout(tmp_path: Path) -> FakeRepo:
    """Just scripts/ in an empty root, for tests that build their own marketplace (no git)."""
    r = FakeRepo(tmp_path / "repo")
    (r.root / "scripts").mkdir(parents=True)
    for s in ("validate.py", "gen-catalog.py", "skill_descriptions.py"):
        shutil.copy2(REPO / "scripts" / s, r.root / "scripts" / s)
    return r


@pytest.fixture
def known_bug():
    """known_bug(reason): skips a test that documents a bug in a script under test (the test asserts the
    correct behaviour). RUN_KNOWN_BUGS=1 runs it anyway to show the failure. Delete the call with the fix."""
    def skip_unless_requested(reason: str) -> None:
        if not os.environ.get("RUN_KNOWN_BUGS"):
            pytest.skip(f"KNOWN BUG: {reason}")
    return skip_unless_requested
