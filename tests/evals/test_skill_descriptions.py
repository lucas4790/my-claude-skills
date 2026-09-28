"""Offline tests for scripts/skill_descriptions.py, the description checks validate.py runs on every PR."""
import ast
import re
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True  # keep scripts/__pycache__ out of the working tree
sys.path.insert(0, str(ROOT / "scripts"))
import skill_descriptions as sd  # noqa: E402


def skill(name, desc, plugin="p", dmi=False, when=""):
    return sd.Skill(plugin, name, f"plugins/{plugin}/skills/{name}/SKILL.md", " ".join(desc.split()), when, not dmi)


# --- frontmatter ------------------------------------------------------------------------------

def test_frontmatter_forms():
    text = (
        "---\n"
        "name: 'quoted-name'\n"
        "description: >-\n"
        "  Folded description\n"
        "  over two lines.\n"
        "when_to_use: |\n"
        "  line one\n"
        "  line two\n"
        "plain: value: with colon\n"
        'dq: "double quoted"\n'
        "cont: first\n"
        "  second\n"
        "disable-model-invocation: true\n"
        "---\nbody\n"
    )
    fm = sd.parse_frontmatter(text)
    assert fm["name"] == "quoted-name"
    assert fm["description"] == "Folded description over two lines."
    assert fm["when_to_use"] == "line one line two"
    assert fm["plain"] == "value: with colon"
    assert fm["dq"] == "double quoted"
    assert fm["cont"] == "first\nsecond"
    assert sd.is_true(fm["disable-model-invocation"])
    assert sd.parse_frontmatter("no frontmatter") == {}
    assert not sd.is_true(None) and sd.is_true('"yes"')


def _gen_catalog_frontmatter():
    """gen-catalog.py's own parser, without executing the script (importing it rewrites SKILLS.md)."""
    src = (ROOT / "scripts/gen-catalog.py").read_text(encoding="utf-8")
    fn = next(n for n in ast.parse(src).body if isinstance(n, ast.FunctionDef) and n.name == "frontmatter")
    ns = {"re": re, "Path": Path}
    exec(ast.get_source_segment(src, fn), ns)
    return ns["frontmatter"]


def test_descriptions_match_the_catalog_parser():
    gc = _gen_catalog_frontmatter()
    for s in sd.load_skills(ROOT):
        expected = " ".join(gc(ROOT / s.path).get("description", "").split())
        assert s.description == expected, s.path


def test_repo_index():
    skills = sd.load_skills(ROOT)
    q = {s.qualified: s for s in skills}
    assert "powershell:pester" in q and "azure-agent-skills:azure-kubernetes-service" in q
    assert q["dotnet-test:filter-syntax"].model_invocable is False
    assert len(q) == len(skills), "qualified names are unique"
    assert {s.plugin for s in sd.load_skills(ROOT, plugins=["powershell"])} == {"powershell"}


# --- heuristics -------------------------------------------------------------------------------

@pytest.mark.parametrize("text", [
    "Deploy things. Use when the user asks for a deploy.",
    "Does X. USE FOR: rename, move. DO NOT USE FOR: Y.",
    "ALWAYS USE before running tests.",
    "Triggers include 'open a website'.",
    "Activation requires a coverage report.",
    "Use this skill whenever the user mentions charts.",
    "MANDATORY for static source-to-test pairing.",
    "Invoke even for a tiny package.",
    "Helps when the user wants a spec.",
])
def test_trigger_phrases(text):
    assert sd.has_trigger_phrase(text)


@pytest.mark.parametrize("text", [
    "Design stable, compatible public APIs using extend-only design principles.",
    "Write integration tests using TestContainers for .NET with xUnit.",
    "Seal classes, use readonly structs, prefer static pure functions.",
    "Manage NuGet packages. Never edit XML directly - use dotnet add/remove/list commands.",
])
def test_no_trigger_phrase(text):
    assert not sd.has_trigger_phrase(text)


def test_description_issues():
    assert sd.description_issues(skill("ok", "Rotates Azure Key Vault secrets and keys safely. Use when rotating or backing up secrets.")) == []
    short = sd.description_issues(skill("s", "File upload endpoints in ASP.NET minimal APIs (.NET 8+)"))
    assert any("too short" in i for i in short) and any("when-to-use" in i for i in short)
    # when_to_use counts towards routing text
    assert sd.description_issues(skill("w", "Kubernetes helper for clusters and namespaces and pods everywhere.",
                                       when="Use when debugging pods")) == []
    long = sd.description_issues(skill("l", "Use when x. " + "word " * 250))
    assert any("over the Agent Skills limit" in i for i in long)
    assert any("1536" in i for i in sd.description_issues(skill("l2", "Use when x. " + "w " * 500, when="y " * 600)))
    # never routed by the model: only the length limit applies
    assert sd.description_issues(skill("d", "short", dmi=True)) == []
    assert any("limit" in i for i in sd.description_issues(skill("d2", "x" * 1100, dmi=True)))


