#!/usr/bin/env python3
"""Skill trigger evals: does the right skill load for a realistic prompt, and do look-alikes stay out?

For every case in tests/evals/triggers.yaml this runs `claude -p` once (or --runs N times) with this
repo's plugins loaded through --plugin-dir, reads the stream-json output, records which skills the
model invoked through the Skill tool, and scores the case:

  expect   skills that must load (all of them; "a|b" = either one). [] = negative control: no repo
           skill may load except those in `accept`.
  accept   skills that may load without counting against the case (plausible extras).
  forbid   look-alike skills that must not load.
  strict   true = any other repo skill loading also fails the case (implied when expect is []).

Output: a pass/fail table per case, per-skill precision/recall (TP/FP/FN) and a summary; optionally
--json FILE and --markdown FILE (e.g. "$GITHUB_STEP_SUMMARY"). Skills that are not from this repo
(a user's own skills, Claude Code's bundled skills with --keep-bundled-skills) are listed, never scored.

Isolation. Every run gets a fresh --session-id and --no-session-persistence, in an empty temporary
working directory; the variables that tie a nested `claude` to a parent session (CLAUDE_CODE_SESSION_ID,
CLAUDE_CODE_REMOTE_SESSION_ID, CLAUDECODE) are removed from its environment. The model can only load
skills: --tools Skill removes every other built-in tool from its context, MCP tools are denied and no
MCP server starts (--strict-mcp-config), --settings turns off hooks, skill shell injection and
Claude Code's bundled skills, --permission-mode dontAsk, --restricted when the CLI has it (ignores
user/project settings, user skills and claude.ai-synced skills), --max-turns and --max-budget-usd cap
each run. Never --dangerously-skip-permissions.

Detection (verified on Claude Code 2.1.284): a skill load is an `assistant` event whose content has a
`tool_use` block named "Skill" with input {"skill": "<plugin>:<name>"} (sometimes the bare alias),
followed by a `user` tool_result "Launching skill: <plugin>:<name>"; a call the CLI answers with an error
result (an unknown name, a skill with disable-model-invocation) is reported as rejected and not scored, and
a call whose result never arrived still counts. Skills load before the answer, so
a run stops once the model has written --stop-after characters of answer text or reaches for any
other tool (it tries Write for "write a module" prompts; that tool does not exist here). The approach
(stream-json, Skill tool_use detection, stopping early) follows scripts/run_eval.py of the vendored
skill-creator (anthropics/skills, Apache-2.0), which tests one skill description at a time through a
temporary command file; this runner scores the real plugins against each other instead. No code is
copied from it.

Skill listing budget. Claude Code fits all skill descriptions into a listing of about 1% of the
context window (skillListingBudgetFraction). With every plugin of this repo loaded the listing is
about twice that, so descriptions are cut, as in a real session with the same plugins. The runner
reads the CLI's "Skill listing over budget" debug line and reports it; --listing-budget 0.03 shows
the model the full descriptions.

Credentials contract (for the weekly workflow): without ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN,
ANTHROPIC_AUTH_TOKEN, a Bedrock/Vertex/Foundry switch, or a logged-in CLI (`claude auth status` exits
0), the script prints "SKIPPED: ..." (a ::notice:: in GitHub Actions) and exits 0, or 3 with
--require-credentials. Exit codes: 0 all cases passed (or --no-fail, or skipped), 1 a case failed or
errored, 2 usage/config error (bad triggers.yaml, unknown skill, missing CLI, credentials rejected).

Cost: a run sends the skill listing (about 12k tokens with every plugin; a prompt-cache write every
run, because the listing travels with the prompt), plus the body of each skill loaded (the Azure
skills are 15-40k tokens each), and stops after a few hundred output tokens. The child gets
CLAUDE_CODE_PROMPT_CACHE_TTL=5m (runs last seconds; a subscription's 1-hour TTL bills writes at the
higher rate). The report shows token totals; the CLI reports dollars only for runs that reach their
result event. --dry-run validates the cases and prints the commands without calling the model.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path

sys.dont_write_bytecode = True  # no scripts/__pycache__ in the working tree
sys.path.insert(0, str(Path(__file__).resolve().parent))
from skill_descriptions import Skill, load_skills, plugin_dirs, plugin_name  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CASES = ROOT / "tests/evals/triggers.yaml"
# Nested `claude` processes inherit these from a parent Claude Code session and would reuse its
# session instead of starting their own.
PARENT_SESSION_VARS = ("CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_REMOTE_SESSION_ID", "CLAUDECODE")
CREDENTIAL_VARS = ("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN",
                   "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY")
DENIED_TOOLS = "Bash,PowerShell,Edit,Write,NotebookEdit,WebFetch,WebSearch,Agent,Task,mcp__*"
SAFE_SETTINGS = {"disableAllHooks": True, "disableSkillShellExecution": True}
LISTING_RX = re.compile(r"Skill listing over budget: (\d+) skills, (\d+) chars > (\d+) budget")
AUTH_ERROR_RX = re.compile(r"invalid api key|please run /login|not logged in|authentication[_ ]failed|"
                           r"oauth token has expired|\b401\b", re.I)
ID_RX = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")


# --- cases ------------------------------------------------------------------------------------

@dataclass
class Case:
    id: str
    prompt: str
    expect: list[list[str]]          # each entry: alternatives, any one satisfies it
    accept: list[str] = field(default_factory=list)
    forbid: list[str] = field(default_factory=list)
    strict: bool = False
    tags: list[str] = field(default_factory=list)
    note: str = ""

    @property
    def negative(self) -> bool:
        return not self.expect


def _names(value, where: str, errors: list[str]) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, list) or not all(isinstance(v, str) and v.strip() for v in value):
        errors.append(f"{where}: must be a list of skill names")
        return []
    return [v.strip() for v in value]


def parse_cases(data, errors: list[str]) -> list[Case]:
    """Build cases from the loaded YAML document ({"cases": [...]} or a bare list)."""
    items = data.get("cases") if isinstance(data, dict) else data
    if not isinstance(items, list):
        errors.append("triggers file: expected a top-level `cases:` list")
        return []
    cases, seen = [], set()
    known = {"id", "prompt", "expect", "accept", "forbid", "strict", "tags", "note"}
    for i, item in enumerate(items):
        where = f"case #{i + 1}"
        if not isinstance(item, dict):
            errors.append(f"{where}: not a mapping")
            continue
        cid = item.get("id")
        if not isinstance(cid, str) or not ID_RX.fullmatch(cid):
            errors.append(f"{where}: id must be lowercase-hyphen ({cid!r})")
            cid = f"case-{i + 1}"
        where = f"case {cid}"
        if cid in seen:
            errors.append(f"{where}: duplicate id")
        seen.add(cid)
        for k in sorted(set(item) - known):
            errors.append(f"{where}: unknown key {k!r}")
        prompt = item.get("prompt")
        if not isinstance(prompt, str) or not prompt.strip():
            errors.append(f"{where}: prompt must be a non-empty string")
            prompt = ""
        if "expect" not in item:
            errors.append(f"{where}: expect is required (use [] for a negative control)")
        expect = [[a.strip() for a in e.split("|") if a.strip()] for e in _names(item.get("expect"), f"{where} expect", errors)]
        strict = item.get("strict", False)
        if not isinstance(strict, bool):
            errors.append(f"{where}: strict must be true or false")
            strict = False
        tags = item.get("tags") or []
        if not isinstance(tags, list):
            errors.append(f"{where}: tags must be a list")
            tags = []
        cases.append(Case(id=cid, prompt=prompt.strip(), expect=expect,
                          accept=_names(item.get("accept"), f"{where} accept", errors),
                          forbid=_names(item.get("forbid"), f"{where} forbid", errors),
                          strict=strict, tags=[str(t) for t in tags], note=str(item.get("note") or "")))
    return cases


def load_cases(path: Path, errors: list[str]) -> list[Case]:
    try:
        import yaml  # PyYAML; only this loader needs it
    except ImportError:
        errors.append("PyYAML is required to read the cases (pip install pyyaml, or apt install python3-yaml)")
        return []
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as e:
        errors.append(f"{path}: {e}")
        return []
    return parse_cases(data, errors)


# --- skill index ------------------------------------------------------------------------------

class SkillIndex:
    """Maps the names the model invokes ("plugin:name", or a bare alias) and the names used in the
    cases (bare or qualified) to this repo's skills."""

    def __init__(self, skills: list[Skill]):
        self.skills = skills
        self.by_qualified = {s.qualified: s for s in skills}
        bare: dict[str, list[Skill]] = {}
        for s in skills:
            bare.setdefault(s.name, []).append(s)
        self.by_bare = {k: v[0] for k, v in bare.items() if len(v) == 1}
        self.ambiguous = {k for k, v in bare.items() if len(v) > 1}
        self.plugins = {s.plugin for s in skills}

    def resolve(self, name: str) -> Skill | None:
        name = name.strip().lstrip("/")
        if ":" in name:
            return self.by_qualified.get(name)
        return self.by_bare.get(name)

    def label(self, name: str) -> str:
        """Short display name: the bare skill name when it is unique, else the qualified one."""
        s = self.resolve(name)
        if s is None:
            return name
        return s.name if s.name in self.by_bare else s.qualified


