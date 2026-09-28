#!/usr/bin/env python3
"""Skill index and description routing heuristics (stdlib only, no network, no model calls).

Used by scripts/validate.py (cheap static checks on every PR, warnings only) and by
scripts/eval-triggers.py (the skill index that maps names the model invokes to repo skills).

A model decides whether to load a skill from its `description` (plus `when_to_use` in Claude Code),
so three things make routing unreliable, and each gets a warning:

  - a description too short to route on (< MIN_DESC chars) or over the Agent Skills limit
    (MAX_DESC chars; Claude Code also cuts description + when_to_use at LISTING_CAP chars);
  - no "when to use" phrase ("Use when ...", "USE FOR:", "Triggers include ...", ...);
  - two descriptions that share most of their distinctive words and do not name each other,
    so the model has nothing to tell them apart.

Skills with `disable-model-invocation: true` are never routed by the model, so only the length
limit applies to them.

Run directly to print the report for the whole repo, the top overlapping pairs, and counts:
    python3 scripts/skill_descriptions.py [--diff REF] [--top N]
"""
from __future__ import annotations

import argparse
import itertools
import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

MIN_DESC = 80        # shorter than this rarely carries enough keywords to route on
MAX_DESC = 1024      # Agent Skills spec limit for `description`
LISTING_CAP = 1536   # Claude Code truncates description + when_to_use at this length in the skill listing
OVERLAP_THRESHOLD = 0.35   # overlap coefficient of distinctive words (see overlap_pairs)
OVERLAP_MIN_SHARED = 3     # ignore pairs that share fewer distinctive words than this
DISTINCTIVE_DF = 0.10      # a word used by more than this share of skills is boilerplate, not a signal


# --- frontmatter ------------------------------------------------------------------------------

def parse_frontmatter(text: str) -> dict[str, str]:
    """Top-level `key: value` pairs of a YAML frontmatter block, including folded (`>`, `>-`) and
    literal (`|`, `|-`) block scalars and indented continuation lines. Same approach as
    scripts/gen-catalog.py (no PyYAML dependency); block scalars are joined with spaces."""
    m = re.match(r"^---\s*\n(.*?)\n---", text, re.S)
    if not m:
        return {}
    data: dict[str, str] = {}
    key: str | None = None
    buf: list[str] = []
    block = False

    def flush() -> None:
        if key is None:
            return
        val = (" " if block else "\n").join(buf).strip()
        if not block and len(val) >= 2 and val[0] == val[-1] and val[0] in "'\"":
            val = val[1:-1]
        data[key] = val

    for line in m.group(1).splitlines():
        if key and (line.startswith(" ") or line.startswith("\t")):
            buf.append(line.strip())
            continue
        flush()
        km = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$", line)
        if not km:
            key = None
            continue
        key, val = km.group(1), km.group(2).strip()
        block = val in (">", ">-", ">+", "|", "|-", "|+")
        buf = [] if block else [val]
    flush()
    return data


def is_true(value: str | None) -> bool:
    return (value or "").strip().strip("'\"").lower() in ("true", "yes", "on")


# --- skill index ------------------------------------------------------------------------------

@dataclass(frozen=True)
class Skill:
    plugin: str          # plugin name (the namespace Claude Code uses: "<plugin>:<name>")
    name: str            # frontmatter name, or the folder name
    path: str            # SKILL.md path relative to the repo root (posix)
    description: str
    when_to_use: str = ""
    model_invocable: bool = True

    @property
    def qualified(self) -> str:
        return f"{self.plugin}:{self.name}"

    @property
    def routing_text(self) -> str:
        """What the model sees in the skill listing."""
        return " ".join(f"{self.description} {self.when_to_use}".split())


def plugin_dirs(root: Path = ROOT) -> list[Path]:
    """Local plugins: every plugins/<dir> with a .claude-plugin/plugin.json."""
    return sorted(p.parent.parent for p in (root / "plugins").glob("*/.claude-plugin/plugin.json"))


def plugin_name(plugin_dir: Path) -> str:
    try:
        name = json.loads((plugin_dir / ".claude-plugin/plugin.json").read_text(encoding="utf-8")).get("name")
    except (OSError, ValueError):
        name = None
    return name or plugin_dir.name


def skill_files(plugin_dir: Path) -> list[Path]:
    """Same rule as scripts/gen-catalog.py: the manifest's explicit skill list when every entry
    exists, otherwise every SKILL.md under the plugin."""
    manifest = plugin_dir / ".claude-plugin/plugin.json"
    try:
        declared = json.loads(manifest.read_text(encoding="utf-8")).get("skills") if manifest.exists() else None
    except ValueError:
        declared = None
    if isinstance(declared, list):
        explicit = [plugin_dir / d / "SKILL.md" for d in declared]
        if explicit and all(f.exists() for f in explicit):
            return explicit
    return sorted(plugin_dir.rglob("SKILL.md"))


