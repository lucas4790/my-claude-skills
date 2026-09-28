#!/usr/bin/env python3
"""Validates marketplace.json, every plugin manifest and SKILL.md, that SKILLS.md is current,
scans vendored content for prompt-injection / exfiltration patterns, and warns about skill
descriptions that route badly (scripts/skill_descriptions.py: too short/long, no "Use when ..."
phrase, two skills that share most of their distinctive words). Description warnings never change
the exit code; with --diff they cover only SKILL.md files changed since REF.

  validate.py               structural checks + full injection scan (warnings only)
  validate.py --diff REF    structural checks + injection scan of lines ADDED since REF
                            (git diff REF plus untracked files); high-severity hits exit 2
  validate.py --diff REF --warn-only
                            same, but injection hits never fail (for jobs that already open a PR)

Exit codes: 0 ok, 1 structural problem, 2 high-severity injection hit in added lines.
"""
import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

# No scripts/__pycache__: the sync job runs this script and then `git add -A`.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from skill_descriptions import routing_warnings  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # Windows consoles default to cp1252
problems: list[str] = []
warnings: list[str] = []
injections: list[str] = []  # high-severity hits in --diff mode

# Everything under plugins/ that Claude reads or runs. Binary/media files are skipped.
TEXT_EXT = {".md", ".txt", ".json", ".yaml", ".yml", ".toml", ".xml", ".html",
            ".sh", ".ps1", ".py", ".js", ".mjs", ".cjs", ".ts"}

# (regex, label, severity). "high" = a human must look before this reaches main;
# "low" = worth a glance in the PR body. Matched case-insensitively, per file.
SUSPICIOUS = [
    # instructions aimed at the model rather than the user
    (r"(ignore|disregard|forget)\s+(all\s+)?(the\s+)?(previous|prior|above|earlier|your)\s+(instructions?|rules|guidelines|prompts?)",
     "override-instructions phrase", "high"),
    (r"(you are now|new (system )?instructions?:|override (the )?(system|developer) (prompt|message))",
     "system-prompt override phrase", "high"),
    (r"(do not|don'?t|never)\s+(tell|inform|mention|show|reveal|disclose)( this| that| it)?( to)?\s+the\s+user",
     "hide-from-user phrase", "high"),
    (r"without\s+(telling|asking|informing|notifying|confirming with)\s+the\s+user", "bypass-user phrase", "high"),
    (r"\b(secretly|covertly|silently exfiltrate|hide (this|it) from the user)\b", "covert-action phrase", "high"),
    (r"<!--(?:(?!-->).)*?\b(ignore|you must|you should|instructions?|system prompt|assistant|claude)\b(?:(?!-->).)*?-->",
     "HTML comment containing instructions", "high"),
    # exfiltration channels
    (r"(webhook\.site|requestbin|pipedream\.net|ngrok(-free)?\.(io|app|dev)|burpcollaborator|interact\.sh|oast\.(fun|live|me|pro|site)|hooks\.slack\.com|discord(app)?\.com/api/webhooks)",
     "exfiltration/webhook host", "high"),
    (r"!\[[^\]]*\]\(https?://[^)]*\?[^)]*\)", "external image with query string (exfil vector)", "high"),
    (r"!\[[^\]]*\]\(https?://", "external image", "low"),
    # credentials and tokens
    (r"(~|\$HOME|%USERPROFILE%)[/\\]\.(ssh|aws|azure|kube|gnupg|netrc|npmrc|docker/config\.json)\b|\bid_(rsa|ed25519)\b|\.credentials\.json",
     "credential path", "high"),
    (r"\b(gh auth token|az account get-access-token|aws sts get-session-token|gcloud auth print-(access|identity)-token)\b",
     "token-minting command", "high"),
    (r"\$\{?CLAUDE_API_KEY|ANTHROPIC_API_KEY|\bAWS_SECRET_ACCESS_KEY\b|\bGITHUB_TOKEN\b", "API key / secret reference", "high"),
    # remote code execution
    (r"(curl|wget)[^\n|]*\|\s*(sudo\s+)?(ba|z)?sh\b", "curl | sh pipeline", "high"),
    (r"\b(irm|iwr|Invoke-RestMethod|Invoke-WebRequest)\b[^\n|]*\|\s*(iex|Invoke-Expression)\b", "irm | iex pipeline", "high"),
    (r"base64\s+(-d|--decode)[^\n|]*\|\s*(ba|z)?sh\b", "base64 | sh pipeline", "high"),
    (r"base64\s+(-d|--decode)", "base64 decode", "low"),
    # line-scoped (works without re.M) and skipped on lines containing "http": long URLs match the class too
    (r"(?<![^\n])(?![^\n]*http)[^\n]*?[A-Za-z0-9+/]{120,}={0,2}", "long base64-looking blob", "low"),
    (r"\b(eval|exec|Invoke-Expression|iex)\s*\(", "dynamic code execution", "low"),
    # hooks run automatically; a newly added one deserves eyes
    (r"\"(SessionStart|UserPromptSubmit|PreToolUse|PostToolUse|Stop|SubagentStop|Notification|PreCompact)\"\s*:",
     "hook event registration", "high"),
    # text hidden from a human reader
    (r"[\u200b\u200c\u200d\u2060\ufeff]", "zero-width/invisible unicode", "high"),
    (r"[\u202a-\u202e\u2066-\u2069]", "bidi override unicode", "high"),
]
COMPILED = [(re.compile(p, re.I | re.S), label, sev) for p, label, sev in SUSPICIOUS]