def validate_cases(cases: list[Case], index: SkillIndex) -> list[str]:
    errors = []
    for c in cases:
        def check(names: list[str], field_: str) -> list[str]:
            out = []
            for n in names:
                s = index.resolve(n)
                if s is None:
                    hint = " (ambiguous; use plugin:name)" if n in index.ambiguous else ""
                    errors.append(f"case {c.id}: {field_} names unknown skill {n!r}{hint}")
                    continue
                if field_ == "expect" and not s.model_invocable:
                    errors.append(f"case {c.id}: expect names {n!r}, which has disable-model-invocation: true "
                                  f"(the model can never load it)")
                out.append(s.qualified)
            return out
        exp = {q for group in c.expect for q in check(group, "expect")}
        acc = set(check(c.accept, "accept"))
        forb = set(check(c.forbid, "forbid"))
        for q in sorted(forb & (exp | acc)):
            errors.append(f"case {c.id}: {q} is both forbidden and expected/accepted")
    return errors


# --- stream parsing ---------------------------------------------------------------------------

@dataclass
class Invocation:
    name: str                  # as the model wrote it
    tool_use_id: str = ""
    ok: bool | None = None     # from the tool_result; None = no result seen (run stopped first)


class StreamParser:
    """Consumes `claude -p --output-format stream-json --verbose [--include-partial-messages]` lines.
    feed() returns True when the run can stop: the result arrived, the model has written
    stop_after_chars of answer text, or it reached for a tool other than Skill (skills load first).
    stop_after_chars=None never stops early."""

    def __init__(self, stop_after_chars: int | None = 400):
        self.stop_after_chars = stop_after_chars
        self.init: dict = {}
        self.result: dict = {}
        self.invocations: list[Invocation] = []
        self.stopped_early = False
        self.stop_reason = ""        # "answer" or "tool:<name>" when stopped early
        self.text_chars = 0          # answer text seen in the current main-thread message
        self.tool_in_message = False
        self.bad_lines = 0
        # token usage of the main conversation, summed over model messages (from message_start /
        # message_delta; the output of a message cut off by the early stop is not included)
        self.usage = {"input": 0, "cache_write": 0, "cache_read": 0, "output": 0}

    def feed(self, line: str) -> bool:
        line = line.strip()
        if not line:
            return False
        try:
            ev = json.loads(line)
        except ValueError:
            self.bad_lines += 1
            return False
        if not isinstance(ev, dict):
            return False
        t = ev.get("type")
        parent = ev.get("parent_tool_use_id")
        if t == "system" and ev.get("subtype") == "init":
            self.init = ev
        elif t == "stream_event" and parent is None:
            return self._stream_event(ev.get("event") or {})
        elif t == "assistant":
            msg = ev.get("message") or {}
            if msg.get("model") == "<synthetic>":
                return False  # an error notice written by the CLI (e.g. unknown model), not the model's answer
            for block in msg.get("content") or []:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_use":
                    if parent is None:
                        self.tool_in_message = True
                    if block.get("name") == "Skill":
                        inp = block.get("input") or {}
                        name = inp.get("skill") or inp.get("command") or inp.get("name") or ""
                        if name and not any(i.tool_use_id and i.tool_use_id == block.get("id") for i in self.invocations):
                            self.invocations.append(Invocation(str(name), block.get("id") or ""))
                    elif parent is None and self._acting(block.get("name")):
                        return True
                elif block.get("type") == "text" and parent is None and not self.tool_in_message:
                    # complete text block (runs without --include-partial-messages)
                    self.text_chars = max(self.text_chars, len(block.get("text") or ""))
                    if self._answering():
                        return True
        elif t == "user":
            msg = ev.get("message") or {}
            content = msg.get("content")
            for block in content if isinstance(content, list) else []:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    for inv in self.invocations:
                        if inv.tool_use_id and inv.tool_use_id == block.get("tool_use_id"):
                            inv.ok = not block.get("is_error", False)
            if parent is None:  # a new model message follows the tool results
                self.text_chars, self.tool_in_message = 0, False
        elif t == "result":
            self.result = ev
            return True
        return False

    def _stream_event(self, se: dict) -> bool:
        st = se.get("type")
        if st == "message_start":
            self.text_chars, self.tool_in_message = 0, False
            u = (se.get("message") or {}).get("usage") or {}
            self.usage["input"] += int(u.get("input_tokens") or 0)
            self.usage["cache_write"] += int(u.get("cache_creation_input_tokens") or 0)
            self.usage["cache_read"] += int(u.get("cache_read_input_tokens") or 0)
        elif st == "message_delta":
            self.usage["output"] += int((se.get("usage") or {}).get("output_tokens") or 0)
        elif st == "content_block_start":
            cb = se.get("content_block") or {}
            if cb.get("type") in ("tool_use", "server_tool_use"):
                self.tool_in_message = True
                if cb.get("name") != "Skill" and self._acting(cb.get("name")):
                    return True
        elif st == "content_block_delta":
            d = se.get("delta") or {}
            if d.get("type") == "text_delta" and not self.tool_in_message:
                self.text_chars += len(d.get("text") or "")
                return self._answering()
        return False

    def _answering(self) -> bool:
        if self.stop_after_chars and self.text_chars >= self.stop_after_chars:
            self.stopped_early, self.stop_reason = True, "answer"
            return True
        return False

    def _acting(self, tool: str | None) -> bool:
        """The model reaches for another tool (Write, Bash, ...): it has settled on its skills and
        starts doing the task. Those tools do not exist in the session, so waiting only burns tokens
        on calls that fail."""
        if self.stop_after_chars:
            self.stopped_early, self.stop_reason = True, f"tool:{tool or '?'}"
            return True
        return False

    @property
    def invoked(self) -> list[str]:
        """Skills that loaded: every Skill call except those the CLI rejected (an error tool_result, e.g. an
        unknown name). A call without a result still counts: the run may stop before the result arrives."""
        return [i.name for i in self.invocations if i.ok is not False]

    @property
    def rejected(self) -> list[str]:
        return [i.name for i in self.invocations if i.ok is False]

    @property
    def error(self) -> str:
        """Why the run failed, '' when it did not. Hitting --max-turns is not a failure here."""
        r = self.result
        if not r:
            return "" if self.stopped_early else "no result event"
        if r.get("subtype") in ("success", "error_max_turns"):
            if r.get("is_error") and r.get("subtype") == "success":
                status = f" (HTTP {r['api_error_status']})" if r.get("api_error_status") else ""
                return str(r.get("result") or "is_error")[:300] + status
            return ""
        return f"{r.get('subtype')}: {str(r.get('result') or r.get('errors') or '')[:300]}"