def load_skills(root: Path = ROOT, plugins: list[str] | None = None) -> list[Skill]:
    """Every SKILL.md of the local plugins (optionally only the named plugins)."""
    out = []
    for pdir in plugin_dirs(root):
        pname = plugin_name(pdir)
        if plugins is not None and pname not in plugins and pdir.name not in plugins:
            continue
        for f in skill_files(pdir):
            fm = parse_frontmatter(f.read_text(encoding="utf-8", errors="replace"))
            out.append(Skill(
                plugin=pname,
                name=(fm.get("name") or f.parent.name).strip(),
                path=f.relative_to(root).as_posix(),
                description=" ".join(fm.get("description", "").split()),
                when_to_use=" ".join(fm.get("when_to_use", "").split()),
                model_invocable=not is_true(fm.get("disable-model-invocation")),
            ))
    return out


# --- heuristics -------------------------------------------------------------------------------

TRIGGER_RX = re.compile(r"""
      \buse\s+(?:this\s+skill\s+|this\s+|it\s+|them\s+|only\s+)?(?:when|whenever|for|if|before|after|instead|during)\b
    | \b(?:always|must|should)\s+(?:be\s+)?used?\b
    | \bmandatory\s+(?:for|when|before)\b
    | \btrigger(?:s|ed|ing)?\b
    | \bactivat(?:e|es|ed|ion)\b
    | \binvoke\s+(?:this\s+(?:skill\s+)?)?(?:when|whenever|for|even)\b
    | \bwhen\s+(?:the\s+)?(?:user|you|asked|someone|a\s+user|an?\s+agent)\b
    | \bload\s+(?:this\s+(?:skill\s+)?)?(?:when|whenever|only)\b
""", re.I | re.X)

# Negative routing clauses name *other* skills' keywords; they help routing, so they must not count
# as overlap. Cut from the phrase to the end of its sentence (a period followed by space or end).
NEGATIVE_RX = re.compile(r"\b(?:not\s+for|do\s+not\s+use|don'?t\s+use|never\s+use|exclude[sd]?)\b.*?(?:\.(?=\s|$)|$)",
                         re.I | re.S)
WORD_RX = re.compile(r"[a-z0-9][a-z0-9+#]*(?:[./-][a-z0-9+#]+)*")
STOPWORDS = frozenset("""
a an the and or nor but of to in on for with by from as at into onto via than then so such
is are be been being it its this that these those there their them they we our you your
use used uses using when whenever if only also any all other others each per more most
can will should must may might do does did not no don't e.g eg etc i.e ie like about across
within without over under up out new existing both either one two three
skill skills user users agent agents claude related development task tasks work working
include includes including covers covering guide guides help helps
""".split())


def has_trigger_phrase(text: str) -> bool:
    return bool(TRIGGER_RX.search(text))


def tokens(text: str) -> set[str]:
    """Content words of a description, without its negative ("Not for ...") clauses."""
    text = NEGATIVE_RX.sub(" ", text)
    return {w for w in WORD_RX.findall(text.lower()) if len(w) > 1 and w not in STOPWORDS}


def description_issues(skill: Skill) -> list[str]:
    """Human-readable problems with one skill's description (empty list = fine)."""
    issues = []
    n = len(skill.description)
    if n > MAX_DESC:
        issues.append(f"description is {n} chars, over the Agent Skills limit of {MAX_DESC}")
    if len(skill.routing_text) > LISTING_CAP:
        issues.append(f"description + when_to_use is {len(skill.routing_text)} chars; Claude Code cuts the listing at {LISTING_CAP}")
    if not skill.model_invocable or not skill.description:
        return issues  # never routed by the model; an empty description is validate.py's structural check
    if len(skill.routing_text) < MIN_DESC:
        issues.append(f"description is {len(skill.routing_text)} chars, too short to route on (< {MIN_DESC})")
    if not has_trigger_phrase(skill.routing_text):
        issues.append('no when-to-use phrase (e.g. "Use when ...", "USE FOR: ...")')
    return issues


def names_each_other(a: Skill, b: Skill) -> bool:
    """True when either description mentions the other skill by name (already disambiguated)."""
    def mentions(text: str, name: str) -> bool:
        return re.search(rf"(?<![\w-]){re.escape(name)}(?![\w-])", text, re.I) is not None
    return mentions(a.routing_text, b.name) or mentions(b.routing_text, a.name)


