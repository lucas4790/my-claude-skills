#!/usr/bin/env python3
"""Validates marketplace.json, every plugin manifest and SKILL.md, and that SKILLS.md is current. Exit 1 on any problem."""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
problems: list[str] = []
warnings: list[str] = []
SUSPICIOUS = [
    (r"ignore (all )?(previous|prior|above) instructions", "prompt-injection phrase"),
    (r"curl[^\n|]*\|\s*(ba)?sh", "curl | sh pipeline"),
    (r"base64\s+(-d|--decode)", "base64 decode"),
    (r"[\u200b\u200c\u200d\u2060\ufeff]", "zero-width/invisible unicode"),
    (r"\$\{?CLAUDE_API_KEY|ANTHROPIC_API_KEY", "API key reference"),
]


def frontmatter(text: str) -> dict | None:
    m = re.match(r"^---\s*\n(.*?)\n---", text, re.S)
    if not m:
        return None
    keys = {}
    for line in m.group(1).splitlines():
        km = re.match(r"^([A-Za-z_-]+):\s*(.*)$", line)
        if km:
            keys[km.group(1)] = km.group(2)
    return keys


def check_json(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        problems.append(f"{path.relative_to(ROOT)}: invalid JSON ({e})")
        return None


mp = check_json(ROOT / ".claude-plugin/marketplace.json") or {"plugins": []}
names = [p.get("name") for p in mp["plugins"]]
for n in set(names):
    if names.count(n) > 1:
        problems.append(f"marketplace.json: duplicate plugin name {n!r}")

for p in mp["plugins"]:
    name, src = p.get("name"), p.get("source")
    if not name or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
        problems.append(f"marketplace.json: bad plugin name {name!r}")
    if isinstance(src, dict):
        if src.get("source") == "url" and not src.get("url", "").startswith("https://"):
            problems.append(f"{name}: url source must be https")
        if src.get("source") in ("url", "github") and not re.fullmatch(r"[0-9a-f]{40}", src.get("sha", "")):
            problems.append(f"{name}: external source must be pinned with a 40-char sha")
        continue
    pdir = ROOT / src
    if not pdir.is_dir():
        problems.append(f"{name}: source dir {src} missing")
        continue
    manifest = pdir / ".claude-plugin/plugin.json"
    mj = None
    if not manifest.exists():
        problems.append(f"{name}: missing {manifest.relative_to(ROOT)}")
    else:
        mj = check_json(manifest)
        if mj and mj.get("name") != name:
            problems.append(f"{name}: plugin.json name {mj.get('name')!r} != marketplace name")
        if mj and isinstance(mj.get("skills"), list):
            for s in mj["skills"]:
                if not (pdir / s / "SKILL.md").exists() and not s.rstrip("/").endswith("skills"):
                    problems.append(f"{name}: plugin.json skill path {s} has no SKILL.md")
    skill_files = list(pdir.rglob("SKILL.md"))
    has_content = skill_files or any((pdir / d).is_dir() for d in ("commands", "agents", "hooks")) \
        or (pdir / ".mcp.json").exists() or "lspServers" in p or (mj and "lspServers" in mj)
    if not has_content:
        problems.append(f"{name}: plugin has no skills, commands, agents, hooks, MCP or LSP")

for f in ROOT.glob("plugins/**/SKILL.md"):
    rel = f.relative_to(ROOT)
    text = f.read_text(encoding="utf-8", errors="replace")
    fm = frontmatter(text)
    if fm is None:
        problems.append(f"{rel}: no YAML frontmatter")
        continue
    if not fm.get("name"):
        problems.append(f"{rel}: frontmatter missing name")
    if "description" not in fm:
        problems.append(f"{rel}: frontmatter missing description")
    if len(text) > 200_000:
        problems.append(f"{rel}: over 200 KB")
    for pattern, label in SUSPICIOUS:
        if re.search(pattern, text, re.I):
            warnings.append(f"{rel}: {label} — read before trusting")

for f in ROOT.glob("plugins/**/*"):
    if f.is_file() and f.stat().st_size > 5_000_000:
        problems.append(f"{f.relative_to(ROOT)}: file over 5 MB")

before = (ROOT / "SKILLS.md").read_text(encoding="utf-8") if (ROOT / "SKILLS.md").exists() else ""
subprocess.run([sys.executable, str(ROOT / "scripts/gen-catalog.py")], check=True, capture_output=True)
if (ROOT / "SKILLS.md").read_text(encoding="utf-8") != before:
    problems.append("SKILLS.md was stale (regenerated now; commit it)")

if warnings:
    print("\n".join(f"⚠ {w}" for w in warnings))
if problems:
    print("\n".join(f"✗ {p}" for p in problems))
    sys.exit(1)
print(f"✓ {len(mp['plugins'])} plugins, {len(list(ROOT.glob('plugins/**/SKILL.md')))} skills valid")
