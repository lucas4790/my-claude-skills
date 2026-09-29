#!/usr/bin/env python3
"""Validates marketplace.json, every plugin manifest and SKILL.md, that SKILLS.md is current,
scans vendored content for prompt-injection / exfiltration patterns and hook registrations, and
warns about skill descriptions that route badly (scripts/skill_descriptions.py: too short/long, no
"Use when ..." phrase, two skills that share most of their distinctive words). Description warnings
never change the exit code; with --diff they cover only SKILL.md files changed since REF.

  validate.py               structural checks + full injection scan (warnings only)
  validate.py --diff REF    structural checks + injection scan of lines ADDED since REF
                            (git diff REF plus untracked files) and of hook registrations added or
                            changed since REF; high-severity hits exit 2
  validate.py --diff REF --warn-only
                            same, but injection hits never fail (for jobs that already open a PR)

Exit codes: 0 ok, 1 structural problem, 2 high-severity injection hit in added lines.
"""
import argparse
import collections
import hashlib
import json
import posixpath
import re
import subprocess
import sys
from pathlib import Path

# No scripts/__pycache__: the sync job runs this script and then `git add -A`.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from skill_descriptions import FRONTMATTER_RX, parse_frontmatter, routing_warnings, skill_files  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # Windows consoles default to cp1252
problems: list[str] = []
warnings: list[str] = []
injections: list[str] = []  # high-severity hits in --diff mode

# The injection scan reads every file under plugins/ that is text: these types always (a NUL byte, which
# makes git call a file binary, must not hide one from the scan), any other file (.gitattributes,
# LICENSE, a new language) when its first 8 KB hold no NUL byte. Images and other binaries are skipped.
TEXT_EXT = {".md", ".txt", ".json", ".yaml", ".yml", ".toml", ".xml", ".html",
            ".sh", ".bash", ".zsh", ".ps1", ".psm1", ".psd1", ".bat", ".cmd",
            ".py", ".rb", ".go", ".cs", ".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx"}


def is_text(rel: str) -> bool:
    if Path(rel).suffix.lower() in TEXT_EXT:
        return True
    try:
        with open(ROOT / rel, "rb") as fh:
            return b"\0" not in fh.read(8192)
    except OSError:  # deleted since REF, or unreadable
        return False

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
    # hooks run automatically; a newly added one deserves eyes. Hook config files are read structurally
    # (hook_configs, any event name); this pattern covers hook JSON in other text, e.g. a skill that tells
    # the model to add a hook to settings.json. Not after ==, != or case: code that compares event names.
    (r"(?<![=!]=\s)(?<![=!]=)(?<!case\s)\"(SessionStart|SessionEnd|UserPromptSubmit(ted)?|UserPromptExpansion|"
     r"PreToolUse|PostToolUse(Failure)?|PermissionRequest|Stop(Failure)?|SubagentStart|SubagentStop|Notification|"
     r"PreCompact|PostCompact|agentStop|errorOccurred)\"\s*:",
     "hook event registration", "high"),
    # text hidden from a human reader
    (r"[\u200b\u200c\u200d\u2060\ufeff]", "zero-width/invisible unicode", "high"),
    (r"[\u202a-\u202e\u2066-\u2069]", "bidi override unicode", "high"),
]
COMPILED = [(re.compile(p, re.I | re.S), label, sev) for p, label, sev in SUSPICIOUS]

# Hook registrations the owner reviewed: scripts/reviewed-hooks.json maps a file under plugins/ to the sha256
# of its content (CRLF read as LF). While a listed file is unchanged, its hook registration is reported as
# [reviewed] instead of [high]; any edit changes the hash, so the registration fails --diff again until the
# new content is reviewed and the hash updated in the same PR. The scripts a listed hook file runs through
# ${CLAUDE_PLUGIN_ROOT}/... are reviewed files too: each needs its own entry, and an edit of one fails --diff
# the same way. Filled in just before the injection scan.
REVIEWED_HOOKS: dict[str, str] = {}
# Hook config files in the working tree (hook_configs); the hook pattern of SUSPICIOUS skips them.
HOOK_FILES: set[str] = set()


