#!/usr/bin/env python3
"""Tests the fenced code blocks of SKILL.md files, per language. Run it through
scripts/test-skill-examples.sh, whose header documents the behaviour, the options and the exit codes;
tests/skill-examples.json holds the per-skill configuration (format: README, "Skill example tests").

Only run it on SKILL.md files you trust: the Pester runner and runnable python blocks execute the examples.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import warnings
from dataclasses import dataclass, field
from pathlib import Path

PROG = "test-skill-examples"
if sys.version_info < (3, 10):
    sys.stderr.write(f"{PROG}: Python 3.10 or newer is required (found {sys.version.split()[0]})\n")
    sys.exit(2)

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
DEFAULT_CONFIG = REPO / "tests" / "skill-examples.json"
YAMLLINT_CONFIG = HERE / "yamllint.yaml"
PESTER_DRIVER = HERE / "pester-driver.ps1"
PS_PARSE = HERE / "ps-parse.ps1"

EXIT_OK, EXIT_FAIL, EXIT_ENV = 0, 1, 2
MODES = ("enforce", "report")

# Fence info string (first word, lower case) -> checker. Everything else is reported as "not tested".
LANGUAGES = {
    "powershell": "powershell", "pwsh": "powershell", "ps1": "powershell",
    "bash": "bash", "shell": "bash", "sh": "sh",
    "python": "python", "py": "python", "python3": "python",
    "yaml": "yaml", "yml": "yaml",
    "json": "json",
}
PS_RUNNERS = ("parse", "pester")
SKIP_WHEN = ("always", "windows", "not-windows", "linux", "not-linux", "macos", "not-macos")
SHELLCHECK_SEVERITIES = ("error", "warning", "info", "style")
SHELLCHECK_CODE = re.compile(r"^(SC)?\d{4}$")
# `<namespace>`-style placeholders in shell and parsed PowerShell blocks (see "placeholders").
PLACEHOLDER = re.compile(r"(?<![<\w$])<([A-Za-z][A-Za-z0-9_.:/@-]*)>")
TIMEOUT = {"syntax": 60, "lint": 120, "python-run": 300, "ps-parse": 300, "pester": 1200}
SUMMARY_REPORT_LINES = 3  # problem lines per report-mode skill in the final summary (all are in the details)


def replace_placeholders(text: str) -> tuple[str, int]:
    """`<resource-group>` -> `__placeholder_resource_group__`: a word the shell and the PowerShell parser accept."""
    return PLACEHOLDER.subn(lambda m: "__placeholder_" + re.sub(r"\W", "_", m.group(1)) + "__", text)


def env_flag(name: str) -> bool:
    return os.environ.get(name, "") not in ("", "0")


# --------------------------------------------------------------------------------------------- extraction

@dataclass
class Block:
    index: int              # 1-based position among all fenced blocks of the file (the "block" skip key)
    tag: str                # first word of the info string, lower case; '' for an unlabeled fence
    fence_line: int         # 1-based line of the opening fence
    text: str
    headings: list[str]     # enclosing headings, outermost first

    @property
    def lang(self) -> str | None:
        return LANGUAGES.get(self.tag)

    @property
    def line(self) -> int:
        """SKILL.md line of the first line of the block's content."""
        return self.fence_line + 1

    def where(self) -> str:
        text = f"block {self.index} ({self.tag or 'unlabeled'}, line {self.line}"
        if self.headings:
            text += f', under "{self.headings[-1]}"'
        return text + ")"


_FENCE_OPEN = re.compile(r"^(?P<indent>[ \t]*)(?P<fence>`{3,}|~{3,})(?P<info>.*)$")
_FENCE_CLOSE = re.compile(r"^[ \t]*(`{3,}|~{3,})[ \t]*$")
_ATX = re.compile(r"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*$")


def normalize_heading(text: str) -> str:
    text = re.sub(r"^#+[ \t]*", "", text.strip())
    return " ".join(text.split())


def extract_blocks(markdown: str) -> list[Block]:
    """Fenced code blocks (``` and ~~~, any indentation, CommonMark closing rules), with the headings they
    sit under. YAML frontmatter is skipped; an unclosed fence runs to the end of the file."""
    lines = markdown.splitlines()
    start = 0
    if lines and lines[0].strip() == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() in ("---", "..."):
                start = i + 1
                break
    blocks: list[Block] = []
    headings: list[tuple[int, str]] = []
    fence = ""
    indent = 0
    tag = ""
    fence_line = 0
    body: list[str] = []

    def close() -> None:
        blocks.append(Block(len(blocks) + 1, tag, fence_line, "\n".join(body), [t for _, t in headings]))

    for i in range(start, len(lines)):
        line = lines[i]
        if not fence:
            m = _FENCE_OPEN.match(line)
            # A backtick fence's info string cannot contain a backtick (```x``` is inline code).
            if m and not (m["fence"][0] == "`" and "`" in m["info"]):
                fence, indent, fence_line, body = m["fence"], len(m["indent"]), i + 1, []
                info = m["info"].strip()
                tag = info.split()[0].lower().strip("{}").lstrip(".") if info else ""
                continue
            h = _ATX.match(line)
            if h:
                level = len(h.group(1))
                title = normalize_heading(re.sub(r"(^|[ \t]+)#+$", "", h.group(2) or ""))
                while headings and headings[-1][0] >= level:
                    headings.pop()
                headings.append((level, title))
            continue
        m = _FENCE_CLOSE.match(line)
        if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence):
            close()
            fence = ""
            continue
        # CommonMark: remove up to the opening fence's indentation from each content line.
        spaces = len(line) - len(line.lstrip(" "))
        body.append(line[min(indent, spaces):])
    if fence:
        close()
    return blocks