# --- running ----------------------------------------------------------------------------------

@dataclass
class RunResult:
    case_id: str
    run: int
    invoked: list[str] = field(default_factory=list)
    rejected: list[str] = field(default_factory=list)  # Skill calls the CLI answered with an error; never scored
    bad_lines: int = 0         # stream-json lines that were not JSON
    error: str = ""
    cost_usd: float = 0.0      # only when the run reached its result event (not after an early stop)
    tokens: dict = field(default_factory=dict)
    seconds: float = 0.0
    model: str = ""
    stopped_early: bool = False
    stop_reason: str = ""
    listing: str = ""          # "Skill listing over budget ..." from the CLI's debug log
    plugin_errors: list = field(default_factory=list)


def session_settings(args) -> dict:
    settings = dict(SAFE_SETTINGS)
    if not getattr(args, "keep_bundled_skills", False):
        # Claude Code's own skills are never scored; a mis-invoked one (update-config is ~70k tokens)
        # only adds cost and noise
        settings["disableBundledSkills"] = True
    if getattr(args, "listing_budget", None):
        settings["skillListingBudgetFraction"] = args.listing_budget
    return settings


def build_command(args, plugin_paths: list[Path], session_id: str, supports: set[str],
                  debug_file: str | None = None) -> list[str]:
    cmd = [args.claude, "-p",
           "--output-format", "stream-json", "--verbose", "--include-partial-messages",
           "--session-id", session_id, "--no-session-persistence",
           "--tools", "Skill", "--allowedTools", "Skill", "--disallowedTools", DENIED_TOOLS,
           "--permission-mode", "dontAsk", "--strict-mcp-config",
           "--settings", json.dumps(session_settings(args), separators=(",", ":")),
           "--max-turns", str(args.max_turns), "--max-budget-usd", f"{args.max_budget_usd:g}"]
    if "--restricted" in supports:
        cmd.append("--restricted")
    if "--permission-prompts" in supports:
        cmd += ["--permission-prompts", "none"]
    if debug_file and "--debug-file" in supports:
        cmd += ["--debug-file", debug_file]
    if args.model:
        cmd += ["--model", args.model]
    if args.effort:
        cmd += ["--effort", args.effort]
    for p in plugin_paths:
        cmd += ["--plugin-dir", str(p)]
    return cmd  # the prompt goes to stdin: no argv parsing surprises, not visible in `ps`


