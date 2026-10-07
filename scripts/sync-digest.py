#!/usr/bin/env python3
"""Digest of what a sync changed, as bounded markdown for the sync PR body (stdlib only, no network).

  sync-digest.py --base REF [--head REF] [--max-bytes N] [--no-commands]

Compares the tree of REF with the tree of --head (a ref) or, without --head, with HEAD plus the working tree
including untracked files: what sync.sh and bump-pinned.sh leave behind, the scope of `validate.py --diff HEAD`.
The real index is never touched. Both sides are read from git objects, so nothing in the checkout is followed
(a symlink stays a symlink), run or imported: upstream files are only parsed (JSON, YAML frontmatter).

Prints per source (and pinned plugin) the old and new commit with a compare link, per plugin the files added,
modified and removed and whether the manifest version changed, the new, removed and changed skills (and whether
the model can invoke them), the net change of model-invocable description characters, and the hook, MCP and LSP
registrations added, removed or changed. Every cut is announced ("N more not shown"), as is every changed file
that was too big to read; the output stays under --max-bytes (default 12000). Text from upstream is sanitised and
printed in code spans only. --no-commands leaves the command, URL and prompt text out of the registrations (the
workflow falls back to it when that text trips the attribution guard).

Never fails a job: an internal error prints a one-line note (a section that fails is replaced by one) and the
exit status stays 0. No changes: prints nothing. Exit 2: bad arguments or a ref that does not resolve.
"""
from __future__ import annotations

import argparse
import ast
import collections
import json
import os
import posixpath
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# No scripts/__pycache__: the sync job runs this script and then `git add -A`.
sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import skill_descriptions as sd  # noqa: E402

ROOT = HERE.parent
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

LOCK = "UPSTREAM.lock.json"
MARKETPLACE = ".claude-plugin/marketplace.json"
MAX_BLOB = 1_000_000  # a file over this is not parsed
SCRIPT_EXT = {".sh", ".bash", ".zsh", ".ps1", ".psm1", ".bat", ".cmd", ".py", ".js", ".mjs", ".cjs", ".ts", ".rb"}
REGULAR = {"100644", "100755"}
LIMITS = {"sources": 30, "plugins": 40, "skills": 30, "changed": 25, "registrations": 25, "other": 10}
GITHUB_REPO = re.compile(r"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?")
SHA = re.compile(r"[0-9a-f]{40}")


# --- git ------------------------------------------------------------------------------------------------------

def git(*args: str, env: dict | None = None) -> bytes:
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, check=True,
                          env={**os.environ, **(env or {})}).stdout


class UnknownRef(Exception):
    pass


def tree_of(ref: str, flag: str) -> str:
    try:
        return git("rev-parse", "--verify", "--quiet", f"{ref}^{{tree}}").decode().strip()
    except subprocess.CalledProcessError:
        raise UnknownRef(f"{flag} {clean(ref, 80)} is not a known ref") from None


def worktree_tree() -> str:
    """Tree of HEAD plus the working tree (untracked files too, .gitignore honoured), built in a throwaway
    index so that the real one stays as it is."""
    with tempfile.TemporaryDirectory() as d:
        env = {"GIT_INDEX_FILE": os.path.join(d, "index")}
        git("read-tree", "HEAD", env=env)
        git("add", "-A", "--", ".", env=env)
        return git("write-tree", env=env).decode().strip()


def listing(tree: str) -> dict[str, tuple[str, str]]:
    """{path: (mode, oid)} of every entry of a tree, symlinks and submodules included."""
    out = {}
    for rec in git("ls-tree", "-r", "-z", "--full-tree", tree).split(b"\0"):
        if rec:
            meta, _, path = rec.partition(b"\t")
            mode, _type, oid = meta.decode().split()
            out[path.decode("utf-8", "replace")] = (mode, oid)
    return out


