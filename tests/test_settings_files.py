"""settings/*.json: the files AGENTS.md calls the riskiest ones in the repo.

Checks shape and the invariants the README promises, not Claude Code's matching (see
test_settings_guardrails.py for the guardrails' ask rules):
- permissions.json stays read-only: only Bash rules, no command word that changes state.
- permissions-trusted-repo.json holds rules that can run code from the clone, and none of permissions.json's.
- project-plugins.json only enables plugins this marketplace publishes.
"""
import json
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SETTINGS = ROOT / "settings"
RULE = re.compile(r"^(Bash|PowerShell)\((.+)\)$")

# Words that change state in the tools permissions.json covers (git, gh, az, kubectl, helm, terraform, ...).
# A read-only baseline must not contain any of them as a separate word of an allow rule.
MUTATING = {
    "add", "apply", "checkout", "clean", "commit", "cordon", "cp", "create", "delete", "destroy", "drain",
    "edit", "exec", "install", "merge", "patch", "pull", "push", "rebase", "replace", "reset", "rm",
    "rollback", "scale", "switch", "taint", "uncordon", "uninstall", "upgrade",
}


def load(name: str) -> dict:
    return json.loads((SETTINGS / name).read_text(encoding="utf-8"))


def rules(name: str, kind: str) -> list[str]:
    return load(name).get("permissions", {}).get(kind, [])


@pytest.mark.parametrize("name", ["permissions.json", "permissions-trusted-repo.json",
                                  "claude-guardrails.json", "project-plugins.json"])
def test_settings_file_is_valid_json_with_a_comment_or_content(name):
    data = load(name)
    assert isinstance(data, dict) and data


@pytest.mark.parametrize("name,kind", [("permissions.json", "allow"), ("permissions.json", "ask"),
                                       ("permissions-trusted-repo.json", "allow"),
                                       ("claude-guardrails.json", "ask")])
def test_rules_are_wellformed_and_unique(name, kind):
    found = rules(name, kind)
    assert found, f"{name} has no {kind} rules"
    assert len(found) == len(set(found)), f"duplicate rule in {name} {kind}"
    for rule in found:
        m = RULE.match(rule)
        assert m, f"{name}: not a Bash/PowerShell rule: {rule}"
        assert m.group(2).strip() == m.group(2), f"{name}: stray whitespace in {rule}"


# --- permissions.json: read-only baseline -------------------------------------------------------------

def test_permissions_json_has_only_allow_and_ask_and_a_comment():
    data = load("permissions.json")
    assert set(data) == {"$comment", "permissions"}
    assert set(data["permissions"]) == {"allow", "ask"}


def test_permissions_json_allows_only_bash_rules():
    assert all(r.startswith("Bash(") for r in rules("permissions.json", "allow"))


def test_permissions_json_allow_rules_contain_no_mutating_word():
    bad = []
    for rule in rules("permissions.json", "allow"):
        words = set(re.split(r"[\s*()]+", RULE.match(rule).group(2)))
        if words & MUTATING:
            bad.append(rule)
    assert bad == [], f"state-changing words in the read-only baseline: {bad}"


def test_permissions_json_ask_rules_do_not_repeat_an_allow_rule():
    assert set(rules("permissions.json", "ask")).isdisjoint(rules("permissions.json", "allow"))


# --- permissions-trusted-repo.json ----------------------------------------------------------------------

def test_trusted_repo_rules_are_not_also_in_the_baseline():
    baseline = set(rules("permissions.json", "allow"))
    assert set(rules("permissions-trusted-repo.json", "allow")).isdisjoint(baseline)


def test_trusted_repo_file_only_allows():
    data = load("permissions-trusted-repo.json")
    assert set(data["permissions"]) == {"allow"}


# --- project-plugins.json -----------------------------------------------------------------------------------

def test_project_plugins_only_enables_published_plugins():
    marketplace = json.loads((ROOT / ".claude-plugin" / "marketplace.json").read_text(encoding="utf-8"))
    published = {p["name"] for p in marketplace["plugins"]}
    data = load("project-plugins.json")

    assert list(data["extraKnownMarketplaces"]) == [marketplace["name"]]
    assert data["extraKnownMarketplaces"][marketplace["name"]]["source"]["repo"] == "lucas4790/my-claude-skills"

    for key, enabled in data["enabledPlugins"].items():
        plugin, _, market = key.partition("@")
        assert market == marketplace["name"], key
        assert plugin in published, f"{key}: no such plugin in marketplace.json"
        assert enabled is True