def child_env() -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if k not in PARENT_SESSION_VARS}
    # The skill listing travels with the prompt, so it is a cache write on every run. A run lasts
    # seconds: the 5-minute TTL (API-key default) is enough, and a subscription's 1-hour TTL would
    # bill those writes at the higher rate. An explicit setting from the caller wins.
    env.setdefault("CLAUDE_CODE_PROMPT_CACHE_TTL", "5m")
    return env


def run_once(case: Case, run: int, args, plugin_paths: list[Path], supports: set[str], cwd: str) -> RunResult:
    """One `claude -p` run. `cwd` is an empty directory shared by all runs (the model has no file
    tools; one directory lets parallel runs share the cached prompt prefix)."""
    res = RunResult(case.id, run)
    parser = StreamParser(None if args.no_early_stop else args.stop_after)
    start = time.monotonic()
    timed_out = threading.Event()
    with tempfile.TemporaryDirectory(prefix="skill-eval-debug-") as dbg, tempfile.TemporaryFile("w+") as err:
        debug_file = str(Path(dbg) / "debug.log")
        cmd = build_command(args, plugin_paths, str(uuid.uuid4()), supports, debug_file)
        try:
            proc = subprocess.Popen(cmd, cwd=cwd, env=child_env(), stdin=subprocess.PIPE,
                                    stdout=subprocess.PIPE, stderr=err, text=True, encoding="utf-8",
                                    errors="replace")
        except OSError as e:
            res.error = f"cannot start {args.claude}: {e}"
            return res
        record = None
        if args.record:
            Path(args.record).mkdir(parents=True, exist_ok=True)
            record = open(Path(args.record) / f"{case.id}.{run}.jsonl", "w", encoding="utf-8")
        timer = threading.Timer(args.timeout, lambda: (timed_out.set(), proc.kill()))
        timer.start()
        try:
            try:
                proc.stdin.write(case.prompt)
                proc.stdin.close()
            except OSError:
                pass
            for line in proc.stdout:
                if record:
                    record.write(line)
                if parser.feed(line):
                    break
        finally:
            timer.cancel()
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
            proc.stdout.close()
            if record:
                record.close()
        err.seek(0)
        stderr_tail = err.read()[-400:].strip()
        try:
            m = LISTING_RX.search(Path(debug_file).read_text(encoding="utf-8", errors="replace"))
            res.listing = m.group(0) if m else ""
        except OSError:
            pass
    res.seconds = time.monotonic() - start
    res.invoked = parser.invoked
    res.rejected = parser.rejected
    res.bad_lines = parser.bad_lines
    res.stopped_early = parser.stopped_early
    res.stop_reason = parser.stop_reason
    res.model = parser.init.get("model", "")
    res.plugin_errors = list(parser.init.get("plugin_errors") or [])
    res.cost_usd = float(parser.result.get("total_cost_usd") or 0.0)
    res.tokens = dict(parser.usage)
    if timed_out.is_set():
        res.error = f"timeout after {args.timeout}s"
    else:
        res.error = parser.error
    if res.error and stderr_tail and not parser.init:
        res.error += f" | stderr: {stderr_tail}"
    return res