def content_sha256(rel: str) -> str:
    try:
        return hashlib.sha256((ROOT / rel).read_bytes().replace(b"\r\n", b"\n")).hexdigest()
    except OSError:
        return ""


def scan(rel: str, text: str, line_numbers: list[int] | None, fail_high: bool) -> None:
    """Report each pattern once per file: its most severe hit (the first one of that severity) with a
    count of the others. line_numbers maps 0-based line index of `text` to a display line number
    (None = identity, for whole-file scans)."""
    for rx, label, sev in COMPILED:
        if label == "hook event registration" and rel in HOOK_FILES:
            continue  # read structurally, see hook_configs
        m, msev, n = None, "", 0
        for hit in rx.finditer(text):
            n += 1
            hsev = sev
            # A quoted phrase ("ignore previous instructions") is nearly always a skill *describing*
            # injection to defend against it, not performing it. Decided per hit: a quoted mention must
            # not hide an unquoted one later in the file.
            if sev == "high" and label.endswith("phrase") and hit.start() > 0 and text[hit.start() - 1] in "\"'`“‘":
                hsev = "low"
            if m is None or (hsev == "high" and msev != "high"):
                m, msev = hit, hsev
        if m is None:
            continue
        sev = msev
        if sev == "high" and label == "hook event registration" and rel in REVIEWED_HOOKS \
                and REVIEWED_HOOKS[rel] == content_sha256(rel):
            sev = "reviewed"
        idx = text.count("\n", 0, m.start())
        ln = line_numbers[idx] if line_numbers and idx < len(line_numbers) else idx + 1
        more = f" (+{n - 1} more)" if n > 1 else ""
        msg = f"{rel}:{ln}: [{sev}] {label}{more}"
        if sev == "high" and fail_high:
            injections.append(msg)
        else:
            warnings.append(msg)


def git(*args: str) -> str:
    # errors="replace": diffs of UTF-16 or Latin-1 files (--text shows them) must not crash the scan
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
                          errors="replace", check=True).stdout


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
        # same file-type filter as the untracked-file loop below and the full scan
        if not path or not is_text(path):
            continue
        ln, in_hunk = 0, False
        # --text etc.: a NUL byte or a `-diff` .gitattributes entry must not turn the added lines into
        # "Binary files differ" and so hide them from the scan
        for line in git("diff", "--text", "--no-textconv", "--no-ext-diff", "--no-renames", "-U0", "--no-color",
                        ref, "--", f":(literal){path}").splitlines():
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
        if path and is_text(path):
            lines = (ROOT / path).read_text(encoding="utf-8", errors="replace").splitlines()
            out[path] = (list(range(1, len(lines) + 1)), lines)
    return out


ap = argparse.ArgumentParser()
ap.add_argument("--diff", metavar="REF", help="scan only lines added since this git ref")
ap.add_argument("--warn-only", action="store_true", help="injection hits never fail the run")
args = ap.parse_args()


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
            # an explicit list is all that loads (and all SKILLS.md shows): a skill that sync.sh copies in
            # from a whole upstream folder would otherwise be vendored and scanned but never used
            listed = {f.resolve() for f in skill_files(pdir)}
            for f in sorted(pdir.rglob("SKILL.md")):
                if f.resolve() not in listed:
                    warnings.append(f"{name}: {f.relative_to(ROOT).as_posix()} is not in the plugin.json skills list, so it "
                                    f"is never loaded or catalogued; add its folder there (or exclude it in sources.json)")
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
    skill_mds = list(pdir.rglob("SKILL.md"))
    has_content = skill_mds or any((pdir / d).is_dir() for d in ("commands", "agents", "hooks")) \
        or (pdir / ".mcp.json").exists() or "lspServers" in p or (mj and "lspServers" in mj)
    if not has_content:
        problems.append(f"{name}: plugin has no skills, commands, agents, hooks, MCP or LSP")

