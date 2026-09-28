"""Offline schema check of tests/evals/triggers.yaml against the repo's real skills."""
import importlib.util
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True  # keep scripts/__pycache__ out of the working tree
sys.path.insert(0, str(ROOT / "scripts"))
yaml = pytest.importorskip("yaml")

spec = importlib.util.spec_from_file_location("eval_triggers", ROOT / "scripts" / "eval-triggers.py")
et = sys.modules.setdefault("eval_triggers", importlib.util.module_from_spec(spec))
if not hasattr(et, "main"):
    spec.loader.exec_module(et)
from skill_descriptions import load_skills  # noqa: E402


@pytest.fixture(scope="module")
def cases_and_index():
    errors = []
    cases = et.load_cases(ROOT / "tests/evals/triggers.yaml", errors)
    assert not errors, errors
    return cases, et.SkillIndex(load_skills(ROOT))


def test_every_name_is_a_real_model_invocable_skill(cases_and_index):
    cases, index = cases_and_index
    assert et.validate_cases(cases, index) == []


def test_bare_names_are_unambiguous(cases_and_index):
    cases, index = cases_and_index
    for c in cases:
        for name in [a for g in c.expect for a in g] + c.accept + c.forbid:
            if ":" not in name:
                assert name not in index.ambiguous, f"{c.id}: {name} is ambiguous; use plugin:name"


def test_shape_of_the_prompt_set(cases_and_index):
    cases, _ = cases_and_index
    assert 35 <= len(cases) <= 60
    negatives = [c for c in cases if c.negative]
    assert len(negatives) >= 8, "keep enough negative controls"
    # every negative control and every positive case names at least one look-alike to keep out
    missing = [c.id for c in cases if not c.forbid]
    assert not missing, f"cases without forbid: {missing}"
    assert all(len(c.prompt) >= 40 for c in cases), "prompts should be realistic, not keywords"


def test_expected_plugins_exist_locally(cases_and_index):
    cases, index = cases_and_index
    for c in cases:
        for g in c.expect:
            for a in g:
                assert index.resolve(a).plugin in index.plugins