# ------------------------------------------------------------------------------------------ configuration

class ConfigError(Exception):
    pass


def _no_duplicates(pairs: list[tuple[str, object]]) -> dict:
    seen: dict = {}
    for key, value in pairs:
        if key in seen:
            raise ConfigError(f"duplicate key {key!r}")
        seen[key] = value
    return seen


def _check_keys(obj: object, where: str, allowed: set[str], required: set[str] = frozenset()) -> dict:
    if not isinstance(obj, dict):
        raise ConfigError(f"{where}: expected an object")
    unknown = sorted(k for k in obj if k not in allowed and not k.startswith("$"))
    if unknown:
        raise ConfigError(f"{where}: unknown key(s) {', '.join(unknown)} (allowed: {', '.join(sorted(allowed))})")
    missing = sorted(k for k in required if k not in obj)
    if missing:
        raise ConfigError(f"{where}: missing key(s) {', '.join(missing)}")
    return obj


def _check_str(value: object, where: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ConfigError(f"{where}: expected a non-empty string")
    return value


def _check_str_list(value: object, where: str) -> list[str]:
    if not isinstance(value, list):
        raise ConfigError(f"{where}: expected a list of strings")
    return [_check_str(v, f"{where}[{i}]") for i, v in enumerate(value)]


def _check_index(value: object, where: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        raise ConfigError(f"{where}: expected a block number (1 or more)")
    return value


def resolve_path(value: str) -> Path:
    """Config paths are relative to the repository root (or absolute)."""
    path = Path(value)
    return (path if path.is_absolute() else REPO / path).resolve()


def _check_shellcheck(obj: object, where: str) -> dict:
    _check_keys(obj, where, {"exclude", "severity", "reason"})
    out: dict = {}
    if ("exclude" in obj or "severity" in obj) and "reason" not in obj:
        raise ConfigError(f"{where}: 'reason' is required with 'exclude' or 'severity' (why these findings do not count)")
    if "reason" in obj:
        _check_str(obj["reason"], f"{where}.reason")
    if "exclude" in obj:
        codes = _check_str_list(obj["exclude"], f"{where}.exclude")
        for code in codes:
            if not SHELLCHECK_CODE.match(code):
                raise ConfigError(f"{where}.exclude: {code!r} is not a shellcheck code such as SC2034")
        out["exclude"] = ["SC" + c.removeprefix("SC") for c in codes]
    if "severity" in obj:
        if obj["severity"] not in SHELLCHECK_SEVERITIES:
            raise ConfigError(f"{where}.severity: one of {', '.join(SHELLCHECK_SEVERITIES)}")
        out["severity"] = obj["severity"]
    return out


def _check_skill(key: str, obj: object, defaults: dict) -> dict:
    where = f"skills[{key!r}]"
    _check_keys(obj, where, {"mode", "skip", "shellcheck", "placeholders", "python", "powershell"}, {"mode"})
    if obj["mode"] not in MODES:
        raise ConfigError(f"{where}.mode: 'enforce' or 'report'")
    conf = {
        "mode": obj["mode"],
        "skip": [],
        "shellcheck": {
            "exclude": list(defaults["shellcheck"].get("exclude", [])),
            "severity": defaults["shellcheck"].get("severity", "style"),
        },
        "placeholders": defaults["placeholders"],
        "runnable": [],
        "powershell": {"runner": "parse"},
    }
    skip = obj.get("skip", [])
    if not isinstance(skip, list):
        raise ConfigError(f"{where}.skip: expected a list")
    for i, rule in enumerate(skip):
        rw = f"{where}.skip[{i}]"
        _check_keys(rule, rw, {"block", "heading", "reason"}, {"reason"})
        _check_str(rule["reason"], f"{rw}.reason")
        if ("block" in rule) == ("heading" in rule):
            raise ConfigError(f"{rw}: give exactly one of 'block' (number) or 'heading' (text)")
        if "block" in rule:
            conf["skip"].append({"block": _check_index(rule["block"], f"{rw}.block"), "reason": rule["reason"]})
        else:
            heading = normalize_heading(_check_str(rule["heading"], f"{rw}.heading"))
            conf["skip"].append({"heading": heading, "reason": rule["reason"]})
    if "shellcheck" in obj:
        sc = _check_shellcheck(obj["shellcheck"], f"{where}.shellcheck")
        conf["shellcheck"]["exclude"] = sorted(set(conf["shellcheck"]["exclude"]) | set(sc.get("exclude", [])))
        conf["shellcheck"]["severity"] = sc.get("severity", conf["shellcheck"]["severity"])
    if "placeholders" in obj:
        if not isinstance(obj["placeholders"], bool):
            raise ConfigError(f"{where}.placeholders: true or false")
        conf["placeholders"] = obj["placeholders"]
    if "python" in obj:
        py = _check_keys(obj["python"], f"{where}.python", {"runnable"})
        runnable = py.get("runnable", [])
        if not isinstance(runnable, list):
            raise ConfigError(f"{where}.python.runnable: expected a list of block numbers")
        conf["runnable"] = [_check_index(v, f"{where}.python.runnable[{i}]") for i, v in enumerate(runnable)]
    if "powershell" in obj:
        pw = f"{where}.powershell"
        ps = _check_keys(obj["powershell"], pw, {"runner", "stubs", "fixtures", "allowed_skips", "required_passing"})
        runner = ps.get("runner", "parse")
        if runner not in PS_RUNNERS:
            raise ConfigError(f"{pw}.runner: 'parse' (syntax check only) or 'pester' (run as Pester tests)")
        pester_only = sorted(k for k in ps if k != "runner" and not k.startswith("$"))
        if runner == "parse" and pester_only:
            raise ConfigError(f"{pw}: {', '.join(pester_only)} only apply to runner 'pester'")
        out: dict = {"runner": runner, "stubs": None, "fixtures": None, "allowed_skips": [], "required_passing": []}
        if "stubs" in ps:
            out["stubs"] = resolve_path(_check_str(ps["stubs"], f"{pw}.stubs"))
            if not out["stubs"].is_file():
                raise ConfigError(f"{pw}.stubs: no such file: {out['stubs']}")
        if "fixtures" in ps:
            out["fixtures"] = resolve_path(_check_str(ps["fixtures"], f"{pw}.fixtures"))
            if not out["fixtures"].is_dir():
                raise ConfigError(f"{pw}.fixtures: no such directory: {out['fixtures']}")
        skips = ps.get("allowed_skips", [])
        if not isinstance(skips, list):
            raise ConfigError(f"{pw}.allowed_skips: expected a list")
        for i, s in enumerate(skips):
            sw = f"{pw}.allowed_skips[{i}]"
            _check_keys(s, sw, {"test", "when", "reason"}, {"test", "when", "reason"})
            _check_str(s["test"], f"{sw}.test")
            _check_str(s["reason"], f"{sw}.reason")
            if s["when"] not in SKIP_WHEN:
                raise ConfigError(f"{sw}.when: one of {', '.join(SKIP_WHEN)}")
            out["allowed_skips"].append({"test": s["test"], "when": s["when"], "reason": s["reason"]})
        out["required_passing"] = _check_str_list(ps.get("required_passing", []), f"{pw}.required_passing")
        conf["powershell"] = out
    return conf


def load_config(path: Path) -> tuple[dict, dict[Path, tuple[str, dict]]]:
    """Returns (defaults, {resolved SKILL.md path: (config key, skill config)}) in config order."""
    try:
        raw = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_no_duplicates)
    except OSError as e:
        raise ConfigError(f"cannot read: {e.strerror or e}") from None
    except json.JSONDecodeError as e:
        raise ConfigError(f"invalid JSON: {e}") from None
    _check_keys(raw, "top level", {"defaults", "skills"}, {"skills"})
    defaults_raw = _check_keys(raw.get("defaults", {}), "defaults", {"shellcheck", "placeholders"})
    defaults = {
        "shellcheck": _check_shellcheck(defaults_raw.get("shellcheck", {}), "defaults.shellcheck"),
        "placeholders": defaults_raw.get("placeholders", True),
    }
    if not isinstance(defaults["placeholders"], bool):
        raise ConfigError("defaults.placeholders: true or false")
    if not isinstance(raw["skills"], dict):
        raise ConfigError("skills: expected an object keyed by SKILL.md path")
    skills: dict[Path, tuple[str, dict]] = {}
    for key, obj in raw["skills"].items():
        if key.startswith("$"):
            continue
        resolved = resolve_path(key)
        if resolved in skills:
            raise ConfigError(f"skills[{key!r}]: same file as skills[{skills[resolved][0]!r}]")
        skills[resolved] = (key, _check_skill(key, obj, defaults))
    return defaults, skills


def default_skill_config(defaults: dict) -> dict:
    return _check_skill("<not in the config>", {"mode": "enforce"}, defaults)


# ---------------------------------------------------------------------------------------------- results

@dataclass
class BlockResult:
    block: Block
    status: str = "passed"            # passed | failed | incomplete | skipped | untested
    checks: list[str] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)
    missing: list[str] = field(default_factory=list)
    reason: str = ""
    pester_failed: bool = False       # the Pester run attributes a failure to this block (listed per skill)


