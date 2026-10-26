"""Release files agree: marketplace version, changelog, and the Release workflow's tag trigger.

The Release workflow refuses a tag whose version differs from marketplace.json or has no changelog
section; this checks the same thing on every pull request, so a version bump cannot be half done.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SEMVER = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
SECTION = re.compile(r"^## \[([^\]]+)\]", re.MULTILINE)


def marketplace_version() -> str:
    data = json.loads((ROOT / ".claude-plugin" / "marketplace.json").read_text(encoding="utf-8"))
    return data["metadata"]["version"]


def changelog_versions() -> list[str]:
    return SECTION.findall((ROOT / "CHANGELOG.md").read_text(encoding="utf-8"))


def test_marketplace_version_is_semver():
    assert SEMVER.match(marketplace_version()), marketplace_version()


def test_changelog_has_unreleased_first_then_releases_newest_first():
    versions = changelog_versions()
    assert versions[0] == "Unreleased"
    releases = [tuple(map(int, v.split("."))) for v in versions[1:]]
    assert releases, "no released version in CHANGELOG.md"
    assert all(SEMVER.match(v) for v in versions[1:])
    assert releases == sorted(releases, reverse=True), "releases must be listed newest first"
    assert len(set(releases)) == len(releases)


def test_marketplace_version_is_the_newest_changelog_release():
    assert changelog_versions()[1] == marketplace_version()


def test_release_workflow_runs_only_on_version_tags():
    text = (ROOT / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
    on_block = text.split("\njobs:")[0]
    assert re.search(r"^on:\n  push:\n    tags:\n      - \"v\[0-9\]\+\.\[0-9\]\+\.\[0-9\]\+\"", on_block, re.MULTILINE)
    assert "branches" not in on_block and "pull_request" not in on_block
    assert "git tag" not in text and "git push" not in text, "the workflow must not create tags"
