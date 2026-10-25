"""scripts/reviewed-hooks.json against the checkout.

validate.py compares a hook file with its pinned sha256 only in --diff mode on pull requests. This runs the same
comparison on the whole repository, so a hook edited on a branch without a PR (or merged by hand) still fails
here until the owner has reviewed it and updated the hash. Never update an entry just to make this pass: the
entry is the owner's statement that they read the file.
"""
import hashlib
import json
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
REVIEWED = json.loads((ROOT / "scripts" / "reviewed-hooks.json").read_text(encoding="utf-8"))["reviewed"]
SOURCES = json.loads((ROOT / "sources.json").read_text(encoding="utf-8"))["sources"]
VENDORED = [c["to"].rstrip("/") for s in SOURCES for c in s.get("copy", [])]
PLUGIN_ROOT_REF = re.compile(r"\$\{CLAUDE_PLUGIN_ROOT\}/([^\s\"'\\;&|)]+)")


def sha256(rel: str) -> str:
    return hashlib.sha256((ROOT / rel).read_bytes().replace(b"\r\n", b"\n")).hexdigest()


def is_vendored(rel: str) -> bool:
    return any(rel == v or rel.startswith(v + "/") for v in VENDORED)


def plugin_dir(rel: str) -> str:
    return "/".join(rel.split("/")[:2])


def repo_owned_hook_registrations() -> list[str]:
    found = []
    for path in sorted((ROOT / "plugins").glob("*/hooks/*.json")):
        rel = path.relative_to(ROOT).as_posix()
        if not is_vendored(rel) and not is_vendored(plugin_dir(rel)):
            found.append(rel)
    return found


def test_there_is_something_to_check():
    assert REVIEWED, "scripts/reviewed-hooks.json lists no hook; this test would check nothing"


@pytest.mark.parametrize("rel", sorted(REVIEWED))
def test_listed_file_exists_under_plugins_and_matches_its_hash(rel):
    assert rel.startswith("plugins/"), f"{rel} is not under plugins/"
    assert (ROOT / rel).is_file(), f"{rel} is listed but does not exist; remove the entry"
    assert sha256(rel) == REVIEWED[rel], (
        f"{rel} changed since the owner reviewed it. After reviewing the change, set its hash in "
        f"scripts/reviewed-hooks.json to {sha256(rel)}"
    )


@pytest.mark.parametrize("rel", repo_owned_hook_registrations() or ["<none>"])
def test_every_repo_owned_hook_registration_is_reviewed(rel):
    if rel == "<none>":
        pytest.skip("no repo-owned plugin registers hooks")
    assert rel in REVIEWED, f"{rel} registers hooks but is not in scripts/reviewed-hooks.json"


@pytest.mark.parametrize("hook", sorted(r for r in REVIEWED if r.endswith(".json")))
def test_scripts_a_reviewed_hook_runs_are_reviewed_too(hook):
    text = (ROOT / hook).read_text(encoding="utf-8")
    for ref in PLUGIN_ROOT_REF.findall(text):
        script = f"{plugin_dir(hook)}/{ref}"
        assert script in REVIEWED, f"{hook} runs {script}, which is not listed in scripts/reviewed-hooks.json"