# --- scoring ----------------------------------------------------------------------------------

@dataclass
class CaseResult:
    case: Case
    status: str                       # PASS FAIL ERROR SKIP
    loaded: list[str] = field(default_factory=list)       # repo skills (qualified) at/over threshold
    rates: dict[str, float] = field(default_factory=dict)  # repo skill -> share of runs that loaded it
    other: list[str] = field(default_factory=list)        # non-repo skills invoked (not scored)
    missing: list[str] = field(default_factory=list)      # expect groups (joined with |) not satisfied
    forbidden: list[str] = field(default_factory=list)
    extra: list[str] = field(default_factory=list)        # loaded, not expected/accepted/forbidden
    runs: list[RunResult] = field(default_factory=list)
    reason: str = ""


def qualify(names: list[str], index: SkillIndex) -> list[str]:
    return [s.qualified for s in (index.resolve(n) for n in names) if s]


def score_case(case: Case, runs: list[RunResult], index: SkillIndex, threshold: float = 0.5) -> CaseResult:
    ok = [r for r in runs if not r.error]
    if not ok:
        return CaseResult(case, "ERROR", runs=runs, reason=(runs[0].error if runs else "not run"))
    counts: dict[str, int] = {}
    other: set[str] = set()
    for r in ok:
        seen = set()
        for name in r.invoked:
            s = index.resolve(name)
            if s is None:
                other.add(name)
            else:
                seen.add(s.qualified)
        for q in seen:
            counts[q] = counts.get(q, 0) + 1
    rates = {q: n / len(ok) for q, n in counts.items()}
    loaded = sorted(q for q, rate in rates.items() if rate >= threshold)
    groups = [qualify(g, index) for g in case.expect]
    expected = {q for g in groups for q in g}
    accept, forbid = set(qualify(case.accept, index)), set(qualify(case.forbid, index))
    missing = ["|".join(g) for g in groups if g and not set(g) & set(loaded)]
    forbidden = sorted(forbid & set(loaded))
    extra = sorted(set(loaded) - expected - accept - forbid)
    failed = bool(missing or forbidden or ((case.negative or case.strict) and extra))
    reasons = []
    if missing:
        reasons.append("missing " + ", ".join(index.label(m.split("|")[0]) + ("|..." if "|" in m else "") for m in missing))
    if forbidden:
        reasons.append("forbidden " + ", ".join(index.label(q) for q in forbidden))
    if (case.negative or case.strict) and extra:
        reasons.append("unexpected " + ", ".join(index.label(q) for q in extra))
    return CaseResult(case, "FAIL" if failed else "PASS", loaded, rates, sorted(other), missing, forbidden,
                      extra, runs, "; ".join(reasons))


def skill_stats(results: list[CaseResult], index: SkillIndex) -> dict[str, dict]:
    """Per repo skill: TP (expected and loaded), FN (expected, not loaded), FP (loaded, neither
    expected nor accepted), plus precision and recall (None when undefined). For an "a|b" group
    every loaded alternative is a TP; when none loaded, the FN goes to the first alternative."""
    stats: dict[str, dict] = {}

    def bump(q: str, key: str) -> None:
        stats.setdefault(q, {"tp": 0, "fp": 0, "fn": 0})[key] += 1

    for cr in results:
        if cr.status not in ("PASS", "FAIL"):
            continue
        loaded = set(cr.loaded)
        groups = [qualify(g, index) for g in cr.case.expect]
        for g in groups:
            hit = [q for q in g if q in loaded]
            for q in hit:
                bump(q, "tp")
            if g and not hit:
                bump(g[0], "fn")
        expected = {q for g in groups for q in g}
        for q in loaded - expected - set(qualify(cr.case.accept, index)):
            bump(q, "fp")
    for s in stats.values():
        s["precision"] = s["tp"] / (s["tp"] + s["fp"]) if s["tp"] + s["fp"] else None
        s["recall"] = s["tp"] / (s["tp"] + s["fn"]) if s["tp"] + s["fn"] else None
    return dict(sorted(stats.items()))


def summarize(results: list[CaseResult], stats: dict[str, dict]) -> dict:
    tp, fp, fn = (sum(s[k] for s in stats.values()) for k in ("tp", "fp", "fn"))
    by = {k: sum(1 for r in results if r.status == k) for k in ("PASS", "FAIL", "ERROR", "SKIP")}
    runs = [r for cr in results for r in cr.runs]
    return {
        "cases": len(results), **{k.lower(): v for k, v in by.items()},
        "tp": tp, "fp": fp, "fn": fn,
        "precision": tp / (tp + fp) if tp + fp else None,
        "recall": tp / (tp + fn) if tp + fn else None,
        "runs": len(runs), "cost_usd": round(sum(r.cost_usd for r in runs), 4),
        "runs_with_cost": sum(1 for r in runs if r.cost_usd),
        "tokens": {k: sum(r.tokens.get(k, 0) for r in runs) for k in ("input", "cache_write", "cache_read", "output")},
        "models": sorted({r.model for r in runs if r.model}),
        "listing": sorted({r.listing for r in runs if r.listing}),
        "rejected_calls": sum(len(r.rejected) for r in runs),
        "bad_lines": sum(r.bad_lines for r in runs),
    }