@dataclass
class Skill:
    path: Path
    display: str
    mode: str
    conf: dict
    configured: bool
    blocks: list[Block] = field(default_factory=list)
    results: list[BlockResult] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)   # skill-level: config drift, Pester run problems
    notes: list[str] = field(default_factory=list)
    missing: set[str] = field(default_factory=set)      # tools a check needed but could not find
    errors: list[str] = field(default_factory=list)     # environment errors (file missing, driver crash)
    pester_counts: str = ""

    def failed(self) -> bool:
        return bool(self.problems) or any(r.status == "failed" for r in self.results)

    def all_problems(self) -> list[str]:
        return [f"{r.block.where()}: {p}" for r in self.results for p in r.problems] + self.problems


# ----------------------------------------------------------------------------------------------- runner

def run(cmd: list[str], timeout: int, cwd: Path | None = None) -> tuple[int, str]:
    """Runs cmd, returns (exit code, stdout+stderr). A timeout is exit code -1."""
    try:
        p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                           text=True, encoding="utf-8", errors="replace", timeout=timeout)
    except subprocess.TimeoutExpired:
        return -1, f"timed out after {timeout}s"
    return p.returncode, p.stdout


def listify(value: object) -> list:
    """A JSON value that PowerShell may have written as a scalar instead of a one-element array."""
    if value is None:
        return []
    return list(value) if isinstance(value, list) else [value]