for f in ROOT.glob("plugins/**/SKILL.md"):
    rel = f.relative_to(ROOT)
    text = f.read_text(encoding="utf-8", errors="replace")
    if not FRONTMATTER_RX.match(text):
        problems.append(f"{rel}: no YAML frontmatter")
        continue
    fm = parse_frontmatter(text)  # the parser SKILLS.md and the description checks use: quotes, > and | blocks
    if not fm.get("name", "").strip():
        problems.append(f"{rel}: frontmatter missing name")
    # the model routes on the description alone; skill_descriptions.py leaves an empty one to this check
    if "description" not in fm:
        problems.append(f"{rel}: frontmatter missing description")
    elif not fm["description"].strip():
        problems.append(f"{rel}: frontmatter has an empty description")
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
added = added_lines(args.diff) if args.diff else {}


def changed_since_ref(rel: str) -> bool:
    """rel differs from --diff REF in the working tree (any edit, deletions included) or is untracked."""
    return bool(git("diff", "--name-only", "--no-renames", args.diff, "--", f":(literal){rel}").strip()
                or git("ls-files", "--others", "--exclude-standard", "--", f":(literal){rel}").strip())


# --- hook registrations -----------------------------------------------------------------------------------
# Hooks run without asking, so registrations are read structurally, whatever the event name (Claude Code's
# SessionEnd, PermissionRequest, ..., Copilot's sessionStart, ...): every file named hooks.json, the `hooks`
# key of each plugin.json, .claude-plugin/plugin.json and marketplace.json entry (inline, or paths to more
# hook files) and the `hooks` key of a markdown frontmatter (skills and commands can carry hooks). With
# --diff, each registration that is new or changed since REF is a high-severity hit.
MARKETPLACE = ".claude-plugin/marketplace.json"
HOOK_META_KEYS = {"hooks", "description", "version", "$schema", "$comment"}


def canonical(value) -> str:
    return json.dumps(value, sort_keys=True, ensure_ascii=False)


def registrations(cfg) -> list[tuple[str, str, str]]:
    """(event, matcher, handler) for every handler of a hooks config: Claude Code's {"hooks": {Event:
    [{"matcher": .., "hooks": [handler]}]}}, Copilot's {"hooks": {event: [handler]}}, or the event map itself
    (a manifest's inline `hooks`). Matcher and handler are canonical JSON, so a changed command, `if`, type or
    timeout makes a new tuple. Other top-level keys of a hooks file (e.g. "modules") count as registrations."""
    if not isinstance(cfg, dict):
        return [("hooks", "", canonical(cfg))]
    events = cfg["hooks"] if isinstance(cfg.get("hooks"), dict) else cfg
    out = []
    for event, entries in events.items():
        if not isinstance(entries, list):
            continue  # "description", "version", ...
        for entry in entries:
            if isinstance(entry, dict) and isinstance(entry.get("hooks"), list):
                matcher = canonical({k: v for k, v in entry.items() if k != "hooks"})
                out += [(event, matcher, canonical(h)) for h in entry["hooks"]]
            else:
                out.append((event, "", canonical(entry)))
    return out + [(k, "", canonical(v)) for k, v in cfg.items() if events is not cfg and k not in HOOK_META_KEYS]


def hook_candidates(paths) -> set[str]:
    return {p for p in paths if p == MARKETPLACE or p.endswith(".md")
            or (p.startswith("plugins/") and posixpath.basename(p) in ("hooks.json", "plugin.json"))}