# Hook registrations the owner reviewed: scripts/reviewed-hooks.json maps a file under plugins/ to the sha256
# of its content (CRLF read as LF). While a listed file is unchanged, its hook registration is reported as
# [reviewed] instead of [high]; any edit changes the hash, so the registration fails --diff again until the
# new content is reviewed and the hash updated in the same PR. Filled in just before the injection scan.
REVIEWED_HOOKS: dict[str, str] = {}


def content_sha256(rel: str) -> str:
    try:
        return hashlib.sha256((ROOT / rel).read_bytes().replace(b"\r\n", b"\n")).hexdigest()
    except OSError:
        return ""


def scan(rel: str, text: str, line_numbers: list[int] | None, fail_high: bool) -> None:
    """Report the first hit per pattern. line_numbers maps 0-based line index of `text`
    to a display line number (None = identity, for whole-file scans)."""
    for rx, label, sev in COMPILED:
        m = rx.search(text)
        if not m:
            continue
        # A quoted phrase ("ignore previous instructions") is nearly always a skill *describing*
        # injection to defend against it, not performing it.
        if sev == "high" and label.endswith("phrase") and m.start() > 0 and text[m.start() - 1] in "\"'`“‘":
            sev = "low"
        if sev == "high" and label == "hook event registration" and rel in REVIEWED_HOOKS \
                and REVIEWED_HOOKS[rel] == content_sha256(rel):
            sev = "reviewed"
        idx = text.count("\n", 0, m.start())
        ln = line_numbers[idx] if line_numbers and idx < len(line_numbers) else idx + 1
        n = sum(1 for _ in rx.finditer(text))
        more = f" (+{n - 1} more)" if n > 1 else ""
        msg = f"{rel}:{ln}: [{sev}] {label}{more}"
        if sev == "high" and fail_high:
            injections.append(msg)
        else:
            warnings.append(msg)


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=True).stdout


def added_lines(ref: str) -> dict[str, tuple[list[int], list[str]]]:
    """{path: (line numbers, lines)} for every line added under plugins/ since REF,
    including whole untracked files (sync.sh copies new files in unstaged)."""
    out: dict[str, tuple[list[int], list[str]]] = {}
    try:
        # -z: paths verbatim; the patch headers C-quote non-ASCII names and tab-terminate names with spaces
        changed = git("diff", "--name-only", "-z", "--no-renames", ref, "--", "plugins/").split("\0")
    except subprocess.CalledProcessError:
        print(f"✗ --diff: unknown git ref '{ref}'")
        sys.exit(1)
    for path in changed:
        # same file-type filter as the untracked-file loop below
        if not path or Path(path).suffix not in TEXT_EXT:
            continue
        ln, in_hunk = 0, False
        for line in git("diff", "--no-renames", "-U0", "--no-color", ref, "--", f":(literal){path}").splitlines():
            if line.startswith("@@"):
                m = re.match(r"@@ -\S+ \+(\d+)", line)
                ln, in_hunk = (int(m.group(1)) if m else 0), True
            elif in_hunk and line.startswith("+"):  # past the headers even "+++…" is an added line
                nums, lines = out.setdefault(path, ([], []))
                nums.append(ln)
                lines.append(line[1:])
                ln += 1
            # removed lines ("-") do not advance the new-file line counter
    for path in git("ls-files", "-z", "--others", "--exclude-standard", "--", "plugins/").split("\0"):
        if path and Path(path).suffix in TEXT_EXT:
            lines = (ROOT / path).read_text(encoding="utf-8", errors="replace").splitlines()
            out[path] = (list(range(1, len(lines) + 1)), lines)
    return out