def tail(text: str, n: int = 5) -> str:
    """The last n non-empty lines of text on one line, shortened."""
    lines = [ln.rstrip() for ln in text.strip().splitlines() if ln.strip()]
    out = " | ".join(lines[-n:])
    return out[:400] + ("..." if len(out) > 400 else "")


class Runner:
    def __init__(self, config_path: Path, work: Path):
        self.config_path = config_path
        self.work = work
        self.require_tools = env_flag("SKILL_EXAMPLES_REQUIRE_TOOLS")
        # REQUIRE wins over ALLOW: CI sets REQUIRE, and a stray ALLOW must not weaken it.
        self.allow_missing = env_flag("SKILL_EXAMPLES_ALLOW_MISSING_TOOLS") and not self.require_tools
        self.no_install = env_flag("SKILL_EXAMPLES_NO_INSTALL")
        self.tools = {name: shutil.which(name) for name in ("bash", "sh", "shellcheck", "yamllint", "pwsh")}
        try:
            import yaml  # noqa: PLC0415 - optional dependency
            self.yaml = yaml
        except ImportError:
            self.yaml = None
        self.ps_parse: dict[str, list[dict]] = {}

    # --- per-language checks; each returns problems (empty = passed) and records missing tools

    def _file(self, skill_no: int, block: Block, ext: str, text: str) -> Path:
        d = self.work / f"skill-{skill_no:02d}"
        d.mkdir(parents=True, exist_ok=True)
        path = d / f"block-{block.index:02d}.{ext}"
        path.write_text(text if text.endswith("\n") else text + "\n", encoding="utf-8")
        return path

    def check_shell(self, skill: Skill, no: int, r: BlockResult) -> None:
        block, conf = r.block, skill.conf
        text = block.text
        dialect = block.lang  # bash or sh; a shebang naming a shell wins
        m = re.match(r"#!\S*?(?:/env\s+)?\S*?\b(bash|dash|ksh|sh)\b", text)
        if m:
            dialect = {"dash": "sh"}.get(m.group(1), m.group(1))
        if conf["placeholders"]:
            text, count = replace_placeholders(text)
            if count:
                r.checks.append(f"{count} <placeholder>(s) replaced")
        path = self._file(no, block, "sh", text)
        if dialect == "sh" and self.tools["sh"]:
            syntax, name = self.tools["sh"], "sh -n"
        else:
            syntax, name = self.tools["bash"], "bash -n"
        if not syntax:
            r.missing.append("bash")
        else:
            r.checks.append(name)
            rc, out = run([syntax, "-n", str(path)], TIMEOUT["syntax"])
            if rc != 0:
                for line in out.strip().splitlines() or [f"exit {rc}"]:
                    m = re.match(r"^.*?:(?: line)? (\d+): (.*)$", line)
                    if m:
                        r.problems.append(f"{name}: line {block.line + int(m.group(1)) - 1}: {m.group(2)}")
                    else:
                        r.problems.append(f"{name}: {line.replace(str(path), 'block')}")
        if not self.tools["shellcheck"]:
            r.missing.append("shellcheck")
            return
        r.checks.append("shellcheck")
        sc = conf["shellcheck"]
        cmd = [self.tools["shellcheck"], "--norc", "-f", "json1", "-S", sc["severity"], "-s", dialect]
        if sc["exclude"]:
            cmd += ["-e", ",".join(sc["exclude"])]
        rc, out = run(cmd + [str(path)], TIMEOUT["lint"])
        if rc not in (0, 1):
            r.problems.append(f"shellcheck exited {rc}: {tail(out)}")
            return
        try:
            comments = json.loads(out).get("comments", []) if out.strip() else []
        except json.JSONDecodeError:
            r.problems.append(f"shellcheck: unreadable output: {tail(out)}")
            return
        for c in comments:
            r.problems.append(f"shellcheck: line {block.line + c['line'] - 1}: SC{c['code']} ({c['level']}): {c['message']}")
        if rc == 1 and not comments:
            r.problems.append(f"shellcheck exited 1 without findings: {tail(out)}")

    def check_python(self, skill: Skill, no: int, r: BlockResult) -> None:
        block = r.block
        r.checks.append("compile")
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                compile(block.text, f"block-{block.index:02d}.py", "exec", dont_inherit=True)
        except SyntaxError as e:
            line = block.line + (e.lineno or 1) - 1
            r.problems.append(f"python compile: line {line}: {e.msg}")
            return
        if block.index in skill.conf["runnable"]:
            r.checks.append("run")
            path = self._file(no, block, "py", block.text)
            rc, out = run([sys.executable, str(path)], TIMEOUT["python-run"], cwd=path.parent)
            if rc != 0:
                r.problems.append(f"python run: exit {rc}: {tail(out)}")

    def check_yaml(self, skill: Skill, no: int, r: BlockResult) -> None:
        block = r.block
        if self.yaml is None:
            r.missing.append("PyYAML")
        else:
            r.checks.append("yaml parse")
            yaml = self.yaml

            class Loader(yaml.SafeLoader):
                pass

            def any_tag(loader, _suffix, node):  # CloudFormation-style !Ref/!Sub tags are data, not errors
                if isinstance(node, yaml.ScalarNode):
                    return loader.construct_scalar(node)
                if isinstance(node, yaml.SequenceNode):
                    return loader.construct_sequence(node)
                return loader.construct_mapping(node)

            Loader.add_multi_constructor("!", any_tag)
            try:
                for _ in yaml.load_all(block.text, Loader=Loader):
                    pass
            except yaml.YAMLError as e:
                mark = getattr(e, "problem_mark", None)
                where = f"line {block.line + mark.line}: " if mark is not None else ""
                problem = getattr(e, "problem", None) or str(e).splitlines()[0]
                r.problems.append(f"yaml parse: {where}{problem}")
            except (ValueError, TypeError) as e:  # e.g. an impossible timestamp
                r.problems.append(f"yaml parse: {e}")
        if not self.tools["yamllint"]:
            r.missing.append("yamllint")
            return
        r.checks.append("yamllint")
        path = self._file(no, block, "yaml", block.text)
        rc, out = run([self.tools["yamllint"], "-c", str(YAMLLINT_CONFIG), "-f", "parsable", str(path)], TIMEOUT["lint"])
        found = 0
        for line in out.splitlines():
            m = re.match(r"^.*?:(\d+):(\d+): \[(\w+)\] (.*)$", line)
            if m:
                found += 1
                r.problems.append(f"yamllint: line {block.line + int(m.group(1)) - 1}: [{m.group(3)}] {m.group(4)}")
        if rc not in (0, 1, 2) or (rc != 0 and not found):
            r.problems.append(f"yamllint exited {rc}: {tail(out)}")

    def check_json(self, _skill: Skill, _no: int, r: BlockResult) -> None:
        r.checks.append("json parse")
        try:
            json.loads(r.block.text)
        except json.JSONDecodeError as e:
            r.problems.append(f"json parse: line {r.block.line + e.lineno - 1}: {e.msg}")

    # --- PowerShell

    def run_ps_parse(self, jobs: list[tuple[str, str]]) -> None:
        """Parses every 'parse'-runner PowerShell block in one pwsh process (syntax only, nothing runs)."""
        if not jobs or not self.tools["pwsh"]:
            return
        src = self.work / "ps-parse.json"
        dst = self.work / "ps-parse.out.json"
        src.write_text(json.dumps([{"id": key, "text": text} for key, text in jobs]), encoding="utf-8")
        rc, out = run([self.tools["pwsh"], "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(PS_PARSE),
                       str(src), str(dst)], TIMEOUT["ps-parse"])
        try:
            data = json.loads(dst.read_text(encoding="utf-8-sig"))
        except (OSError, json.JSONDecodeError):
            data = None
        if rc != 0 or not isinstance(data, dict):
            message = f"PowerShell parser failed (exit {rc}): {tail(out)}"
            self.ps_parse = {key: [{"error": message}] for key, _ in jobs}
            return
        for key, _ in jobs:
            errors = data.get(key, [])
            self.ps_parse[key] = [errors] if isinstance(errors, dict) else list(errors or [])

    def check_ps_parse(self, skill: Skill, no: int, r: BlockResult) -> None:
        if not self.tools["pwsh"]:
            r.missing.append("pwsh")
            return
        if skill.conf["placeholders"] and PLACEHOLDER.search(r.block.text):
            r.checks.append(f"{len(PLACEHOLDER.findall(r.block.text))} <placeholder>(s) replaced")
        r.checks.append("PowerShell parser")
        for e in self.ps_parse.get(f"{no}:{r.block.index}", [{"error": "no parser result"}]):
            if "error" in e:
                r.problems.append(e["error"])
            else:
                r.problems.append(f"PowerShell parser: line {r.block.line + int(e['line']) - 1}: {e['message']}")

    def run_pester(self, skill: Skill, no: int, results: list[BlockResult]) -> None:
        """Runs the skill's PowerShell blocks as Pester tests through pester-driver.ps1."""
        if not self.tools["pwsh"]:
            for r in results:
                r.missing.append("pwsh")
            return
        ps = skill.conf["powershell"]
        work = self.work / f"skill-{no:02d}" / "pester"
        work.mkdir(parents=True, exist_ok=True)
        payload = {
            "skill": skill.display,
            "blocks": [{"index": r.block.index, "line": r.block.line, "text": r.block.text} for r in results],
            "stubs": str(ps["stubs"]) if ps["stubs"] else None,
            "fixtures": str(ps["fixtures"]) if ps["fixtures"] else None,
            "allowed_skips": ps["allowed_skips"],
            "required_passing": ps["required_passing"],
            "install": not self.no_install,
        }
        (work / "input.json").write_text(json.dumps(payload, indent=1), encoding="utf-8")
        for r in results:
            r.checks.append("Pester")
        sys.stdout.flush()
        try:
            rc = subprocess.run([self.tools["pwsh"], "-NoLogo", "-NoProfile", "-NonInteractive", "-File",
                                 str(PESTER_DRIVER), str(work / "input.json"), str(work)],
                                stdin=subprocess.DEVNULL, timeout=TIMEOUT["pester"], check=False).returncode
        except subprocess.TimeoutExpired:
            skill.problems.append(f"Pester run timed out after {TIMEOUT['pester']}s")
            return
        try:
            out = json.loads((work / "result.json").read_text(encoding="utf-8-sig"))
        except (OSError, json.JSONDecodeError):
            skill.errors.append(f"the Pester driver exited {rc} without a result")
            return
        skill.notes += listify(out.get("notes"))
        skill.pester_counts = out.get("counts") or ""
        if out.get("status") == "missing":
            for r in results:
                r.missing.append("Pester 6")
            skill.notes += [f"Pester: {p}" for p in listify(out.get("problems"))]
            return
        if out.get("status") == "error":
            skill.errors += [f"Pester: {p}" for p in listify(out.get("problems"))]
            return
        failed = {int(i) for i in listify(out.get("failed_blocks"))}
        for r in results:
            r.pester_failed = r.block.index in failed
        skill.problems += [f"Pester: {p}" for p in listify(out.get("problems"))]
        if rc not in (0, 1) and not skill.problems:
            skill.problems.append(f"Pester driver exited {rc}")

    # --- orchestration

    def prepare(self, skill: Skill) -> None:
        """Extracts the blocks and applies the skip rules (so PowerShell parsing can be batched)."""
        try:
            skill.blocks = extract_blocks(skill.path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError) as e:
            skill.errors.append(f"cannot read {skill.display}: {e}")
            return
        used = set()
        for block in skill.blocks:
            r = BlockResult(block)
            for n, rule in enumerate(skill.conf["skip"]):
                if rule.get("block") == block.index or rule.get("heading") in block.headings:
                    r.status, r.reason = "skipped", rule["reason"]
                    used.add(n)
                    break
            if r.status != "skipped" and block.lang is None:
                r.status = "untested"
            skill.results.append(r)
        for n, rule in enumerate(skill.conf["skip"]):
            if n not in used:
                what = f"block {rule['block']}" if "block" in rule else f'heading "{rule["heading"]}"'
                skill.problems.append(f"config: skip rule for {what} matches no block (update {self.config_path.name})")
        by_index = {b.index: b for b in skill.blocks}
        for i in skill.conf["runnable"]:
            if i not in by_index or by_index[i].lang != "python":
                skill.problems.append(f"config: python.runnable lists block {i}, which is not a python block")

    def check(self, skill: Skill, no: int) -> None:
        pester_runner = skill.conf["powershell"]["runner"] == "pester"
        tested = [r for r in skill.results if r.status not in ("skipped", "untested")]
        pester = [r for r in tested if pester_runner and r.block.lang == "powershell"]
        checkers = {"bash": self.check_shell, "sh": self.check_shell, "python": self.check_python,
                    "yaml": self.check_yaml, "json": self.check_json, "powershell": self.check_ps_parse}
        for r in tested:
            if not (pester_runner and r.block.lang == "powershell"):
                checkers[r.block.lang](skill, no, r)
        if pester:
            self.run_pester(skill, no, pester)
        elif pester_runner:
            skill.problems.append("powershell runner 'pester' is configured, but no powershell block is left to run")
        for r in tested:
            r.problems = list(dict.fromkeys(r.problems))  # one line per distinct finding
            if r.problems or r.pester_failed:
                r.status = "failed"
            elif r.missing:
                r.status = "incomplete"
            skill.missing.update(r.missing)
        if not any(b.lang for b in skill.blocks):
            skill.problems.append("no code block in a tested language (bash, sh, python, yaml, json, powershell)")
        elif not tested:
            skill.notes.append("every block in a tested language is skipped by the config")


