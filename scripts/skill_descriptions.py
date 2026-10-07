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

The second half of the module is the listing cost: how many characters of the model's context the
skills and commands of a plugin or profile take (SKILLS.md, "Listing cost"), the budgets of
profiles.json `listingBudget` and the warnings validate.py prints for them.

Run directly to print the report for the whole repo, the top overlapping pairs, and counts:
    python3 scripts/skill_descriptions.py [--diff REF] [--top N]
"""
from __future__ import annotations

import argparse
import itertools
import json
import re
import subprocess
import tempfile
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

FRONTMATTER_RX = re.compile(r"^---\s*\n(.*?)\n---", re.S)


def parse_frontmatter(text: str) -> dict[str, str]:
    """Top-level `key: value` pairs of a YAML frontmatter block, including folded (`>`, `>-`, `>+`)
    and literal (`|`, `|-`, `|+`) block scalars and indented continuation lines (no PyYAML
    dependency); block scalars are joined with spaces. A blank line does not end a value (YAML ends it
    at the next less-indented line), so `description: >-` followed by a blank line is not empty. The one
    parser of validate.py, gen-catalog.py and the eval index, so the checks, SKILLS.md and the evals read
    the same values."""
    m = FRONTMATTER_RX.match(text)
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
        if key and not line.strip():
            continue
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
    """The manifest's explicit skill list when every entry exists, otherwise every SKILL.md under
    the plugin. gen-catalog.py lists these in SKILLS.md; validate.py warns about any other SKILL.md."""
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
        # -z paths are raw UTF-8; the locale codec (cp1252 on Windows) would garble or reject them
        return subprocess.run(["git", *a], cwd=root, capture_output=True, text=True, encoding="utf-8",
                              errors="replace", check=True).stdout
    # -z: git C-quotes non-ASCII paths otherwise, and they would never match
    paths = set(git("diff", "--name-only", "-z", "--no-renames", ref, "--", "plugins/").split("\0"))
    paths |= set(git("ls-files", "-z", "--others", "--exclude-standard", "--", "plugins/").split("\0"))
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


# --- listing cost -----------------------------------------------------------------------------
# What the installed plugins put into the model's context in every session. Claude Code lists each
# model-invocable skill and plugin command as one line, "- plugin:name: description" (description,
# then " - " and when_to_use, cut at LISTING_CAP), joins the lines with line breaks and fits them into a
# budget of window tokens x 3 or 4 characters x 1% (setting skillListingBudgetFraction): over it, the
# descriptions of the least used skills are dropped and only "- plugin:name" stays. Agents are not in it.
# That is read from Claude Code 2.1.292. Copilot CLI has a budget variable (SKILL_CHAR_BUDGET); its listing
# format and what it does over the budget are not verified, so its figures use the same counting rule.
# Simplified: only commands/ is read (not a `commands` path of plugin.json), a command in a subfolder keeps
# its file name (no namespace), the "name (alias)" Claude Code adds to two equal names is not counted, and a
# length is in code points (Claude Code counts UTF-16 units), so a few characters per entry can differ.

ENTRY_OVERHEAD = 5       # "- " before the name, ": " after it, a line break after the entry
NAME_ONLY_OVERHEAD = 3   # "- " and the line break: what an entry keeps when its description is dropped
GROWTH_WARN = 500        # --diff: a plugin whose cost grows by more than this is reported (an average skill costs ~530)


@dataclass(frozen=True)
class Entry:
    plugin: str
    name: str
    kind: str      # "skill" or "command"
    path: str      # relative to the repo root (posix)
    text: str      # what follows "- plugin:name: ", already cut at LISTING_CAP

    @property
    def qualified(self) -> str:
        return f"{self.plugin}:{self.name}"

    @property
    def chars(self) -> int:
        return len(self.qualified) + ENTRY_OVERHEAD + len(self.text)

    @property
    def name_chars(self) -> int:
        return len(self.qualified) + NAME_ONLY_OVERHEAD


@dataclass(frozen=True)
class Cost:
    skills: int = 0
    commands: int = 0
    chars: int = 0
    names: int = 0

    def __add__(self, other: "Cost") -> "Cost":
        return Cost(self.skills + other.skills, self.commands + other.commands,
                    self.chars + other.chars, self.names + other.names)

    @property
    def entries(self) -> int:
        return self.skills + self.commands


def listing_text(description: str, when_to_use: str = "") -> str:
    """The text after the name in the listing: Claude Code's `description - when_to_use`, cut at LISTING_CAP
    characters with an ellipsis. (Skill.routing_text joins with a space; the length checks keep using it.)"""
    text = " ".join(f"{description} - {when_to_use}".split()) if when_to_use.strip() else " ".join(description.split())
    return text if len(text) <= LISTING_CAP else text[:LISTING_CAP - 1] + "\u2026"


def plugin_entries(plugin_dir: Path, plugin: str, root: Path = ROOT) -> list[Entry]:
    """The listing entries of one plugin directory: its skills (skill_files) and its commands/*.md, minus
    everything with `disable-model-invocation: true` (never listed). A command is named after its file."""
    found = [(f, "skill") for f in skill_files(plugin_dir)]
    commands = plugin_dir / "commands"
    if commands.is_dir():
        found += [(f, "command") for f in sorted(commands.rglob("*.md"))]
    out = []
    for f, kind in found:
        try:
            fm = parse_frontmatter(f.read_text(encoding="utf-8", errors="replace"))
        except OSError:  # a dangling or unreadable file (gen-catalog.py reports it): the cost leaves it out
            continue
        if is_true(fm.get("disable-model-invocation")):
            continue
        name = (fm.get("name") or (f.parent.name if kind == "skill" else f.stem)).strip()
        out.append(Entry(plugin, name, kind, f.relative_to(root).as_posix(),
                         listing_text(fm.get("description", ""), fm.get("when_to_use", ""))))
    return out


def listing_entries(root: Path = ROOT) -> list[Entry]:
    """Every listing entry of the local plugins (plugins/<dir> with a .claude-plugin/plugin.json)."""
    return [e for pdir in plugin_dirs(root) for e in plugin_entries(pdir, plugin_name(pdir), root)]


def plugin_costs(entries: list[Entry]) -> dict[str, Cost]:
    out: dict[str, Cost] = {}
    for e in entries:
        out[e.plugin] = out.get(e.plugin, Cost()) + Cost(int(e.kind == "skill"), int(e.kind == "command"),
                                                         e.chars, e.name_chars)
    return out


def profile_costs(costs: dict[str, Cost], profiles: dict[str, list[str]]) -> dict[str, Cost]:
    out = {}
    for name, members in profiles.items():
        total = Cost()
        for m in members:
            total = total + costs.get(m, Cost())
        out[name] = total
    return out


def load_profiles(root: Path = ROOT) -> dict | None:
    """profiles.json as a dict, or None when it is missing, invalid or not an object (validate.py reports that)."""
    try:
        data = json.loads((root / "profiles.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def profile_members(prof: dict | None) -> dict[str, list[str]]:
    """{profile: [plugin names]} of profiles.json; anything that is not an object of lists of names is left out."""
    raw = prof.get("profiles") if isinstance(prof, dict) else None
    if not isinstance(raw, dict):
        return {}
    return {k: [m for m in v if isinstance(m, str)] for k, v in raw.items() if isinstance(v, list)}


@dataclass(frozen=True)
class Budget:
    client: str
    label: str
    chars: int
    profiles: tuple[str, ...]


def parse_budgets(prof: dict | None) -> tuple[list[Budget], list[str]]:
    """The valid entries of profiles.json `listingBudget` ({client: {"chars": N, "profiles": [...], "label": ..}},
    "$comment" ignored) in file order, and one problem text per invalid entry (validate.py reports them)."""
    raw = (prof or {}).get("listingBudget")
    if raw is None:
        return [], []
    if not isinstance(raw, dict):
        return [], ["profiles.json: listingBudget must be an object"]
    known = profile_members(prof)
    out, problems = [], []
    for client, cfg in raw.items():
        if client.startswith("$"):
            continue
        where = f"profiles.json: listingBudget.{client}"
        if not isinstance(cfg, dict):
            problems.append(f'{where} must be an object with "chars" and "profiles"')
            continue
        chars, names = cfg.get("chars"), cfg.get("profiles")
        ok = True
        if isinstance(chars, bool) or not isinstance(chars, int) or chars <= 0:
            problems.append(f"{where}.chars must be a positive integer")
            ok = False
        if not isinstance(names, list) or not names or not all(isinstance(n, str) for n in names):
            problems.append(f"{where}.profiles must be a non-empty list of profile names")
            ok = False
        else:
            seen: set[str] = set()
            for n in names:
                if n not in known:
                    problems.append(f"{where} names unknown profile {n!r}")
                    ok = False
                elif n in seen:   # a typo for another profile would leave that one unchecked
                    problems.append(f"{where} names profile {n!r} twice")
                    ok = False
                seen.add(n)
        if ok:
            label = cfg.get("label")
            out.append(Budget(client, label if isinstance(label, str) and label.strip() else client, chars, tuple(names)))
    return out, problems


def names_tree(root: Path, ref: str) -> bool:
    """True when REF names one commit or tree. A range (A..B, A...B) is fine for `git diff` but has no tree to read."""
    return subprocess.run(["git", "rev-parse", "--verify", "--quiet", f"{ref}^{{tree}}"], cwd=root,
                          capture_output=True).returncode == 0


def entries_at_ref(root: Path, ref: str) -> list[Entry]:
    """The listing entries of the plugins as committed at REF (a ref that has no plugins/ gives none).
    Reads the blobs with git ls-tree and one git cat-file --batch, never a checkout, into a temp tree that
    the same loaders read. Raises subprocess.CalledProcessError when git fails (a bad ref)."""
    want = re.compile(r"^plugins/[^/]+/\.claude-plugin/plugin\.json$|(?:^|/)SKILL\.md$|^plugins/[^/]+/commands/.+\.md$")

    def git(*a: str, data: bytes | None = None) -> bytes:
        return subprocess.run(["git", *a], cwd=root, capture_output=True, check=True, input=data).stdout

    items = []
    for rec in git("ls-tree", "-r", "-z", ref, "--", "plugins/").split(b"\0"):
        meta, _, path = rec.partition(b"\t")
        parts = meta.split(b" ")
        rel = path.decode("utf-8", "surrogateescape")
        # a tree can hold entries named ".." (hand-made objects): never write outside the temp tree
        if (len(parts) == 3 and parts[1] == b"blob" and parts[0] in (b"100644", b"100755") and want.search(rel)
                and not {"", ".", ".."} & set(rel.replace("\\", "/").split("/"))):
            items.append((rel, parts[2]))
    if not items:
        return []
    blobs = git("cat-file", "--batch", data=b"".join(sha + b"\n" for _rel, sha in items))
    with tempfile.TemporaryDirectory() as tmp:
        pos = 0
        for rel, _sha in items:
            end = blobs.index(b"\n", pos)
            head = blobs[pos:end].split(b" ")
            if head[-1] == b"missing":
                pos = end + 1
                continue
            size = int(head[2])
            try:
                dest = Path(tmp) / rel
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(blobs[end + 1:end + 1 + size])
            except (OSError, ValueError):  # a name this system cannot hold: leave the file out
                pass
            pos = end + 1 + size + 1
        return listing_entries(Path(tmp))


def _pct(n: int, d: int) -> str:
    return f"{round(100 * n / d)}%"


def budget_warnings(root: Path = ROOT, ref: str | None = None, prof: dict | None = None,
                    entries: list[Entry] | None = None) -> list[str]:
    """validate.py's listing-budget warnings, one line each (without the leading marker).

    Without `ref`: one line per (budget, profile) whose cost is over the budget. With `ref`: the same
    line only for a profile that is over its budget now and was within it at REF or grew by more than
    GROWTH_WARN since, plus one line per plugin whose cost grew by more than GROWTH_WARN (a plugin
    that is new since REF counts from 0). Profile membership is the one in `prof` on both sides. A REF that
    is not one commit or tree (a range) has no listing to compare with: one line says so and nothing else is checked."""
    if ref and not names_tree(root, ref):
        return [f"profiles.json: [budget] listing cost not compared with '{ref}': it is not one commit or tree "
                f"(a range?), so growth since it is not checked"]
    prof = load_profiles(root) if prof is None else prof
    entries = listing_entries(root) if entries is None else entries
    now = plugin_costs(entries)
    profiles = profile_members(prof)
    budgets, _problems = parse_budgets(prof)
    before = plugin_costs(entries_at_ref(root, ref)) if ref else None
    now_p = profile_costs(now, profiles)
    before_p = profile_costs(before, profiles) if before is not None else None
    home = {m: name for name, members in profiles.items() for m in members}
    out = []
    for b in budgets:
        for name in b.profiles:
            cost = now_p.get(name, Cost())
            if cost.chars <= b.chars:
                continue
            note = ""
            if before_p is not None:
                was = before_p.get(name, Cost()).chars
                grew = cost.chars - was
                if was > b.chars and grew <= GROWTH_WARN:
                    continue
                note = f"; {was:,} at {ref} ({grew:+,})"
            top = max((m for m in profiles.get(name, []) if m in now), key=lambda m: (now[m].chars, m), default=None)
            largest = f"; largest plugin {top} ({now[top].chars:,})" if top else ""
            out.append(f"profiles.json: [budget] profile '{name}' costs {cost.chars:,} listing characters "
                       f"(entries: {cost.entries}), {_pct(cost.chars, b.chars)} of the {b.chars:,}-character {b.label} "
                       f"budget, so descriptions may be cut{note}{largest}")
    if before is not None:
        for plugin in sorted(now):
            was, cost = before.get(plugin, Cost()).chars, now[plugin].chars
            if cost - was <= GROWTH_WARN:
                continue
            pct = f", +{_pct(cost - was, was)}" if was else ""
            where = f" (profile {home[plugin]}: {now_p[home[plugin]].chars:,} characters in total)" if plugin in home else ""
            out.append(f"{plugin}: [budget] listing cost grew from {was:,} to {cost:,} characters "
                       f"(+{cost - was:,}{pct}) since {ref}{where}")
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