# --- reporting --------------------------------------------------------------------------------

def _pct(v) -> str:
    return "-" if v is None else f"{v:.0%}"


def _labels(qs: list[str], index: SkillIndex, rates: dict[str, float] | None = None) -> str:
    out = []
    for q in qs:
        lab = index.label(q)
        if rates and 0 < rates.get(q, 1) < 1:
            lab += f" ({rates[q]:.0%})"
        out.append(lab)
    return ", ".join(out) or "-"


def _expected(case: Case, index: SkillIndex) -> str:
    return ", ".join("|".join(index.label(a) for a in g) for g in case.expect) or "(none)"


def rows(results: list[CaseResult], index: SkillIndex) -> list[list[str]]:
    out = []
    for r in results:
        loaded = _labels(r.loaded, index, r.rates)
        if r.other:
            loaded += " + other: " + ", ".join(r.other)
        out.append([r.case.id, _expected(r.case, index), loaded, _labels(r.forbidden, index),
                    r.status + (f" ({r.reason})" if r.reason and r.status != "PASS" else "")])
    return out


def text_report(results: list[CaseResult], stats: dict, summary: dict, index: SkillIndex) -> str:
    head = ["id", "expected", "loaded", "forbidden hits", "result"]
    body = rows(results, index)
    widths = [min(max(len(x[i]) for x in [head] + body), cap) for i, cap in enumerate((34, 40, 48, 28, 60))]

    def fmt(cols):
        return "  ".join((c if len(c) <= w else c[: w - 1] + "…").ljust(w) for c, w in zip(cols, widths)).rstrip()
    lines = [fmt(head), fmt(["-" * w for w in widths])] + [fmt(b) for b in body]
    lines += ["", "per-skill precision / recall (repo skills that were expected or loaded):",
              f"  {'skill':44} {'TP':>3} {'FP':>3} {'FN':>3}  precision  recall"]
    for q, s in stats.items():
        lines.append(f"  {index.label(q):44} {s['tp']:>3} {s['fp']:>3} {s['fn']:>3}  {_pct(s['precision']):>9}  {_pct(s['recall']):>6}")
    lines += ["", summary_line(summary)] + [listing_note(x) for x in summary.get("listing", [])]
    return "\n".join(lines)


def listing_note(warning: str) -> str:
    return (f"⚠ {warning}: Claude Code cut skill descriptions to fit the listing, so some skills were "
            f"routed on a shortened description (as in a real session with these plugins). "
            f"--listing-budget 0.03 raises the budget (setting skillListingBudgetFraction).")


def summary_line(s: dict) -> str:
    t = s.get("tokens") or {}
    tok = (f"tokens in {t.get('input', 0) + t.get('cache_write', 0) + t.get('cache_read', 0):,} "
           f"(cache write {t.get('cache_write', 0):,}, read {t.get('cache_read', 0):,}), out {t.get('output', 0):,}+")
    cost = f", ${s['cost_usd']:.2f} reported by {s['runs_with_cost']} run(s)" if s.get("runs_with_cost") else ""
    odd = [f"{n} {what}" for n, what in ((s.get("rejected_calls", 0), "Skill call(s) rejected by the CLI, not scored"),
                                         (s.get("bad_lines", 0), "unreadable stream line(s)")) if n]
    return (f"{s['pass']}/{s['cases']} cases passed ({s['fail']} failed, {s['error']} errors, {s['skip']} skipped); "
            f"micro precision {_pct(s['precision'])}, recall {_pct(s['recall'])} (TP {s['tp']}, FP {s['fp']}, FN {s['fn']}); "
            f"{s['runs']} runs, {tok}{cost}; model {', '.join(s['models']) or '?'}" + "".join(f"; {x}" for x in odd))


def markdown_report(results: list[CaseResult], stats: dict, summary: dict, index: SkillIndex) -> str:
    def cell(x: str) -> str:
        return x.replace("|", "\\|").replace("\n", " ")
    out = ["## Skill trigger evals", "", summary_line(summary), "",
           *[listing_note(x) + "\n" for x in summary.get("listing", [])],
           "| id | expected | loaded | forbidden hits | result |", "|---|---|---|---|---|"]
    for r in rows(results, index):
        r[-1] = ("✓ " if r[-1].startswith("PASS") else "✗ " if r[-1].startswith(("FAIL", "ERROR")) else "") + r[-1]
        out.append("| " + " | ".join(cell(c) for c in r) + " |")
    out += ["", "<details><summary>Per-skill precision / recall</summary>", "",
            "| skill | TP | FP | FN | precision | recall |", "|---|---:|---:|---:|---:|---:|"]
    for q, s in stats.items():
        out.append(f"| {cell(index.label(q))} | {s['tp']} | {s['fp']} | {s['fn']} | {_pct(s['precision'])} | {_pct(s['recall'])} |")
    out += ["", "</details>", ""]
    return "\n".join(out)