# ---------------------------------------------------------------------------------------------- output

def verdict(skill: Skill, allow_missing: bool, require_tools: bool = False) -> str:
    if skill.missing and require_tools:
        return "ERROR"  # SKILL_EXAMPLES_REQUIRE_TOOLS: every check must run, in report mode too
    if skill.mode == "report":
        return "WARN" if skill.failed() or skill.errors or skill.missing else "PASS"
    if skill.errors or (skill.missing and not allow_missing):
        return "ERROR"  # exit 2 wins over exit 1: the run did not check everything it should have
    if skill.failed():
        return "FAIL"
    return "WARN" if skill.missing else "PASS"


def counts(skill: Skill) -> str:
    n = {s: sum(r.status == s for r in skill.results) for s in ("passed", "failed", "incomplete", "skipped")}
    tested = n["passed"] + n["failed"] + n["incomplete"]
    failed = "failed" if skill.mode == "enforce" else "with warnings"
    text = f"{tested} block(s) tested: {n['passed']} passed, {n['failed']} {failed}"
    if n["incomplete"]:
        text += f", {n['incomplete']} incomplete"
    if n["skipped"]:
        text += f"; {n['skipped']} skipped by config"
    langs: dict[str, int] = {}
    for r in skill.results:
        if r.status == "untested":
            langs[r.block.tag or "unlabeled"] = langs.get(r.block.tag or "unlabeled", 0) + 1
    if langs:
        by_count = sorted(langs.items(), key=lambda kv: (-kv[1], kv[0]))
        text += f"; {sum(langs.values())} not tested (" + ", ".join(f"{k} {v}" for k, v in by_count) + ")"
    return text