def hook_configs(paths: set[str], read) -> dict[str, tuple[str, list]]:
    """{file: (text, registrations)} of the hook configs among `paths`, read with read(rel) -> text or None."""
    out: dict[str, tuple[str, list]] = {}
    refs: set[str] = set()

    def hooks_file(rel: str, text: str) -> None:
        try:
            out[rel] = (text, registrations(json.loads(text)))
        except ValueError:  # not JSON: any edit is a new registration
            out[rel] = (text, [("<invalid JSON>", "", text)])

    for rel in sorted(hook_candidates(paths)):
        text = read(rel)
        if text is None:
            continue
        if rel.endswith(".md"):
            hooks = parse_frontmatter(text).get("hooks", "")
            if hooks:
                out[rel] = (text, [("hooks", "", hooks)])
        elif posixpath.basename(rel) == "hooks.json":
            hooks_file(rel, text)
        else:
            try:
                data = json.loads(text)
            except ValueError:
                continue  # an invalid manifest is a structural problem (check_json)
            if not isinstance(data, dict):
                continue
            if rel == MARKETPLACE:
                owners = [(posixpath.normpath(p["source"]), p) for p in data.get("plugins") or []
                          if isinstance(p, dict) and isinstance(p.get("source"), str)]
            else:
                base = posixpath.dirname(rel)
                owners = [(posixpath.dirname(base) if posixpath.basename(base) == ".claude-plugin" else base, data)]
            for base, obj in owners:
                value = obj.get("hooks")
                for item in value if isinstance(value, list) else [] if value is None else [value]:
                    if isinstance(item, str):  # a path to more hooks, relative to the plugin root
                        ref = posixpath.normpath(posixpath.join(base, item))
                        if ref.startswith("plugins/"):  # an installed plugin cannot reach anything else
                            refs.add(ref)
                    else:
                        out.setdefault(rel, (text, []))[1].extend(registrations(item))
    for rel in sorted(refs - set(out)):
        text = read(rel)
        if text is not None:
            hooks_file(rel, text)
    return out


def read_worktree(rel: str) -> str | None:
    try:
        return (ROOT / rel).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None


def hook_registration_hits(fail_high: bool) -> None:
    """One line per hook config file with registrations (with --diff: registrations new or changed since REF):
    [reviewed] while the file is listed unchanged in scripts/reviewed-hooks.json, [high] otherwise."""
    paths = {f.relative_to(ROOT).as_posix() for f in ROOT.glob("plugins/**/*") if f.is_file()} | {MARKETPLACE}
    current = hook_configs(paths, read_worktree)
    HOOK_FILES.update(current)
    old: dict[str, tuple[str, list]] = {}
    if args.diff:
        where = ("--", "plugins/", MARKETPLACE)
        changed = set(git("diff", "--name-only", "-z", "--no-renames", args.diff, *where).split("\0"))
        changed |= set(git("ls-files", "-z", "--others", "--exclude-standard", *where).split("\0"))

        def read_ref(rel: str) -> str | None:
            if rel not in changed:
                return read_worktree(rel)
            try:
                return git("show", f"{args.diff}:{rel}")
            except subprocess.CalledProcessError:  # new since REF
                return None
        old = hook_configs(paths | changed, read_ref)
    for rel, (text, regs) in current.items():
        left = collections.Counter(old.get(rel, ("", []))[1])
        new = []
        for r in regs:
            if left[r]:
                left[r] -= 1
            else:
                new.append(r)
        if not new:
            continue
        key = re.compile(r"^hooks\s*:", re.M) if rel.endswith(".md") else re.compile(rf'"{re.escape(new[0][0])}"\s*:')
        m = key.search(text)
        ln = text.count("\n", 0, m.start()) + 1 if m else 1
        sev = "reviewed" if rel in REVIEWED_HOOKS else "high"
        msg = f"{rel}:{ln}: [{sev}] hook event registration" + (f" (+{len(new) - 1} more)" if len(new) > 1 else "")
        (injections if sev == "high" and fail_high else warnings).append(msg)


def plugin_root(rel: str) -> str:
    """The marketplace plugin directory that holds rel (plugins/<name> when none does)."""
    roots = [posixpath.normpath(p["source"]) for p in mp["plugins"] if isinstance(p.get("source"), str)]
    return max((r for r in roots if rel.startswith(r + "/")), key=len, default="/".join(rel.split("/")[:2]))