ap = argparse.ArgumentParser()
ap.add_argument("--diff", metavar="REF", help="scan only lines added since this git ref")
ap.add_argument("--warn-only", action="store_true", help="injection hits never fail the run")
args = ap.parse_args()


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
    # Copilot CLI reads a root plugin.json before .claude-plugin/plugin.json (Claude Code ignores it)
    root_manifest = pdir / "plugin.json"
    if root_manifest.exists():
        rj = check_json(root_manifest)
        if rj and rj.get("name") != name:
            problems.append(f"{name}: root plugin.json name {rj.get('name')!r} != marketplace name")
        if rj and "agent-plugins.org" in str(rj.get("$schema", "")):
            warnings.append(f"{name}: root plugin.json declares Agent Plugins 1.0; VS Code will ignore .claude-plugin/ layout")
        lsp = (rj or {}).get("lspServers")
        for srv, cfg in (lsp.items() if isinstance(lsp, dict) else []):
            if isinstance(cfg, dict) and "fileExtensions" not in cfg:
                warnings.append(f"{name}: root plugin.json LSP {srv!r} has no fileExtensions (Copilot rejects it)")
    elif mj and isinstance(mj.get("lspServers"), dict):
        warnings.append(f"{name}: LSP only in .claude-plugin/plugin.json; add a root plugin.json with fileExtensions for Copilot")
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
    # Agent Skills spec (VS Code, Copilot): name must equal the folder and be lowercase-hyphen, <= 64 chars.
    # VS Code silently skips a skill that breaks this, so warn (vendored content is fixed upstream).
    sname = fm.get("name", "").strip().strip("'\"")
    if sname and (sname != f.parent.name or not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", sname) or len(sname) > 64):
        warnings.append(f"{rel}: name {sname!r} breaks the Agent Skills rule (must equal folder {f.parent.name!r}, [a-z0-9-], <= 64)")
    if len(text) > 200_000:
        problems.append(f"{rel}: over 200 KB")

# profiles.json: every marketplace plugin in exactly one profile, and nothing else
prof = check_json(ROOT / "profiles.json") if (ROOT / "profiles.json").exists() else None
if prof is None:
    problems.append("profiles.json missing or invalid")
else:
    seen: dict[str, str] = {}
    for pname, members in (prof.get("profiles") or {}).items():
        for m in members:
            if m in seen:
                problems.append(f"profiles.json: {m!r} is in both {seen[m]!r} and {pname!r}")
            seen[m] = pname
    for n in names:
        if n not in seen:
            problems.append(f"profiles.json: marketplace plugin {n!r} is in no profile")
    for m in seen:
        if m not in names:
            problems.append(f"profiles.json: {m!r} is not a marketplace plugin")
    for d in prof.get("copilotDefault", []):
        if d not in (prof.get("profiles") or {}):
            problems.append(f"profiles.json: copilotDefault names unknown profile {d!r}")

for f in ROOT.glob("plugins/**/*"):
    if f.is_file() and f.stat().st_size > 5_000_000:
        problems.append(f"{f.relative_to(ROOT)}: file over 5 MB")

# --- injection scan -----------------------------------------------------------
reviewed_file = ROOT / "scripts/reviewed-hooks.json"
if reviewed_file.exists():
    listed = (check_json(reviewed_file) or {}).get("reviewed", {})
    for rel, digest in (listed.items() if isinstance(listed, dict) else []):
        current = content_sha256(rel)
        if not current:
            warnings.append(f"scripts/reviewed-hooks.json: {rel} does not exist; remove the entry")
        elif current != digest:
            warnings.append(f"scripts/reviewed-hooks.json: {rel} changed since it was reviewed; after reviewing it, "
                            f"set its hash to {current}")
        else:
            REVIEWED_HOOKS[rel] = digest
if args.diff:
    for path, (nums, lines) in added_lines(args.diff).items():
        scan(path, "\n".join(lines), nums, fail_high=not args.warn_only)
else:
    for f in ROOT.glob("plugins/**/*"):
        if f.is_file() and f.suffix in TEXT_EXT and f.stat().st_size <= 5_000_000:
            scan(f.relative_to(ROOT).as_posix(), f.read_text(encoding="utf-8", errors="replace"), None, fail_high=False)

# --- skill description routing (warnings only) ---------------------------------------------------
# In --diff mode only SKILL.md files changed since REF (and overlap pairs involving one), because the
# sync job copies these lines into the PR body.
desc_warnings = routing_warnings(ROOT, args.diff)

before = (ROOT / "SKILLS.md").read_text(encoding="utf-8") if (ROOT / "SKILLS.md").exists() else ""
gen = subprocess.run([sys.executable, str(ROOT / "scripts/gen-catalog.py")], capture_output=True, text=True)
if gen.returncode != 0:  # e.g. an invalid manifest (reported above): report it, do not crash before the ✗ lines
    problems.append(f"scripts/gen-catalog.py failed: {(gen.stderr.strip().splitlines() or ['no output'])[-1]}")
elif (ROOT / "SKILLS.md").read_text(encoding="utf-8") != before:
    problems.append("SKILLS.md was stale (regenerated now; commit it)")

if warnings:
    print("\n".join(f"⚠ {w}" for w in warnings))
if desc_warnings:
    print("\n".join(f"⚠ {w}" for w in desc_warnings))
if injections:
    print("\n".join(f"‼ {i}" for i in injections))
if problems:
    print("\n".join(f"✗ {p}" for p in problems))
    sys.exit(1)
if injections:
    print(f"‼ {len(injections)} high-severity hit(s) in lines added since {args.diff} — review before merging")
    sys.exit(2)
scope = f"lines added since {args.diff}" if args.diff else "full scan"
desc_scope = f"changed since {args.diff}" if args.diff else "all skills"
print(f"✓ {len(mp['plugins'])} plugins, {len(list(ROOT.glob('plugins/**/SKILL.md')))} skills valid; injection scan ({scope}): "
      f"{len(warnings)} warning(s); skill descriptions ({desc_scope}): {len(desc_warnings)} warning(s)")