def print_header(skill: Skill) -> None:
    print(f"== {skill.display} ({skill.mode}{'' if skill.configured else '; not in the config, defaults'}) ==", flush=True)


def print_details(skill: Skill) -> None:
    bad = "FAIL" if skill.mode == "enforce" else "WARN"
    for r in skill.results:
        if r.status == "untested":
            continue
        head = f"  {r.block.where()}"
        if r.status == "skipped":
            print(f"{head}: skipped ({r.reason})")
            continue
        extra = f"; missing {', '.join(r.missing)}" if r.missing else ""
        label = {"passed": "ok", "failed": bad, "incomplete": "incomplete"}[r.status]
        print(f"{head}: {label} ({', '.join(r.checks) or 'no check ran'}{extra})")
        for p in r.problems:
            print(f"      {p}")
    for p in skill.problems:
        print(f"  {bad}: {p}")
    for e in skill.errors:
        print(f"  ERROR: {e}")
    for note in skill.notes:
        print(f"  note: {note}")
    print(f"  {counts(skill)}", flush=True)


def summary_lines(skill: Skill, allow_missing: bool, require_tools: bool) -> list[str]:
    bad = "FAIL" if skill.mode == "enforce" else "warn"
    tag = skill.mode + ("" if skill.configured else ", not in the config")
    lines = [f"{verdict(skill, allow_missing, require_tools):<5} {skill.display} ({tag}): {counts(skill)}"]
    if skill.pester_counts:
        lines.append(f"        pester: {skill.pester_counts}")
    problems = [f"{bad}: {p}" for p in skill.all_problems()] + [f"ERROR: {e}" for e in skill.errors]
    if skill.missing:
        if require_tools:
            how = "an error because SKILL_EXAMPLES_REQUIRE_TOOLS is set"
        elif skill.mode == "report":
            how = "report mode: a warning"
        elif allow_missing:
            how = "a warning because SKILL_EXAMPLES_ALLOW_MISSING_TOOLS is set"
        else:
            how = "install it; SKILL_EXAMPLES_ALLOW_MISSING_TOOLS=1 makes this a warning locally"
        problems.append(f"MISSING TOOL: {', '.join(sorted(skill.missing))} ({how}); those checks did not run")
    if skill.mode == "report" and len(problems) > SUMMARY_REPORT_LINES:
        more = len(problems) - SUMMARY_REPORT_LINES
        problems = problems[:SUMMARY_REPORT_LINES] + [f"... {more} more (details above)"]
    lines += [f"        {p}" for p in problems]
    lines += [f"        note: {n}" for n in skill.notes if n.startswith("skipped as expected")]
    return lines