def json_report(results: list[CaseResult], stats: dict, summary: dict) -> dict:
    return {
        "summary": summary,
        "cases": [{
            "id": r.case.id, "status": r.status, "reason": r.reason, "prompt": r.case.prompt,
            "expect": ["|".join(g) for g in r.case.expect], "accept": r.case.accept, "forbid": r.case.forbid,
            "loaded": r.loaded, "rates": r.rates, "other": r.other, "missing": r.missing,
            "forbidden": r.forbidden, "extra": r.extra,
            "runs": [{"invoked": x.invoked, "rejected": x.rejected, "bad_lines": x.bad_lines,
                      "error": x.error, "cost_usd": x.cost_usd, "tokens": x.tokens,
                      "seconds": round(x.seconds, 1),
                      "model": x.model, "stopped_early": x.stopped_early, "stop_reason": x.stop_reason,
                      "listing": x.listing} for x in r.runs],
        } for r in results],
        "skills": stats,
    }


# --- credentials / CLI --------------------------------------------------------------------------

def credentials(claude: str, env: dict[str, str] | None = None, runner=subprocess.run) -> tuple[bool, str]:
    env = os.environ if env is None else env
    for var in CREDENTIAL_VARS:
        # CLAUDE_CODE_USE_BEDROCK=0 and friends switch a provider off, they are no credentials
        if env.get(var, "").strip().lower() not in ("", "0", "false", "no", "off"):
            return True, var
    try:
        r = runner([claude, "auth", "status"], capture_output=True, text=True, timeout=60,
                   env={k: v for k, v in env.items() if k not in PARENT_SESSION_VARS})
    except (OSError, subprocess.SubprocessError):
        return False, "claude auth status failed"
    if r.returncode == 0:
        return True, "claude auth status"
    return False, "no ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN and the CLI is not logged in"


def cli_supports(claude: str) -> set[str]:
    """Optional flags this CLI version knows (from --help; no model call)."""
    try:
        text = subprocess.run([claude, "--help"], capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError):
        return set()
    return {f for f in ("--restricted", "--permission-prompts", "--debug-file") if f in text}


def select_plugins(args) -> list[Path]:
    dirs = plugin_dirs(ROOT)
    names = None
    if args.plugins:
        names = {p.strip() for p in args.plugins.split(",") if p.strip()}
    if args.profile:
        prof = json.loads((ROOT / "profiles.json").read_text(encoding="utf-8")).get("profiles", {})
        if args.profile not in prof:
            raise SystemExit(f"eval-triggers: unknown profile {args.profile!r} (have: {', '.join(prof)})")
        names = (names or set()) | set(prof[args.profile])
    if names is None:
        return dirs
    known = {plugin_name(d) for d in dirs}
    unknown = sorted(names - known)
    if unknown:
        print(f"eval-triggers: not a local plugin, ignored: {', '.join(unknown)}", file=sys.stderr)
    return [d for d in dirs if plugin_name(d) in names]