def test_tokens_drop_stopwords_and_negative_clauses():
    t = sd.tokens("Use when configuring Azure Pipelines YAML. Not for Azure Repos (use azure-repos). DO NOT USE FOR: boards.")
    assert {"configuring", "azure", "pipelines", "yaml"} <= t
    assert not {"repos", "azure-repos", "boards", "use", "when"} & t


def test_overlap_ignores_family_boilerplate_and_flags_confusable_pairs():
    boiler = "Expert knowledge including troubleshooting best practices decision making limits quotas security configuration."
    # 30 family members: a word shared by all of them is boilerplate; the three NuGet skills stay under
    # the 10% document-frequency cap (int(0.1 * 33) = 3), so their shared words are distinctive
    skills = [skill(f"svc{i}", f"{boiler} Use when configuring service{i} widgets{i}.") for i in range(30)]
    skills += [
        skill("convert-to-cpm", "Convert projects to NuGet Central Package Management with Directory.Packages.props. Use for version drift."),
        skill("package-management", "Manage NuGet packages with Central Package Management and Directory.Packages.props. Use when adding packages."),
        skill("mentions-other", "Manage NuGet Central Package Management Directory.Packages.props. Not for conversions (use convert-to-cpm)."),
        skill("dmi", "NuGet Central Package Management Directory.Packages.props", dmi=True),
    ]
    pairs = sd.overlap_pairs(skills)
    names = {(a.name, b.name) for _, _, a, b, _ in pairs}
    assert ("convert-to-cpm", "package-management") in names
    assert not any(n.startswith("svc") for pair in names for n in pair), "boilerplate alone must not match"
    assert not {("convert-to-cpm", "mentions-other"), ("mentions-other", "convert-to-cpm")} & names, \
        "a description that names the other skill is already disambiguated"
    assert ("package-management", "mentions-other") in names or ("mentions-other", "package-management") in names
    assert not any("dmi" in pair for pair in names)
    assert any("mentions-other" in (a.name, b.name) for _, _, a, b, _ in sd.overlap_pairs(skills, include_disambiguated=True))
    score, jac, _, _, shared = next(p for p in pairs if {p[2].name, p[3].name} == {"convert-to-cpm", "package-management"})
    assert 0 < jac <= score <= 1 and "directory.packages.props" in shared


def test_routing_warnings_scope():
    skills = [
        skill("short", "Too short."),
        skill("fine", "Rotates Azure Key Vault secrets and keys safely. Use when rotating or backing up secrets."),
        skill("convert-to-cpm", "Convert projects to NuGet Central Package Management with Directory.Packages.props. Use for version drift."),
        skill("package-management", "Manage NuGet packages with Central Package Management and Directory.Packages.props. Use when adding packages."),
    ]
    full = sd.routing_warnings(ROOT, skills=skills)
    assert sum("[description]" in w for w in full) == 1 and sum("[overlap]" in w for w in full) == 1
    assert all("[high]" not in w for w in full)   # the sync workflow counts [high] as injection hits
    only_fine = sd.routing_warnings(ROOT, skills=skills, ref="X", changed={"plugins/p/skills/fine/SKILL.md"})
    assert only_fine == []
    one_side = sd.routing_warnings(ROOT, skills=skills, ref="X", changed={"plugins/p/skills/convert-to-cpm/SKILL.md"})
    assert len(one_side) == 1 and "[overlap]" in one_side[0]


def test_real_repo_noise_stays_reasonable():
    lines = sd.routing_warnings(ROOT)
    assert len(lines) <= 40, "description warnings got noisy; revisit the thresholds"


def test_changed_skill_paths(tmp_path):
    def git(*a):
        subprocess.run(["git", *a], cwd=tmp_path, check=True, capture_output=True)
    git("init", "-q")
    git("config", "user.email", "t@example.invalid")
    git("config", "user.name", "t")
    (tmp_path / "plugins/p/skills/a").mkdir(parents=True)
    (tmp_path / "plugins/p/skills/a/SKILL.md").write_text("---\nname: a\n---\n")
    (tmp_path / "plugins/p/skills/a/ref.md").write_text("x")
    git("add", "-A")
    git("-c", "commit.gpgsign=false", "commit", "-qm", "init")
    (tmp_path / "plugins/p/skills/a/SKILL.md").write_text("---\nname: a\ndescription: new\n---\n")
    (tmp_path / "plugins/p/skills/a/ref.md").write_text("y")
    (tmp_path / "plugins/p/skills/b").mkdir()
    (tmp_path / "plugins/p/skills/b/SKILL.md").write_text("---\nname: b\n---\n")
    assert sd.changed_skill_paths(tmp_path, "HEAD") == {"plugins/p/skills/a/SKILL.md", "plugins/p/skills/b/SKILL.md"}
    with pytest.raises(subprocess.CalledProcessError):
        sd.changed_skill_paths(tmp_path, "no-such-ref")