# ------------------------------------------------------------------------------------------------- main

def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="test-skill-examples.sh",
        description="Tests the fenced code blocks of SKILL.md files per language: powershell (Pester or parser), "
                    "bash/sh (bash -n, shellcheck), python (compile; run if configured), yaml (PyYAML, yamllint), "
                    "json (parse). Other fences are reported as not tested. The examples can be executed: only run "
                    "this on SKILL.md files you trust.",
        epilog="Exit status: 0 every enforce-mode skill passed (report-mode problems are warnings); 1 an enforce-mode "
               "example failed; 2 usage, configuration or environment error, or a tool an enforce-mode skill needs is "
               "missing. Environment: SKILL_EXAMPLES_ALLOW_MISSING_TOOLS=1 turns a missing tool into a warning; "
               "SKILL_EXAMPLES_REQUIRE_TOOLS=1 makes any missing tool an error, report mode included (CI); "
               "SKILL_EXAMPLES_NO_INSTALL=1 never installs Pester 6 from the PowerShell Gallery; "
               "TEST_SKILL_EXAMPLES_KEEP=1 keeps the generated files.")
    parser.add_argument("skills", nargs="*", metavar="SKILL.md",
                        help="only test these files (default: every skill in the config); a file that is not in the "
                             "config is tested in enforce mode with the default settings (PowerShell is only parsed)")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG, metavar="FILE",
                        help=f"per-skill configuration (default: {DEFAULT_CONFIG.relative_to(REPO)})")
    return parser.parse_args(argv)