class Blobs:
    """Blob contents through one `git cat-file --batch` process; a blob over MAX_BLOB comes back as None."""

    def __init__(self) -> None:
        self.p = subprocess.Popen(["git", "cat-file", "--batch"], cwd=ROOT, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

    def get(self, oid: str) -> bytes | None:
        self.p.stdin.write(oid.encode() + b"\n")
        self.p.stdin.flush()
        head = self.p.stdout.readline().split()
        if len(head) != 3 or head[1] != b"blob":
            return None
        size = int(head[2])
        if size <= MAX_BLOB:
            data = self.p.stdout.read(size)
        else:  # never held in memory
            data = None
            for _ in range(size // 65536 + 1):
                self.p.stdout.read(min(65536, size))
                size -= min(65536, size)
                if not size:
                    break
        self.p.stdout.read(1)
        return data

    def close(self) -> None:
        self.p.stdin.close()
        self.p.wait()


# --- text safety: whatever comes from upstream is printed through code() -------------------------------------

def clean(value, cap: int = 60) -> str:
    """One line of printable characters without backticks, at most `cap` long."""
    s = "".join(c if c.isprintable() else "?" for c in " ".join(str(value).split())).replace("`", "'")
    return s if len(s) <= cap else s[:max(cap - 3, 1)] + "..."


def code(value, cap: int = 60) -> str:
    """A code span, in which markdown, HTML, @mentions, #123 and links stay inert; a pipe is escaped for tables."""
    return "`" + clean(value, cap).replace("|", "\\|") + "`"


def sha7(sha) -> str:
    return clean(sha, 40)[:7]


# --- the hook helpers of validate.py ----------------------------------------------------------------------------

VALIDATE_NAMES = ("MARKETPLACE", "HOOK_META_KEYS", "FM_HOOKS_KEY", "canonical", "registrations",
                  "frontmatter_hooks", "hook_candidates", "hook_configs")


_HELPERS: dict = {}


def validate_helpers() -> dict:
    """validate.py runs the whole validation when imported (argparse, git, a SKILLS.md rewrite, sys.exit), so it
    cannot be imported. Only its named top-level definitions are compiled, into a namespace of their own and
    nothing else of the file runs: the digest reads hook registrations exactly as the validator does."""
    if _HELPERS:
        return _HELPERS
    tree = ast.parse((HERE / "validate.py").read_text(encoding="utf-8"))
    ns = {"json": json, "re": re, "posixpath": posixpath, "collections": collections,
          "FRONTMATTER_RX": sd.FRONTMATTER_RX}
    found = set()
    for node in tree.body:
        if isinstance(node, ast.FunctionDef):
            name = node.name
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            target = node.targets[0] if isinstance(node, ast.Assign) else node.target
            name = target.id if isinstance(target, ast.Name) else ""
        else:
            continue
        if name in VALIDATE_NAMES:
            exec(compile(ast.Module([node], []), "validate.py", "exec"), ns)  # noqa: S102
            found.add(name)
    if found != set(VALIDATE_NAMES):
        raise RuntimeError("validate.py no longer defines " + ", ".join(sorted(set(VALIDATE_NAMES) - found)))
    _HELPERS.update(ns)
    return _HELPERS


# --- one side of the comparison -------------------------------------------------------------------------------

def inside(entry) -> bool:
    """A skill path of a manifest that is relative and stays inside the plugin (nothing is joined to a directory
    outside the temp dir that skill_descriptions reads). A drive letter or a backslash is no path inside the plugin
    on Windows either."""
    if not isinstance(entry, str) or not entry or "\\" in entry or "\0" in entry or re.match(r"[A-Za-z]:", entry):
        return False
    norm = posixpath.normpath(entry)
    return not posixpath.isabs(entry) and norm != ".." and not norm.startswith("../")


def safe_manifest(text: str) -> str:
    """The two keys of a plugin manifest that skill_descriptions reads: its name, and its list of skill paths when
    every one stays inside the plugin (otherwise the plugin's SKILL.md files are found by walking it)."""
    try:
        data = json.loads(text)
    except ValueError:
        data = None
    out = {}
    if isinstance(data, dict):
        if isinstance(data.get("name"), str):
            out["name"] = data["name"]
        if isinstance(data.get("skills"), list) and all(map(inside, data["skills"])):
            out["skills"] = data["skills"]
    return json.dumps(out)


class Side:
    def __init__(self, tree: str, blobs: Blobs):
        self.tree, self.blobs = tree, blobs
        self.files = listing(tree)
        self.skipped: set[str] = set()   # regular files that were asked for and not read (too big, unreadable)
        self._skills = None

    def text(self, rel: str) -> str | None:
        ent = self.files.get(rel)
        if not ent or ent[0] not in REGULAR:
            return None
        data = self.blobs.get(ent[1])
        if data is None:
            self.skipped.add(rel)
            return None
        return data.decode("utf-8", "replace")

    def json(self, rel: str):
        try:
            return json.loads(self.text(rel) or "")
        except ValueError:
            return None

    def plugins(self) -> set[str]:
        return {p.split("/")[1] for p in self.files if p.startswith("plugins/") and p.count("/") >= 2}

    def version(self, plugin: str):
        for rel in (f"plugins/{plugin}/.claude-plugin/plugin.json", f"plugins/{plugin}/plugin.json"):
            data = self.json(rel)
            if isinstance(data, dict) and isinstance(data.get("version"), str):
                return data["version"]
        return None

    def pins(self) -> dict[str, tuple[str, str]]:
        """{plugin: (repo URL, sha)} of the marketplace entries that point at an external repository."""
        out = {}
        data = self.json(MARKETPLACE)
        for p in (data.get("plugins") if isinstance(data, dict) else None) or []:
            src = p.get("source") if isinstance(p, dict) else None
            if isinstance(src, dict) and isinstance(src.get("sha"), str):
                url = src.get("url") or (f"https://github.com/{src['repo']}" if src.get("repo") else "")
                out[str(p.get("name"))] = (str(url), src["sha"])
        return out

    def skills(self) -> list:
        """The skills, found the way SKILLS.md finds them: the SKILL.md files and plugin manifests are written to a
        temp dir (regular files only, paths checked, manifests cut down to what is read from them) that
        skill_descriptions.load_skills reads, so nothing outside that directory can be reached."""
        if self._skills is None:
            with tempfile.TemporaryDirectory() as d:
                for rel, (mode, _oid) in self.files.items():
                    parts = rel.split("/")
                    if not (parts[0] == "plugins" and mode in REGULAR and not {"", ".", ".."} & set(parts)):
                        continue
                    if parts[-1] == "SKILL.md" or parts[2:] == [".claude-plugin", "plugin.json"]:
                        data = self.text(rel)
                        if data is not None:
                            if parts[-1] == "plugin.json":
                                data = safe_manifest(data)
                            dest = Path(d, *parts)
                            try:
                                dest.parent.mkdir(parents=True, exist_ok=True)
                                dest.write_text(data, encoding="utf-8")
                            except OSError:  # a path this file system cannot hold: that skill is not listed
                                continue
                self._skills = sd.load_skills(Path(d))
        return self._skills


def listing_chars(skill) -> int:
    """What a model-invocable skill adds to the skill listing: description plus when_to_use, cut at the cap."""
    return min(len(skill.routing_text), sd.LISTING_CAP) if skill.model_invocable else 0


def yes(flag: bool) -> str:
    return "yes" if flag else "no"


def more(n: int) -> list[str]:
    """Ends a table (a blank line first: GFM reads a text line right under a row as one more row)."""
    return ["", f"_{n} more not shown._", ""] if n > 0 else [""]


def unread(base: Side, head: Side, keep=None) -> list[str]:
    """A note for the files that changed (or exist on one side only) and were not read, so that a table built from
    what was read is not taken for the whole story. `keep` selects the paths that matter to the section."""
    paths = sorted(p for p in base.skipped | head.skipped
                   if base.files.get(p) != head.files.get(p) and (keep is None or keep(p)))
    if not paths:
        return []
    shown = ", ".join(code(p, 70) for p in paths[:5]) + (f", and {len(paths) - 5} more" if len(paths) > 5 else "")
    return [f"_Not read (over {MAX_BLOB // 1_000_000} MB or unreadable), so missing from the above: {shown}._", ""]


def moved_pins(base: Side, head: Side) -> list[str]:
    o, n = base.pins(), head.pins()
    return sorted(k for k in set(o) | set(n) if o.get(k) != n.get(k))


def compare_url(repo, old, new) -> str:
    m = GITHUB_REPO.fullmatch(str(repo or ""))
    ok = SHA.fullmatch(str(old or "")) and SHA.fullmatch(str(new or ""))
    return f"https://github.com/{m.group(1)}/{m.group(2)}/compare/{old}...{new}" if m and ok else ""


# --- sections: each returns its markdown lines ---------------------------------------------------------------------

def sources_section(base: Side, head: Side, limit: int) -> list[str]:
    old, new = base.json(LOCK) or {}, head.json(LOCK) or {}
    rows = []
    for name in sorted(set(old) | set(new)):
        a, b = old.get(name), new.get(name)
        a, b = (a if isinstance(a, dict) else {}), (b if isinstance(b, dict) else {})
        if a == b:
            continue
        trust = b.get("trust") or a.get("trust")
        what = (f"{code(sha7(a.get('sha')))} -> {code(sha7(b.get('sha')))}" if a and b
                else f"new at {code(sha7(b.get('sha')))}" if b else "removed")
        if a and b and a.get("ref") != b.get("ref"):
            what += f", ref {code(a.get('ref'))} -> {code(b.get('ref'))}"
        link = compare_url(b.get("repo") or a.get("repo"), a.get("sha"), b.get("sha"))
        rows.append(f"| {code(name)} | {code(trust)} | {what} | {'[compare](' + link + ')' if link else '-'} |")
    o, n = base.pins(), head.pins()
    for name in sorted(set(o) | set(n)):
        if o.get(name) == n.get(name):
            continue
        (url0, sha0), (url1, sha1) = o.get(name, ("", "")), n.get(name, ("", ""))
        what = (f"{code(sha7(sha0))} -> {code(sha7(sha1))}" if sha0 and sha1
                else f"new at {code(sha7(sha1))}" if sha1 else "removed")
        link = compare_url(url1 or url0, sha0, sha1)
        rows.append(f"| {code(name)} | pinned | {what} | {'[compare](' + link + ')' if link else '-'} |")
    if not rows:
        return []
    return ["#### Sources", "", "| Source | Trust | Commit | Changes |", "|---|---|---|---|",
            *rows[:limit], *more(len(rows) - limit)]


def classify(base: Side, head: Side):
    b, h = base.files, head.files
    return (sorted(p for p in h if p not in b), sorted(p for p in h if p in b and h[p] != b[p]),
            sorted(p for p in b if p not in h))


def plugins_section(base: Side, head: Side, changes, limit: int) -> list[str]:
    per = collections.defaultdict(lambda: [0, 0, 0])
    for i, group in enumerate(changes):
        for p in group:
            bits = p.split("/")
            if bits[0] == "plugins" and len(bits) > 2:
                per[bits[1]][i] += 1
    if not per:
        return []
    bp, hp = base.plugins(), head.plugins()
    rows = []
    for name, (a, m, r) in sorted(per.items(), key=lambda kv: (-sum(kv[1]), kv[0])):
        v0, v1 = base.version(name), head.version(name)
        ver = "new plugin" if name not in bp else "plugin removed" if name not in hp else ""
        if v0 != v1:
            ver = (ver + ", " if ver else "") + f"{code(v0) if v0 else 'none'} -> {code(v1) if v1 else 'none'}"
        rows.append(f"| {code(name)} | {a} | {m} | {r} | {ver or '-'} |")
    return ["#### Plugins", "", "| Plugin | Added | Modified | Removed | Version |", "|---|--:|--:|--:|---|",
            *rows[:limit], *more(len(rows) - limit)]


def skills_section(base: Side, head: Side, limits: dict):
    """(lines, (new, removed, changed) counts, budget text)."""
    old, new = base.skills(), head.skills()
    # Keyed by name and file: two SKILL.md files of a plugin can carry the same name, and a second one must show
    o, n = {(s.qualified, s.path): s for s in old}, {(s.qualified, s.path): s for s in new}
    copies = collections.Counter(s.qualified for s in new)
    for q, c in collections.Counter(s.qualified for s in old).items():
        copies[q] = max(copies[q], c)

    def label(key) -> str:
        """The skill's name; a name that more than one SKILL.md carries also names the file."""
        return code(key[0]) + (f" (duplicate name, {code(key[1], 70)})" if copies[key[0]] > 1 else "")

    rows = [(0, k, f"| new | {label(k)} | {len(n[k].routing_text)} | {yes(n[k].model_invocable)} |")
            for k in sorted(n.keys() - o.keys())]
    rows += [(1, k, f"| removed | {label(k)} | {len(o[k].routing_text)} | {yes(o[k].model_invocable)} |")
             for k in sorted(o.keys() - n.keys())]
    changed = []
    for k in sorted(o.keys() & n.keys()):
        a, b = o[k], n[k]
        if a.model_invocable != b.model_invocable:
            changed.append((0, f"| invocability changed | {label(k)} | {len(a.routing_text)} -> {len(b.routing_text)} "
                               f"| {yes(a.model_invocable)} -> {yes(b.model_invocable)} |"))
        elif a.routing_text != b.routing_text:
            d = len(b.routing_text) - len(a.routing_text)
            changed.append((1 + 100000 - abs(d), f"| description changed | {label(k)} | {len(a.routing_text)} -> "
                                                f"{len(b.routing_text)} ({d:+d}) | {yes(b.model_invocable)} |"))
    changed.sort(key=lambda r: r[0])
    cost0, cost1 = sum(map(listing_chars, old)), sum(map(listing_chars, new))
    inv0, inv1 = sum(s.model_invocable for s in old), sum(s.model_invocable for s in new)
    budget = (f"{cost0} -> {cost1} ({cost1 - cost0:+d})" if cost0 != cost1 else f"unchanged ({cost1})")
    out = ["#### Skills", ""]
    if rows or changed:
        shown = [r for _k, _q, r in rows[:limits["skills"]]] + [r for _k, r in changed[:limits["changed"]]]
        hidden = max(len(rows) - limits["skills"], 0) + max(len(changed) - limits["changed"], 0)
        out += ["| Change | Skill | Description chars | Model-invocable |", "|---|---|--:|---|", *shown, *more(hidden)]
    out += [f"Model-invocable skills: {inv0} -> {inv1}. Their description characters (description plus when_to_use, "
            f"each counted up to {sd.LISTING_CAP}; commands are not counted), which the skill listing budget is spent "
            f"on: {budget}.", ""]
    out += unread(base, head, lambda p: p.startswith("plugins/") and posixpath.basename(p) in ("SKILL.md", "plugin.json"))
    return out, (len(n.keys() - o.keys()), len(o.keys() - n.keys()), len(changed)), budget


WITHHELD = "(text left out, open the file)"
UNREADABLE = "(entry that could not be read, open the file)"


def describe_handler(handler: str, show: bool = True) -> str:
    try:
        h = json.loads(handler)
    except ValueError:
        h = None
    if not isinstance(h, dict):
        return clean(handler, 160) if show else WITHHELD
    kind = h.get("type", "handler")
    if not show:
        return f"{clean(kind, 20)}: {WITHHELD}"
    return clean(f"{kind}: {h.get('command') or h.get('prompt') or h.get('url') or ''}", 160)


def describe_frontmatter(frontmatter: str, helpers: dict, show: bool = True) -> str:
    """A hook in the frontmatter of a skill, agent or command: the frontmatter from its hooks key on (what comes
    before it, the description, says nothing about the hook)."""
    if not show:
        return f"frontmatter hooks: {WITHHELD}"
    m = helpers["FM_HOOKS_KEY"].search(frontmatter)
    return clean("frontmatter " + (frontmatter[m.start():] if m else frontmatter), 240)


def server_entries(side: Side, plugin: str, kind: str) -> dict[tuple[str, str], str]:
    """{(file, server name): canonical config} of the MCP or LSP servers a plugin declares: the manifest key
    (inline map, or the path of a file in the plugin) and the conventional files."""
    key = "mcpServers" if kind == "mcp" else "lspServers"
    names = [".mcp.json", "mcp.json"] if kind == "mcp" else [".lsp.json", "lsp.json"]
    base = f"plugins/{plugin}"
    out: dict[tuple[str, str], str] = {}

    def add(rel: str, data) -> None:
        if isinstance(data, dict) and isinstance(data.get(key), dict):
            data = data[key]
        for name, cfg in (data.items() if isinstance(data, dict) else []):
            if isinstance(cfg, dict):
                out[(rel, str(name))] = json.dumps(cfg, sort_keys=True, ensure_ascii=False)

    for man in (f"{base}/.claude-plugin/plugin.json", f"{base}/plugin.json"):
        data = side.json(man)
        value = data.get(key) if isinstance(data, dict) else None
        for item in value if isinstance(value, list) else [] if value is None else [value]:
            if isinstance(item, dict):
                add(man, item)
            elif isinstance(item, str):
                ref = posixpath.normpath(posixpath.join(posixpath.dirname(posixpath.dirname(man)) if "/.claude-plugin/" in man
                                                        else posixpath.dirname(man), item))
                if ref.startswith(base + "/"):
                    add(ref, side.json(ref))
    for f in names:
        if f"{base}/{f}" in side.files:
            add(f"{base}/{f}", side.json(f"{base}/{f}"))
    return out


def describe_server(cfg_json: str, show: bool = True) -> str:
    cfg = json.loads(cfg_json)
    kind = clean(cfg.get("type", "stdio"), 20)
    if not show:
        return f"{kind}: {WITHHELD}"
    args = cfg.get("args")
    what = cfg.get("url") or " ".join(str(x) for x in [cfg.get("command", ""), *(args if isinstance(args, list) else [])])
    return clean(f"{kind}: {what}", 180)


def registrations_section(base: Side, head: Side, limit: int, show: bool = True) -> list[str]:
    helpers = validate_helpers()
    paths = {p for p in set(base.files) | set(head.files) if p.startswith("plugins/")} | {MARKETPLACE}
    cfg_old, cfg_new = helpers["hook_configs"](paths, base.text), helpers["hook_configs"](paths, head.text)
    items = []  # (plugin, kind, change, registration, file); one entry that cannot be read must not hide the others
    for rel in sorted(set(cfg_old) | set(cfg_new)):
        plugin = rel.split("/")[1] if rel.startswith("plugins/") else "(marketplace)"
        old = collections.Counter(cfg_old.get(rel, ("", []))[1])
        new = collections.Counter(cfg_new.get(rel, ("", []))[1])
        for change, diff in (("added", new - old), ("removed", old - new)):
            for (event, matcher, handler), _n in sorted(diff.items()):
                try:
                    if rel.endswith(".md"):
                        what = describe_frontmatter(handler, helpers, show)
                    else:
                        try:
                            m = json.loads(matcher).get("matcher")
                        except (ValueError, AttributeError):
                            m = matcher
                        what = f"{clean(event, 40)}{' [' + clean(m, 40) + ']' if m else ''}: {describe_handler(handler, show)}"
                except Exception as e:  # noqa: BLE001
                    print(f"sync-digest: {rel}: {type(e).__name__}: {clean(e, 200)}", file=sys.stderr)
                    what = UNREADABLE
                items.append((plugin, "hook", change, what, rel))
    for plugin in sorted(base.plugins() | head.plugins()):
        for kind in ("mcp", "lsp"):
            try:
                a, b = server_entries(base, plugin, kind), server_entries(head, plugin, kind)
            except Exception as e:  # noqa: BLE001
                print(f"sync-digest: {plugin} {kind}: {type(e).__name__}: {clean(e, 200)}", file=sys.stderr)
                items.append((plugin, kind, "unknown", UNREADABLE, f"plugins/{plugin}"))
                continue
            for k in sorted(a.keys() | b.keys()):
                if a.get(k) != b.get(k):
                    change = "added" if k not in a else "removed" if k not in b else "changed"
                    try:
                        what = f"{clean(k[1], 40)}: {describe_server(b.get(k) or a.get(k), show)}"
                    except Exception as e:  # noqa: BLE001
                        print(f"sync-digest: {k[0]}: {type(e).__name__}: {clean(e, 200)}", file=sys.stderr)
                        what = f"{clean(k[1], 40)}: {UNREADABLE}"
                    items.append((plugin, kind, change, what, k[0]))
    pins, skipped = moved_pins(base, head), unread(base, head)
    out = ["#### Hooks, MCP and LSP servers", ""]
    if not show:
        out += ["_The command, URL and prompt text of the registrations is left out; open the file in the last column._", ""]
    if items:
        out += ["| Plugin | Kind | Change | Registration | File |", "|---|---|---|---|---|"]
        out += [f"| {code(p)} | {k} | {c} | {code(r, 240)} | {code(f, 70)} |" for p, k, c, r, f in items[:limit]]
        out += more(len(items) - limit)
    elif skipped:
        out += ["None found in the files that could be read.", ""]
    else:
        out += [f"None added, removed or changed{' in this tree' if pins else ''}.", ""]
    if pins:
        names = ", ".join(code(p, 40) for p in pins[:5]) + (f", and {len(pins) - 5} more" if len(pins) > 5 else "")
        out += [f"Plugins pinned to an upstream commit ({names}) are not in this tree: what their new commit registers "
                "is not listed here (see Sources and, in the low-trust PR, Pinned plugins).", ""]
    return out + skipped


def also_section(base: Side, head: Side, changes, limit: int) -> list[str]:
    added, modified, removed = changes
    lines = []
    outside = sorted({p for p in added + modified + removed if not p.startswith("plugins/")})
    if outside:
        lines.append(f"- Outside `plugins/` ({len(outside)}): " + ", ".join(code(p, 50) for p in outside[:limit])
                     + (f", and {len(outside) - limit} more" if len(outside) > limit else ""))
    entry = re.compile(r"^plugins/[^/]+/(agents|commands)/[^/]+\.md$")
    scripts = [(s, p) for s, group in (("added", added), ("removed", removed)) for p in group
               if p.startswith("plugins/") and (entry.match(p) or posixpath.splitext(p)[1].lower() in SCRIPT_EXT)]
    if scripts:
        lines.append(f"- Agents, commands and scripts added or removed ({len(scripts)}): "
                     + ", ".join(f"{s} {code(p, 80)}" for s, p in scripts[:limit])
                     + (f", and {len(scripts) - limit} more" if len(scripts) > limit else ""))
    h, b = head.files, base.files
    for noun, what, group in (("symlink", "added or changed", [p for p in added + modified if h[p][0] == "120000"]),
                              ("submodule", "added or changed", [p for p in added + modified if h[p][0] == "160000"]),
                              ("file", "new or newly executable", [p for p in added + modified
                                                                   if h[p][0] == "100755" and b.get(p, ("",))[0] != "100755"])):
        if group:
            lines.append(f"- {len(group)} {noun}{'' if len(group) == 1 else 's'} {what}: "
                         + ", ".join(code(p, 70) for p in group[:3])
                         + (f", and {len(group) - 3} more" if len(group) > 3 else ""))
    return ["#### Also", "", *lines, ""] if lines else []


# --- assembly -----------------------------------------------------------------------------------------------------

def note(section: str, err: Exception) -> list[str]:
    # the message can carry upstream text: one line, so that no log line starts with something other than ours
    print(f"sync-digest: {section}: {type(err).__name__}: {clean(err, 200)}", file=sys.stderr)
    return [f"_{section} could not be read ({type(err).__name__}); see the step log._", ""]


def build(base: Side, head: Side, base_sha: str, limits: dict, show: bool = True) -> str:
    changes = classify(base, head)
    n_files = sum(map(len, changes))
    plugs = {p.split("/")[1] for g in changes for p in g if p.startswith("plugins/") and p.count("/") >= 2}
    body, counts, budget = [], ("?", "?", "?"), "?"
    for name, fn in (("Sources", lambda: sources_section(base, head, limits["sources"])),
                     ("Plugins", lambda: plugins_section(base, head, changes, limits["plugins"])),
                     ("Skills", lambda: skills_section(base, head, limits)),
                     ("Hooks, MCP and LSP servers", lambda: registrations_section(base, head, limits["registrations"], show)),
                     ("Also", lambda: also_section(base, head, changes, limits["other"]))):
        try:
            res = fn()
            if name == "Skills":
                res, counts, budget = res
            body += res
        except Exception as e:  # noqa: BLE001 - a broken section must not take the others down
            body += note(name, e)
    top = (f"Compared with {code(base_sha)}: {n_files} files changed ({len(changes[0])} added, {len(changes[1])} "
           f"modified, {len(changes[2])} removed; a rename counts as one removal and one addition) in {len(plugs)} "
           f"plugin{'' if len(plugs) == 1 else 's'}. Skills: {counts[0]} new, {counts[1]} removed, {counts[2]} with a "
           f"changed description or invocability. Description characters of model-invocable skills: {budget}.")
    return "\n".join(["### Digest of the changes", "", top, "", *body]).rstrip() + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--base", required=True, metavar="REF", help="git ref to compare with")
    ap.add_argument("--head", metavar="REF", help="git ref to compare; default: HEAD plus the working tree")
    ap.add_argument("--max-bytes", type=int, default=12000, help="upper bound of the output (default 12000)")
    ap.add_argument("--no-commands", action="store_true",
                    help="leave the command, URL and prompt text out of the hook, MCP and LSP registrations")
    args = ap.parse_args()
    args.max_bytes = max(args.max_bytes, 1000)
    try:
        base_tree = tree_of(args.base, "--base")
        head_tree = tree_of(args.head, "--head") if args.head else worktree_tree()
        base_sha = git("rev-parse", "--short=7", f"{args.base}^{{commit}}").decode().strip()
    except UnknownRef as e:
        print(f"sync-digest: {e}", file=sys.stderr)
        return 2
    except (subprocess.CalledProcessError, OSError) as e:
        print(f"sync-digest: cannot resolve the trees to compare: {clean(e, 200)}", file=sys.stderr)
        return 2
    if base_tree == head_tree:
        return 0
    blobs = Blobs()
    try:
        base, head = Side(base_tree, blobs), Side(head_tree, blobs)
        limits = dict(LIMITS)
        out = build(base, head, base_sha, limits, not args.no_commands)
        while len(out.encode()) > args.max_bytes and any(v > 3 for v in limits.values()):
            limits = {k: max(3, v // 2) for k, v in limits.items()}
            out = build(base, head, base_sha, limits, not args.no_commands)
        if len(out.encode()) > args.max_bytes:
            out = "\n\n".join(out.split("\n\n")[:2]) + "\n\n_The details do not fit in the PR body; see the Files changed tab._\n"
    except Exception as e:  # noqa: BLE001
        print(f"sync-digest: {type(e).__name__}: {clean(e, 200)}", file=sys.stderr)
        print(f"_The change digest could not be built ({type(e).__name__}); see the step log._")
        return 0
    finally:
        blobs.close()
    sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