# --- main ---------------------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Skill trigger evals (see the module docstring).",
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cases", type=Path, default=DEFAULT_CASES, help="triggers YAML (default: %(default)s)")
    ap.add_argument("--filter", help="regex on case id, prompt, tags and expected skills")
    ap.add_argument("--limit", type=int, help="run only the first N selected cases")
    ap.add_argument("--plugins", help="comma-separated plugin names to load (default: every local plugin)")
    ap.add_argument("--profile", help="load the plugins of this profiles.json profile")
    ap.add_argument("--model", help="model alias or id passed to claude (default: the CLI's default)")
    ap.add_argument("--effort", help="effort level passed to claude")
    ap.add_argument("--jobs", type=int, default=4, help="parallel runs (default: %(default)s)")
    ap.add_argument("--runs", type=int, default=1, help="runs per case; a skill counts as loaded when it loads "
                                                        "in at least --threshold of them (default: %(default)s)")
    ap.add_argument("--threshold", type=float, default=0.5, help="share of runs (default: %(default)s)")
    ap.add_argument("--timeout", type=int, default=180, help="seconds per run (default: %(default)s)")
    ap.add_argument("--max-turns", type=int, default=4, help="passed to claude (default: %(default)s)")
    ap.add_argument("--max-budget-usd", type=float, default=0.5, help="per run, passed to claude (default: %(default)s)")
    ap.add_argument("--stop-after", type=int, default=400,
                    help="stop a run once the model wrote this many characters of answer text (default: %(default)s)")
    ap.add_argument("--no-early-stop", action="store_true", help="let every run finish its answer")
    ap.add_argument("--listing-budget", type=float, metavar="FRACTION",
                    help="skillListingBudgetFraction for the session (the CLI default is 0.01 of the context "
                         "window; with every plugin loaded the listing overflows it and descriptions are cut)")
    ap.add_argument("--keep-bundled-skills", action="store_true",
                    help="keep Claude Code's bundled skills (off by default: never scored, costly when mis-invoked)")
    ap.add_argument("--claude", default=os.environ.get("CLAUDE_BIN", "claude"), help="claude executable")
    ap.add_argument("--json", type=Path, help="write the full results as JSON")
    ap.add_argument("--markdown", type=Path, help="append a Markdown summary (e.g. \"$GITHUB_STEP_SUMMARY\")")
    ap.add_argument("--record", help="save each run's raw stream-json to DIR/<id>.<run>.jsonl")
    ap.add_argument("--dry-run", action="store_true", help="validate the cases and print the commands; no model calls")
    ap.add_argument("--no-fail", action="store_true", help="exit 0 even when cases fail")
    ap.add_argument("--require-credentials", action="store_true", help="exit 3 instead of skipping without credentials")
    args = ap.parse_args(argv)

    errors: list[str] = []
    cases = load_cases(args.cases, errors)
    index = SkillIndex(load_skills(ROOT))
    errors += validate_cases(cases, index)
    if errors:
        print("\n".join(f"✗ {e}" for e in errors), file=sys.stderr)
        return 2
    plugin_paths = select_plugins(args)
    loaded_plugins = {plugin_name(p) for p in plugin_paths}

    selected = cases
    if args.filter:
        try:
            rx = re.compile(args.filter, re.I)
        except re.error as e:  # a usage error (2), not a failed case (1)
            print(f"✗ --filter: {e}", file=sys.stderr)
            return 2
        selected =[c for c in cases if any(rx.search(x) for x in (c.id, c.prompt, *c.tags, *(a for g in c.expect for a in g)))]
    if args.limit is not None:
        selected = selected[: args.limit]
    if not selected:
        print("eval-triggers: no cases selected", file=sys.stderr)
        return 2

    skipped = []
    runnable = []
    for c in selected:
        need = {index.resolve(a).plugin for g in c.expect for a in g}
        if need - loaded_plugins:
            skipped.append(CaseResult(c, "SKIP", reason="needs plugin " + ", ".join(sorted(need - loaded_plugins))))
        else:
            runnable.append(c)

    claude = shutil.which(args.claude) or (args.claude if Path(args.claude).exists() else None)
    if args.dry_run:
        supports = cli_supports(claude) if claude else {"--restricted", "--permission-prompts", "--debug-file"}
        for c in runnable:
            cmd = build_command(args, plugin_paths, "<fresh-uuid>", supports)
            print(f"# {c.id}\nprintf '%s' {shlex.quote(c.prompt)} | env -u {' -u '.join(PARENT_SESSION_VARS)} "
                  f"CLAUDE_CODE_PROMPT_CACHE_TTL=5m {shlex.join(cmd)}\n")
        print(f"dry run: {len(runnable)} case(s) x {args.runs} run(s), {len(plugin_paths)} plugin(s), "
              f"{len(skipped)} skipped; cases file valid", file=sys.stderr)
        return 0
    if not claude:
        print(f"✗ claude CLI not found ({args.claude}); install it: curl -fsSL https://claude.ai/install.sh | bash",
              file=sys.stderr)
        return 2
    has_creds, why = credentials(claude)
    if not has_creds:
        msg = f"SKIPPED: skill trigger evals need credentials ({why})"
        print(msg)
        if os.environ.get("GITHUB_ACTIONS") == "true":
            print(f"::notice title=Skill trigger evals::{msg}")
        if args.markdown:
            with open(args.markdown, "a", encoding="utf-8") as fh:
                fh.write(f"## Skill trigger evals\n\n{msg}\n")
        return 3 if args.require_credentials else 0
    supports = cli_supports(claude)
    args.claude = claude

    jobs = [(c, i) for c in runnable for i in range(args.runs)]
    runs: dict[str, list[RunResult]] = {c.id: [] for c in runnable}
    done, abort = 0, ""
    lock = threading.Lock()
    print(f"eval-triggers: {len(runnable)} case(s) x {args.runs} run(s), {len(plugin_paths)} plugin(s), "
          f"{args.jobs} parallel", file=sys.stderr)
    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool, \
            tempfile.TemporaryDirectory(prefix="skill-eval-") as cwd:
        pending = {}
        queue = list(jobs)

        def submit_next() -> None:
            while queue and len(pending) < max(1, args.jobs):
                with lock:
                    if abort:
                        return
                c, i = queue.pop(0)
                pending[pool.submit(run_once, c, i, args, plugin_paths, supports, cwd)] = (c, i)

        submit_next()
        while pending:
            fut = next(as_completed(list(pending)))
            c, i = pending.pop(fut)
            r = fut.result()
            with lock:
                done += 1
                runs[c.id].append(r)
                if r.error and AUTH_ERROR_RX.search(r.error) and not any(x.invoked or not x.error for rs in runs.values() for x in rs):
                    abort = r.error
            names = ", ".join(index.label(n) for n in r.invoked) or "-"
            state = f"ERROR {r.error[:120]}" if r.error else f"loaded: {names}"
            if r.rejected:
                state += f"; rejected by the CLI: {', '.join(r.rejected)}"
            if r.bad_lines:
                state += f"; {r.bad_lines} unreadable stream line(s)"
            print(f"[{done}/{len(jobs)}] {c.id} #{i}: {state} ({r.seconds:.0f}s)", file=sys.stderr)
            for pe in r.plugin_errors:
                print(f"  plugin error: {pe}", file=sys.stderr)
            submit_next()
    if abort:
        print(f"✗ credentials rejected, stopped: {abort}", file=sys.stderr)
        return 2

    results = []
    for c in selected:
        if c.id in runs:
            results.append(score_case(c, runs[c.id], index, args.threshold))
        else:
            results.append(next(s for s in skipped if s.case.id == c.id))
    stats = skill_stats(results, index)
    summary = summarize(results, stats)
    print(text_report(results, stats, summary, index))
    if args.json:
        args.json.write_text(json.dumps(json_report(results, stats, summary), indent=2) + "\n", encoding="utf-8")
    if args.markdown:
        with open(args.markdown, "a", encoding="utf-8") as fh:
            fh.write(markdown_report(results, stats, summary, index))
    failed = summary["fail"] + summary["error"]
    return 1 if failed and not args.no_fail else 0


if __name__ == "__main__":
    sys.exit(main())