def scripts_run_by(rel: str) -> list[str]:
    """Files under plugins/ that the commands of hook file rel run through ${CLAUDE_PLUGIN_ROOT}/..."""
    def strings(v):
        if isinstance(v, str):
            yield v
        elif isinstance(v, dict):
            for x in v.values():
                yield from strings(x)
        elif isinstance(v, list):
            for x in v:
                yield from strings(x)
    try:
        data = json.loads((ROOT / rel).read_text(encoding="utf-8", errors="replace"))
    except (OSError, ValueError):
        return []
    found = {posixpath.normpath(posixpath.join(plugin_root(rel), m))
             for s in strings(data) for m in re.findall(r"\$\{?CLAUDE_PLUGIN_ROOT\}?/([^\s\"'`;|&<>()$\\]+)", s)}
    return sorted(p for p in found if p.startswith("plugins/") and p != rel)


reviewed_file = ROOT / "scripts/reviewed-hooks.json"
if reviewed_file.exists():
    listed = (check_json(reviewed_file) or {}).get("reviewed", {})
    listed = listed if isinstance(listed, dict) else {}
    present = []  # listed files that exist under plugins/
    for rel, digest in listed.items():
        if not rel.startswith("plugins/") or ".." in Path(rel).parts:
            problems.append(f"scripts/reviewed-hooks.json: {rel!r} is not a path under plugins/")
            continue
        current = content_sha256(rel)
        if not current:
            warnings.append(f"scripts/reviewed-hooks.json: {rel} does not exist; remove the entry")
            continue
        present.append(rel)
        if current != digest:
            msg = (f"scripts/reviewed-hooks.json: {rel} changed since it was reviewed; after reviewing it, "
                   f"set its hash to {current}")
            # any edit of a reviewed hook file in this diff fails like a new registration, not only an edit
            # of the line holding the event name
            if args.diff and not args.warn_only and changed_since_ref(rel):
                injections.append(f"{rel}: [high] reviewed hook file changed; {msg}")
            else:
                warnings.append(msg)
        else:
            REVIEWED_HOOKS[rel] = digest
    # the code a reviewed hook runs is reviewed with it: a script it names through ${CLAUDE_PLUGIN_ROOT} needs
    # its own entry, and an edit of it fails --diff like an edit of the hook file
    for hook in present:
        for script in scripts_run_by(hook):
            current = content_sha256(script)
            changed = bool(args.diff) and changed_since_ref(script)
            if not current:
                warnings.append(f"{hook} runs {script}, which does not exist")
            elif script in REVIEWED_HOOKS:
                if changed:
                    warnings.append(f"{script}: [reviewed] script run by reviewed hook file {hook}")
            elif script not in listed:  # a listed script with another hash is reported above
                msg = (f"scripts/reviewed-hooks.json: {script} is run by reviewed hook file {hook} but not listed; "
                       f"after reviewing it, add \"{script}\": \"{current}\"")
                if changed and not args.warn_only:
                    injections.append(f"{script}: [high] script run by a reviewed hook file changed; {msg}")
                else:
                    warnings.append(msg)
    if args.diff and changed_since_ref("scripts/reviewed-hooks.json"):
        warnings.append(f"scripts/reviewed-hooks.json changed since {args.diff}: each added or changed entry declares a "
                        f"hook reviewed; check every one of them in this diff")
hook_registration_hits(fail_high=bool(args.diff) and not args.warn_only)
if args.diff:
    for path, (nums, lines) in added.items():
        scan(path, "\n".join(lines), nums, fail_high=not args.warn_only)
else:
    for f in ROOT.glob("plugins/**/*"):
        rel = f.relative_to(ROOT).as_posix()
        if f.is_file() and f.stat().st_size <= 5_000_000 and is_text(rel):
            scan(rel, f.read_text(encoding="utf-8", errors="replace"), None, fail_high=False)

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
    print(f"‼ {len(injections)} high-severity hit(s) in changes since {args.diff} — review before merging")
    sys.exit(2)
scope = f"lines added since {args.diff}" if args.diff else "full scan"
desc_scope = f"changed since {args.diff}" if args.diff else "all skills"
print(f"✓ {len(mp['plugins'])} plugins, {len(list(ROOT.glob('plugins/**/SKILL.md')))} skills valid; injection scan ({scope}): "
      f"{len(warnings)} warning(s); skill descriptions ({desc_scope}): {len(desc_warnings)} warning(s)")
