"""Offline schema check of tests/evals/triggers.yaml against the repo's real skills."""
import importlib.util
import json
import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True  # keep scripts/__pycache__ out of the working tree
sys.path.insert(0, str(ROOT / "scripts"))

spec = importlib.util.spec_from_file_location("eval_triggers", ROOT / "scripts" / "eval-triggers.py")
et = sys.modules.setdefault("eval_triggers", importlib.util.module_from_spec(spec))
if not hasattr(et, "main"):
    spec.loader.exec_module(et)
from skill_descriptions import load_skills  # noqa: E402


def need_pyyaml() -> None:
    """Skips without PyYAML, or fails when SKILL_EXAMPLES_REQUIRE_TOOLS is set to anything but 0 (CI: every
    check must run), like need() in tests/skill_examples."""
    if importlib.util.find_spec("yaml") is None:
        if os.environ.get("SKILL_EXAMPLES_REQUIRE_TOOLS", "") not in ("", "0"):
            pytest.fail("missing tool(s): pyyaml (SKILL_EXAMPLES_REQUIRE_TOOLS is set)")
        pytest.skip("missing tool(s): pyyaml")


@pytest.fixture(scope="module")
def cases_and_index():
    need_pyyaml()
    errors = []
    cases = et.load_cases(ROOT / "tests/evals/triggers.yaml", errors)
    assert not errors, errors
    return cases, et.SkillIndex(load_skills(ROOT))


def test_every_name_is_a_real_model_invocable_skill(cases_and_index):
    # also rejects a bare name that two plugins share ("ambiguous; use plugin:name")
    cases, index = cases_and_index
    assert et.validate_cases(cases, index) == []


def test_shape_of_the_prompt_set(cases_and_index):
    cases, _ = cases_and_index
    assert 35 <= len(cases) <= 60
    negatives = [c for c in cases if c.negative]
    assert len(negatives) >= 8, "keep enough negative controls"
    # every negative control and every positive case names at least one look-alike to keep out
    missing = [c.id for c in cases if not c.forbid]
    assert not missing, f"cases without forbid: {missing}"
    assert all(len(c.prompt) >= 40 for c in cases), "prompts should be realistic, not keywords"


def test_named_skills_come_from_local_marketplace_plugins(cases_and_index):
    """The evals load every local plugin dir (the weekly workflow passes no --plugins/--profile), so a skill
    from a plugins/ dir that the marketplace does not list would be scored although no user installs it."""
    cases, index = cases_and_index
    marketplace = json.loads((ROOT / ".claude-plugin/marketplace.json").read_text(encoding="utf-8"))
    local = {p["name"] for p in marketplace["plugins"] if isinstance(p.get("source"), str)}
    for c in cases:
        for name in [a for g in c.expect for a in g] + c.accept + c.forbid:
            s = index.resolve(name)
            if s is not None:  # unknown names: test_every_name_is_a_real_model_invocable_skill
                assert s.plugin in local, f"{c.id}: {name} is from {s.plugin}, not a local marketplace plugin"