def overlap_pairs(skills: list[Skill], threshold: float = OVERLAP_THRESHOLD,
                  min_shared: int = OVERLAP_MIN_SHARED, max_df: float = DISTINCTIVE_DF,
                  include_disambiguated: bool = False) -> list[tuple[float, float, Skill, Skill, list[str]]]:
    """Pairs of model-invocable skills whose descriptions share most of their distinctive words.

    Distinctive words: content words used by at most `max_df` of the skills (at least 2). Words
    that many descriptions share ("troubleshooting", "configuration", "best practices" in every
    Azure skill) are family boilerplate and do not tell the model anything, so plain Jaccard over
    all words ranks boilerplate-sharing pairs first. Score = overlap coefficient
    |A & B| / min(|A|, |B|) of the distinctive words, which also catches a short description that
    is mostly contained in a longer one. Returns (score, jaccard, a, b, shared words), best first;
    pairs where one description names the other are skipped unless include_disambiguated."""
    routed = [s for s in skills if s.model_invocable and s.description]
    toks = {s.qualified: tokens(s.routing_text) for s in routed}
    df: dict[str, int] = {}
    for words in toks.values():
        for w in words:
            df[w] = df.get(w, 0) + 1
    cap = max(2, int(max_df * len(routed)))
    distinct = {k: {w for w in v if df[w] <= cap} for k, v in toks.items()}
    out = []
    for a, b in itertools.combinations(routed, 2):
        da, db = distinct[a.qualified], distinct[b.qualified]
        if not da or not db:
            continue
        shared = da & db
        if len(shared) < min_shared:
            continue
        score = len(shared) / min(len(da), len(db))
        if score < threshold:
            continue
        if not include_disambiguated and names_each_other(a, b):
            continue
        out.append((score, len(shared) / len(da | db), a, b, sorted(shared)))
    out.sort(key=lambda p: (-p[0], -p[1], p[2].qualified, p[3].qualified))
    return out


def changed_skill_paths(root: Path, ref: str) -> set[str]:
    """SKILL.md paths under plugins/ changed since REF in the working tree, plus untracked ones
    (the same scope validate.py --diff scans). Raises subprocess.CalledProcessError on a bad ref."""
    def git(*a: str) -> str:
        return subprocess.run(["git", *a], cwd=root, capture_output=True, text=True, check=True).stdout
    paths = set(git("diff", "--name-only", "--no-renames", ref, "--", "plugins/").splitlines())
    paths |= set(git("ls-files", "--others", "--exclude-standard", "--", "plugins/").splitlines())
    return {p for p in paths if p.endswith("/SKILL.md") or p == "SKILL.md"}


def routing_warnings(root: Path = ROOT, ref: str | None = None, skills: list[Skill] | None = None,
                     changed: set[str] | None = None) -> list[str]:
    """validate.py's description warnings, one line each (without the leading marker).
    With `ref`, only skills whose SKILL.md changed since REF (and overlap pairs involving one)."""
    skills = load_skills(root) if skills is None else skills
    if ref is not None and changed is None:
        changed = changed_skill_paths(root, ref)
    scope = (lambda s: s.path in changed) if changed is not None else (lambda s: True)
    out = []
    for s in sorted(skills, key=lambda s: s.path):
        if scope(s):
            issues = description_issues(s)
            if issues:
                out.append(f"{s.path}: [description] " + "; ".join(issues))
    for score, _jac, a, b, shared in overlap_pairs(skills):
        if scope(a) or scope(b):
            words = ", ".join(shared[:6]) + (", ..." if len(shared) > 6 else "")
            out.append(f"{a.path} ~ {b.path}: [overlap] {a.name} and {b.name} share {score:.0%} of their "
                       f"distinctive description words ({words}) and neither names the other; "
                       f"add a \"Not for ... (use ...)\" clause")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--diff", metavar="REF", help="only skills changed since REF")
    ap.add_argument("--top", type=int, default=15, help="also list the N most overlapping pairs (0 = off)")
    args = ap.parse_args()
    skills = load_skills()
    lines = routing_warnings(ROOT, args.diff, skills)
    print("\n".join(f"⚠ {w}" for w in lines) or "no description warnings")
    if args.top:
        print(f"\ntop {args.top} pairs by distinctive-word overlap (warning threshold {OVERLAP_THRESHOLD}; "
              f"* = one description names the other, never warned):")
        for score, jac, a, b, shared in overlap_pairs(skills, threshold=0.0, include_disambiguated=True)[:args.top]:
            mark = "*" if names_each_other(a, b) else " "
            print(f" {mark} {score:.2f} (jaccard {jac:.2f})  {a.qualified} ~ {b.qualified}  [{', '.join(shared[:8])}]")
    kinds = {k: sum(1 for w in lines if f"[{k}]" in w) for k in ("description", "overlap")}
    routed = sum(1 for s in skills if s.model_invocable)
    print(f"\n{len(skills)} skills ({routed} model-invocable): {kinds['description']} description warning(s), "
          f"{kinds['overlap']} overlap warning(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