def tally_text(tally: dict[str, int]) -> str:
    return ", ".join(f"{n} {v}" for v, n in sorted(tally.items())) or "none"


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(REPO))
    except ValueError:
        return str(path)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        defaults, configured = load_config(args.config)
    except ConfigError as e:
        print(f"{PROG}: {args.config}: {e}", file=sys.stderr)
        return EXIT_ENV

    skills: list[Skill] = []
    if args.skills:
        for arg in args.skills:
            path = Path(arg)
            if not path.is_file():
                print(f"{PROG}: no such file: {arg}", file=sys.stderr)
                return EXIT_ENV
            path = path.resolve()
            key, conf = configured.get(path, (None, None))
            if conf is None:
                conf = default_skill_config(defaults)
            skills.append(Skill(path, display_path(path), conf["mode"], conf, key is not None))
    else:
        for path, (_key, conf) in configured.items():
            skills.append(Skill(path, display_path(path), conf["mode"], conf, True))
        if not skills:
            print(f"{PROG}: {args.config}: no skills configured", file=sys.stderr)
            return EXIT_ENV

    work = Path(tempfile.mkdtemp(prefix="test-skill-examples."))
    keep = os.environ.get("TEST_SKILL_EXAMPLES_KEEP") == "1"
    try:
        runner = Runner(args.config, work)
        for skill in skills:
            if not skill.path.is_file():
                skill.errors.append(f"no such file: {skill.display}")
            else:
                runner.prepare(skill)
        jobs = []  # every PowerShell block to parse, across all skills: one pwsh start instead of one per skill
        for no, skill in enumerate(skills, 1):
            if skill.conf["powershell"]["runner"] != "parse":
                continue
            for r in skill.results:
                if r.status not in ("skipped", "untested") and r.block.lang == "powershell":
                    text = replace_placeholders(r.block.text)[0] if skill.conf["placeholders"] else r.block.text
                    jobs.append((f"{no}:{r.block.index}", text))
        runner.run_ps_parse(jobs)
        for no, skill in enumerate(skills, 1):
            print_header(skill)
            if not skill.errors:
                runner.check(skill, no)
            print_details(skill)
            print()
    finally:
        if keep:
            print(f"{PROG}: kept the generated files in {work}", file=sys.stderr)
        else:
            shutil.rmtree(work, ignore_errors=True)

    allow, require = runner.allow_missing, runner.require_tools
    verdicts = {id(s): verdict(s, allow, require) for s in skills}
    print("== test-skill-examples summary ==")
    # Report-mode skills first: the sync workflow quotes the last lines of this output, which must show the
    # enforce-mode results.
    for skill in [s for s in skills if s.mode == "report"] + [s for s in skills if s.mode == "enforce"]:
        for line in summary_lines(skill, allow, require):
            print(line)
    tally: dict[str, dict[str, int]] = {"enforce": {}, "report": {}}
    for s in skills:
        tally[s.mode][verdicts[id(s)]] = tally[s.mode].get(verdicts[id(s)], 0) + 1
    enforce = tally["enforce"]
    status = EXIT_ENV if enforce.get("ERROR") or tally["report"].get("ERROR") else EXIT_FAIL if enforce.get("FAIL") else EXIT_OK
    word = {EXIT_OK: "PASS", EXIT_FAIL: "FAIL", EXIT_ENV: "ERROR"}[status]
    line = f"result: {word} (exit {status}) - enforce mode: {tally_text(enforce)}"
    if tally["report"]:
        line += f"; report mode (warnings only): {tally_text(tally['report'])}"
    missing = sorted({t for s in skills if s.mode == "enforce" or require for t in s.missing})
    if missing and not allow:
        line += f"; missing tools: {', '.join(missing)} (install them, or set SKILL_EXAMPLES_ALLOW_MISSING_TOOLS=1 locally)"
    print(line)
    return status


if __name__ == "__main__":
    sys.exit(main())
