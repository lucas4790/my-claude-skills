"""Offline tests for scripts/eval-triggers.py: stream-json parsing on recorded runs, scoring and
precision/recall math, the command's safety flags, the credentials contract, and one end-to-end run
against a fake `claude` that replays the fixtures. No network, no model calls."""
import importlib.util
import json
import os
import stat
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True  # keep scripts/__pycache__ out of the working tree
FIXTURES = Path(__file__).resolve().parent / "fixtures"
sys.path.insert(0, str(ROOT / "scripts"))


def _load_runner():
    spec = importlib.util.spec_from_file_location("eval_triggers", ROOT / "scripts" / "eval-triggers.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["eval_triggers"] = mod
    spec.loader.exec_module(mod)
    return mod


et = _load_runner()
from skill_descriptions import Skill  # noqa: E402


def feed_all(parser, name, stop=True):
    """Feed a fixture; with stop=True, stop where the runner would stop."""
    for line in (FIXTURES / name).read_text(encoding="utf-8").splitlines():
        if parser.feed(line) and stop:
            return True
    return False


# --- stream parsing ---------------------------------------------------------------------------

def test_partial_stream_detects_skill_then_stops_on_answer():
    p = et.StreamParser(stop_after_chars=400)
    assert feed_all(p, "partial-skill-then-answer.jsonl") is True
    assert p.invoked == ["powershell:pester"]
    assert p.invocations[0].ok is True          # tool_result "Launching skill: ..." seen
    assert p.stopped_early and p.text_chars >= 400
    assert p.error == ""                        # an early stop is not a failure
    assert p.init["model"] == "test-model"
    assert p.usage["cache_write"] > 0 and p.usage["output"] > 0


def test_partial_stream_without_skill():
    p = et.StreamParser(stop_after_chars=400)
    assert feed_all(p, "partial-answer-no-skill.jsonl") is True
    assert p.invoked == [] and p.stopped_early


def test_no_early_stop_reads_to_the_end():
    p = et.StreamParser(stop_after_chars=None)
    assert feed_all(p, "partial-answer-no-skill.jsonl") is False
    assert not p.stopped_early and p.error == "no result event"  # the fixture is cut before the result


def test_complete_events_and_result():
    """Runs without --include-partial-messages deliver whole content blocks, then a result."""
    p = et.StreamParser(stop_after_chars=None)
    feed_all(p, "complete-events-with-result.jsonl", stop=False)
    assert p.invoked == ["powershell:pester"]
    assert p.result["subtype"] == "success" and p.error == ""
    # the same stream stops at the answer block when early stop is on
    p2 = et.StreamParser(stop_after_chars=400)
    assert feed_all(p2, "complete-events-with-result.jsonl") is True
    assert p2.stopped_early and not p2.result and p2.invoked == ["powershell:pester"]


def test_api_error_is_an_error_not_an_answer():
    p = et.StreamParser(stop_after_chars=10)   # the synthetic notice is longer than 10 chars
    feed_all(p, "api-error-unknown-model.jsonl")
    assert not p.stopped_early
    assert "selected model" in p.error and "HTTP 404" in p.error


def test_stops_when_the_model_reaches_for_another_tool():
    """Real run: AKS skill, a bundled skill, a short preamble, then a Write call (a tool that does not
    exist in the session). Routing is settled at that point; waiting would only burn tokens."""
    p = et.StreamParser(stop_after_chars=400)
    assert feed_all(p, "partial-skill-then-write-tool.jsonl") is True
    assert p.stop_reason == "tool:Write" and p.stopped_early and p.error == ""
    assert p.invoked == ["azure-agent-skills:azure-kubernetes-service", "update-config"]
    assert et.StreamParser(stop_after_chars=None).feed(
        '{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_start",'
        '"content_block":{"type":"tool_use","name":"Write"}}}') is False   # --no-early-stop keeps going


def test_listing_budget_warning_regex():
    line = "2026-09-28T22:09:34Z [WARN] Skill listing over budget: 136 skills, 64398 chars > 30000 budget — descriptions"
    m = et.LISTING_RX.search(line)
    assert m and m.groups() == ("136", "64398", "30000")


def test_max_turns_counts_as_completed():
    p = et.StreamParser(stop_after_chars=None)
    feed_all(p, "max-turns-after-skill.jsonl", stop=False)
    assert p.result["subtype"] == "error_max_turns"
    assert p.error == "" and p.invoked == ["powershell:powershell-safe-invocation"]


def test_parser_ignores_noise_and_subagent_text():
    p = et.StreamParser(stop_after_chars=5)
    assert p.feed("not json") is False and p.bad_lines == 1
    assert p.feed("") is False and p.feed("[1, 2]") is False
    sub = {"type": "assistant", "parent_tool_use_id": "toolu_x",
           "message": {"content": [{"type": "text", "text": "a long subagent answer"}]}}
    assert p.feed(json.dumps(sub)) is False
    dup = {"type": "assistant", "parent_tool_use_id": None, "message": {"content": [
        {"type": "tool_use", "id": "t1", "name": "Skill", "input": {"skill": "pester"}}]}}
    p.feed(json.dumps(dup))
    p.feed(json.dumps(dup))                      # the same tool_use delivered twice counts once
    assert p.invoked == ["pester"]


def test_a_skill_call_the_cli_rejected_is_not_a_load():
    p = et.StreamParser(stop_after_chars=None)
    events = [
        {"type": "assistant", "parent_tool_use_id": None, "message": {"content": [
            {"type": "tool_use", "id": "t1", "name": "Skill", "input": {"skill": "powershell:pester"}},
            {"type": "tool_use", "id": "t2", "name": "Skill", "input": {"skill": "powershell:ghost"}},
            {"type": "tool_use", "id": "t3", "name": "Skill", "input": {"skill": "azure-dns"}}]}},
        {"type": "user", "parent_tool_use_id": None, "message": {"content": [
            {"type": "tool_result", "tool_use_id": "t1", "content": "Launching skill: powershell:pester"},
            {"type": "tool_result", "tool_use_id": "t2", "is_error": True, "content": "Unknown skill: powershell:ghost"}]}},
    ]                                           # t3: no result yet (a run can stop first); it counts
    for e in events:
        p.feed(json.dumps(e))
    p.feed("{truncated")
    assert p.invoked == ["powershell:pester", "azure-dns"] and p.rejected == ["powershell:ghost"]
    assert p.bad_lines == 1
    ix = make_index()
    r = et.RunResult("c1", 0, invoked=p.invoked, rejected=p.rejected, bad_lines=p.bad_lines)
    cr = et.score_case(case(expect=["pester"]), [r], ix)
    assert cr.status == "PASS" and cr.other == []  # the rejected call is neither loaded nor "other"
    s = et.summarize([cr], et.skill_stats([cr], ix))
    assert (s["rejected_calls"], s["bad_lines"]) == (1, 1)
    line = et.summary_line(s)
    assert "1 Skill call(s) rejected by the CLI" in line and "1 unreadable stream line(s)" in line
    run_json = et.json_report([cr], {}, s)["cases"][0]["runs"][0]
    assert run_json["rejected"] == ["powershell:ghost"] and run_json["bad_lines"] == 1


def test_text_after_a_tool_use_in_the_same_message_does_not_stop():
    p = et.StreamParser(stop_after_chars=5)
    events = [
        {"type": "stream_event", "parent_tool_use_id": None, "event": {"type": "message_start", "message": {}}},
        {"type": "stream_event", "parent_tool_use_id": None,
         "event": {"type": "content_block_start", "content_block": {"type": "tool_use", "name": "Skill"}}},
        {"type": "stream_event", "parent_tool_use_id": None,
         "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "0123456789"}}},
    ]
    assert not any(p.feed(json.dumps(e)) for e in events)


# --- index, cases, scoring ---------------------------------------------------------------------

def make_index():
    def s(plugin, name, dmi=False):
        return Skill(plugin, name, f"plugins/{plugin}/skills/{name}/SKILL.md", f"{name} description. Use when x.",
                     model_invocable=not dmi)
    return et.SkillIndex([
        s("azure-agent-skills", "azure-kubernetes-service"), s("azure-agent-skills", "azure-pipelines"),
        s("azure-agent-skills", "azure-devops"), s("azure-agent-skills", "azure-private-link"),
        s("azure-agent-skills", "azure-dns"), s("powershell", "pester"),
        s("powershell", "powershell-safe-invocation"), s("mattpocock-skills", "diagnosing-bugs"),
        s("dotnet-test", "filter-syntax", dmi=True), s("a", "dup"), s("b", "dup"),
    ])


def test_index_resolves_bare_qualified_and_slash_names():
    ix = make_index()
    assert ix.resolve("pester").qualified == "powershell:pester"
    assert ix.resolve("powershell:pester").qualified == "powershell:pester"
    assert ix.resolve("/powershell:pester").qualified == "powershell:pester"
    assert ix.resolve("code-review") is None          # bundled skill: not ours
    assert ix.resolve("anthropic-skills:docs") is None
    assert ix.resolve("dup") is None and "dup" in ix.ambiguous
    assert ix.resolve("a:dup").qualified == "a:dup"
    assert ix.label("azure-agent-skills:azure-pipelines") == "azure-pipelines"
    assert ix.label("a:dup") == "a:dup"


def case(**kw):
    errors = []
    data = {"id": "c1", "prompt": "p", "expect": [], **kw}
    cases = et.parse_cases({"cases": [data]}, errors)
    assert not errors, errors
    return cases[0]


def run(*invoked, error=""):
    return et.RunResult("c1", 0, invoked=list(invoked), error=error)


def test_score_positive_case():
    ix = make_index()
    c = case(expect=["azure-pipelines"], accept=["azure-kubernetes-service"], forbid=["azure-devops"])
    assert et.score_case(c, [run("azure-agent-skills:azure-pipelines")], ix).status == "PASS"
    r = et.score_case(c, [run("azure-agent-skills:azure-pipelines", "azure-agent-skills:azure-devops")], ix)
    assert r.status == "FAIL" and r.forbidden == ["azure-agent-skills:azure-devops"]
    r = et.score_case(c, [run("code-review")], ix)
    assert r.status == "FAIL" and r.missing == ["azure-agent-skills:azure-pipelines"] and r.other == ["code-review"]
    # an unrelated extra repo skill is reported but does not fail a non-strict positive case
    r = et.score_case(c, [run("azure-agent-skills:azure-pipelines", "powershell:pester")], ix)
    assert r.status == "PASS" and r.extra == ["powershell:pester"]
    r = et.score_case(case(expect=["azure-pipelines"], strict=True),
                      [run("azure-agent-skills:azure-pipelines", "powershell:pester")], ix)
    assert r.status == "FAIL"


def test_score_negative_case_and_alternatives():
    ix = make_index()
    neg = case(expect=[], accept=["diagnosing-bugs"], forbid=["azure-kubernetes-service"])
    assert et.score_case(neg, [run()], ix).status == "PASS"
    assert et.score_case(neg, [run("mattpocock-skills:diagnosing-bugs", "debug")], ix).status == "PASS"
    assert et.score_case(neg, [run("powershell:pester")], ix).status == "FAIL"  # any other repo skill
    alt = case(expect=["azure-private-link|azure-dns"])
    assert et.score_case(alt, [run("azure-dns")], ix).status == "PASS"
    assert et.score_case(alt, [run()], ix).missing == ["azure-agent-skills:azure-private-link|azure-agent-skills:azure-dns"]


def test_score_multiple_runs_threshold_and_errors():
    ix = make_index()
    c = case(expect=["pester"])
    runs = [run("pester"), run("pester"), run()]
    r = et.score_case(c, runs, ix, threshold=0.5)
    assert r.status == "PASS" and r.rates == {"powershell:pester": pytest.approx(2 / 3)}
    assert et.score_case(c, runs, ix, threshold=0.9).status == "FAIL"
    assert et.score_case(c, [run(error="timeout"), run("pester")], ix).status == "PASS"  # errored runs are excluded
    r = et.score_case(c, [run(error="timeout after 5s")], ix)
    assert r.status == "ERROR" and "timeout" in r.reason


def test_skill_stats_precision_recall():
    ix = make_index()
    results = [
        et.score_case(case(expect=["azure-pipelines"], forbid=["azure-devops"]),
                      [run("azure-pipelines", "azure-devops")], ix),                   # TP pipelines, FP devops
        et.score_case(case(expect=["azure-pipelines"]), [run()], ix),                 # FN pipelines
        et.score_case(case(expect=["azure-devops"], accept=["azure-pipelines"]),
                      [run("azure-devops", "azure-pipelines")], ix),                   # TP devops, accepted pipelines
        et.score_case(case(expect=["azure-private-link|azure-dns"]), [run()], ix),    # FN goes to the first alternative
        et.score_case(case(expect=["pester"]), [run(error="boom")], ix),              # errors are not scored
    ]
    st = et.skill_stats(results, ix)
    assert st["azure-agent-skills:azure-pipelines"] == {"tp": 1, "fp": 0, "fn": 1, "precision": 1.0, "recall": 0.5}
    assert st["azure-agent-skills:azure-devops"] == {"tp": 1, "fp": 1, "fn": 0, "precision": 0.5, "recall": 1.0}
    assert st["azure-agent-skills:azure-private-link"]["fn"] == 1 and "azure-agent-skills:azure-dns" not in st
    assert "powershell:pester" not in st
    s = et.summarize(results, st)
    assert (s["tp"], s["fp"], s["fn"]) == (2, 1, 2)
    assert s["precision"] == pytest.approx(2 / 3) and s["recall"] == pytest.approx(0.5)
    assert (s["pass"], s["fail"], s["error"]) == (1, 3, 1)
    text = et.text_report(results, st, s, ix)
    assert "azure-pipelines" in text and "50%" in text
    md = et.markdown_report(results, st, s, ix)
    assert md.startswith("## Skill trigger evals") and "| id | expected |" in md
    assert "azure-private-link\\|azure-dns" in md          # pipes escaped inside table cells
    json.dumps(et.json_report(results, st, s))             # serializable


def test_parse_cases_reports_schema_errors():
    errors = []
    et.parse_cases({"cases": [
        {"id": "Bad Id", "prompt": "", "expect": "pester", "colour": 1},
        {"id": "x", "prompt": "p"},
        {"id": "x", "prompt": "p", "expect": [1], "strict": "yes", "tags": "a"},
        "not a mapping",
    ]}, errors)
    joined = "\n".join(errors)
    for needle in ("lowercase-hyphen", "non-empty", "unknown key 'colour'", "expect is required",
                   "duplicate id", "list of skill names", "strict must be", "tags must be", "not a mapping"):
        assert needle in joined, needle
    errors = []
    assert et.parse_cases({"nope": 1}, errors) == [] and errors


def test_validate_cases_names():
    ix = make_index()
    errs = et.validate_cases([case(expect=["nope", "filter-syntax"], forbid=["dup"]),
                              case(expect=["pester"], forbid=["powershell:pester"])], ix)
    joined = "\n".join(errs)
    assert "unknown skill 'nope'" in joined
    assert "disable-model-invocation" in joined
    assert "ambiguous" in joined
    assert "both forbidden and expected" in joined


# --- command, environment, credentials --------------------------------------------------------

class Args:
    claude = "claude"
    max_turns = 4
    max_budget_usd = 0.5
    model = "sonnet"
    effort = None
    listing_budget = None
    keep_bundled_skills = False


def test_command_only_allows_the_skill_tool():
    cmd = et.build_command(Args(), [Path("/p/a"), Path("/p/b")], "11111111-2222-3333-4444-555555555555",
                           {"--restricted", "--permission-prompts", "--debug-file"}, "/tmp/d.log")
    assert cmd[:2] == ["claude", "-p"]
    joined = " ".join(cmd)
    assert "dangerously" not in joined and "bypassPermissions" not in joined
    assert cmd[cmd.index("--tools") + 1] == "Skill"
    assert cmd[cmd.index("--allowedTools") + 1] == "Skill"
    denied = cmd[cmd.index("--disallowedTools") + 1].split(",")
    assert {"Bash", "Edit", "Write", "WebFetch", "mcp__*"} <= set(denied)
    assert cmd[cmd.index("--permission-mode") + 1] == "dontAsk"
    for flag in ("--strict-mcp-config", "--no-session-persistence", "--restricted", "--verbose"):
        assert flag in cmd
    assert cmd[cmd.index("--output-format") + 1] == "stream-json"
    assert cmd[cmd.index("--session-id") + 1] == "11111111-2222-3333-4444-555555555555"
    assert json.loads(cmd[cmd.index("--settings") + 1]) == {
        "disableAllHooks": True, "disableSkillShellExecution": True, "disableBundledSkills": True}
    assert cmd.count("--plugin-dir") == 2 and cmd[cmd.index("--model") + 1] == "sonnet"
    assert cmd[cmd.index("--debug-file") + 1] == "/tmp/d.log"
    older = et.build_command(Args(), [], "u", set(), "/tmp/d.log")
    assert not {"--restricted", "--permission-prompts", "--debug-file"} & set(older)
    a = Args()
    a.listing_budget, a.keep_bundled_skills = 0.03, True
    settings = json.loads(et.build_command(a, [], "u", set())[et.build_command(a, [], "u", set()).index("--settings") + 1])
    assert settings == {"disableAllHooks": True, "disableSkillShellExecution": True, "skillListingBudgetFraction": 0.03}


def test_child_env_drops_parent_session(monkeypatch):
    monkeypatch.setenv("CLAUDE_CODE_SESSION_ID", "parent")
    monkeypatch.setenv("CLAUDE_CODE_REMOTE_SESSION_ID", "parent")
    monkeypatch.setenv("CLAUDECODE", "1")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "k")
    monkeypatch.delenv("CLAUDE_CODE_PROMPT_CACHE_TTL", raising=False)
    env = et.child_env()
    assert not {"CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_REMOTE_SESSION_ID", "CLAUDECODE"} & set(env)
    assert env["ANTHROPIC_API_KEY"] == "k" and env["CLAUDE_CODE_PROMPT_CACHE_TTL"] == "5m"
    monkeypatch.setenv("CLAUDE_CODE_PROMPT_CACHE_TTL", "1h")
    assert et.child_env()["CLAUDE_CODE_PROMPT_CACHE_TTL"] == "1h"   # the caller's choice wins


def test_credentials_contract():
    calls = []

    def runner(rc):
        def _run(cmd, **kw):
            calls.append(cmd)
            return subprocess.CompletedProcess(cmd, rc, "", "")
        return _run
    assert et.credentials("claude", {"ANTHROPIC_API_KEY": "x"}, runner(1)) == (True, "ANTHROPIC_API_KEY")
    assert et.credentials("claude", {"CLAUDE_CODE_OAUTH_TOKEN": "x"}, runner(1))[0]
    assert calls == []                                      # env credentials: no CLI call at all
    assert et.credentials("claude", {"ANTHROPIC_API_KEY": ""}, runner(0)) == (True, "claude auth status")
    assert calls[-1] == ["claude", "auth", "status"]
    ok, why = et.credentials("claude", {}, runner(1))
    assert not ok and "not logged in" in why
    for off in ("0", "false", "OFF", " "):                  # a switched-off provider is no credential
        assert et.credentials("claude", {"CLAUDE_CODE_USE_BEDROCK": off}, runner(1))[0] is False

    def boom(cmd, **kw):
        raise OSError("gone")
    assert et.credentials("claude", {}, boom)[0] is False


# --- end to end with a fake CLI -----------------------------------------------------------------

FAKE_CLAUDE = textwrap.dedent("""\
    #!{python}
    import json, os, sys, time
    log = os.environ["FAKE_CLAUDE_LOG"]
    with open(log, "a") as fh:
        fh.write(json.dumps(sys.argv[1:]) + "\\n")
    args = sys.argv[1:]
    if args[:1] == ["--help"]:
        print("  --restricted\\n  --permission-prompts <target>\\n  --debug-file <path>"); sys.exit(0)
    if "--debug-file" in args:
        with open(args[args.index("--debug-file") + 1], "w") as fh:
            fh.write("[WARN] Skill listing over budget: 121 skills, 57838 chars > 30000 budget — descriptions\\n")
    if args[:2] == ["auth", "status"]:
        sys.exit(int(os.environ.get("FAKE_AUTH_RC", "1")))
    if "-p" in args:
        prompt = sys.stdin.read()
        name = {{"PESTER": "partial-skill-then-answer.jsonl", "KUBECTL": "partial-answer-no-skill.jsonl",
                 "BADMODEL": "api-error-unknown-model.jsonl"}}.get(prompt.split()[0])
        if name is None:
            time.sleep(30); sys.exit(0)
        for line in open(os.path.join({fixtures!r}, name)):
            sys.stdout.write(line); sys.stdout.flush()
        sys.exit(0)
    sys.exit(2)
""")


@pytest.fixture
def fake_cli(tmp_path, monkeypatch):
    exe = tmp_path / "claude"
    exe.write_text(FAKE_CLAUDE.format(python=sys.executable, fixtures=str(FIXTURES)), encoding="utf-8")
    exe.chmod(exe.stat().st_mode | stat.S_IEXEC)
    log = tmp_path / "calls.jsonl"
    monkeypatch.setenv("FAKE_CLAUDE_LOG", str(log))
    for var in et.CREDENTIAL_VARS:
        monkeypatch.delenv(var, raising=False)
    cases = tmp_path / "cases.yaml"
    cases.write_text(textwrap.dedent("""\
        cases:
          - id: pester-case
            prompt: PESTER my Pester mocks fail
            expect: [pester]
            forbid: [powershell-safe-invocation]
          - id: kubectl-case
            prompt: KUBECTL list pods
            expect: []
            forbid: [azure-kubernetes-service]
          - id: wrong-case
            prompt: KUBECTL but expecting a skill
            expect: [azure-pipelines]
          - id: error-case
            prompt: BADMODEL anything
            expect: []
          - id: hang-case
            prompt: HANG forever
            expect: []
        """), encoding="utf-8")
    return exe, log, cases, tmp_path


def calls(log):
    return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []


@pytest.mark.skipif(os.name == "nt", reason="fake CLI is a shebang script")
def test_end_to_end_with_fake_cli(fake_cli, monkeypatch, capsys):
    pytest.importorskip("yaml")
    exe, log, cases, tmp = fake_cli
    monkeypatch.setenv("ANTHROPIC_API_KEY", "dummy")
    out_json, out_md = tmp / "out.json", tmp / "summary.md"
    rc = et.main(["--cases", str(cases), "--claude", str(exe), "--jobs", "3", "--timeout", "5",
                  "--json", str(out_json), "--markdown", str(out_md), "--plugins", "powershell,azure-agent-skills"])
    assert rc == 1
    res = {c["id"]: c for c in json.loads(out_json.read_text())["cases"]}
    assert res["pester-case"]["status"] == "PASS" and res["pester-case"]["loaded"] == ["powershell:pester"]
    assert res["kubectl-case"]["status"] == "PASS"
    assert res["wrong-case"]["status"] == "FAIL"
    assert res["error-case"]["status"] == "ERROR" and "HTTP 404" in res["error-case"]["reason"]
    assert res["hang-case"]["status"] == "ERROR" and "timeout" in res["hang-case"]["reason"]
    md_text = out_md.read_text()
    assert "## Skill trigger evals" in md_text and "Skill listing over budget: 121 skills" in md_text
    runs = [c for c in calls(log) if "-p" in c]
    assert len(runs) == 5
    sessions = {c[c.index("--session-id") + 1] for c in runs}
    assert len(sessions) == 5                              # a fresh session per run
    debug_files = {c[c.index("--debug-file") + 1] for c in runs}
    assert len(debug_files) == 5                           # per-run debug log, parsed for the listing warning
    for c in runs:
        assert "--dangerously-skip-permissions" not in c and c[c.index("--tools") + 1] == "Skill"
        assert "--restricted" in c                        # detected from the fake --help
        assert all(a.startswith(str(ROOT / "plugins")) for a in (c[i + 1] for i, x in enumerate(c) if x == "--plugin-dir"))
        assert not any("PESTER" in a or "KUBECTL" in a for a in c)   # prompts go through stdin
    assert "5 runs" in capsys.readouterr().out


@pytest.mark.skipif(os.name == "nt", reason="fake CLI is a shebang script")
def test_skips_cleanly_without_credentials(fake_cli, monkeypatch, capsys):
    pytest.importorskip("yaml")
    exe, log, cases, tmp = fake_cli
    monkeypatch.setenv("FAKE_AUTH_RC", "1")
    monkeypatch.setenv("GITHUB_ACTIONS", "true")
    md = tmp / "summary.md"
    assert et.main(["--cases", str(cases), "--claude", str(exe), "--markdown", str(md)]) == 0
    out = capsys.readouterr().out
    assert "SKIPPED" in out and "::notice" in out and "SKIPPED" in md.read_text()
    assert et.main(["--cases", str(cases), "--claude", str(exe), "--require-credentials"]) == 3
    assert not [c for c in calls(log) if "-p" in c]        # never reached the model


@pytest.mark.skipif(os.name == "nt", reason="fake CLI is a shebang script")
def test_dry_run_and_config_errors(fake_cli, capsys):
    pytest.importorskip("yaml")
    exe, log, cases, tmp = fake_cli
    assert et.main(["--cases", str(cases), "--claude", str(exe), "--dry-run", "--filter", "^pester"]) == 0
    out = capsys.readouterr().out
    assert "# pester-case" in out and "--plugin-dir" in out and "env -u CLAUDE_CODE_SESSION_ID" in out
    assert not [c for c in calls(log) if "-p" in c]
    assert et.main(["--cases", str(cases), "--claude", str(exe), "--filter", "no-such-case"]) == 2
    capsys.readouterr()
    assert et.main(["--cases", str(cases), "--claude", str(exe), "--dry-run", "--filter", "("]) == 2  # usage error
    assert "✗ --filter: " in capsys.readouterr().err
    bad = tmp / "bad.yaml"
    bad.write_text("cases:\n  - id: x\n    prompt: p\n    expect: [no-such-skill]\n", encoding="utf-8")
    assert et.main(["--cases", str(bad), "--claude", str(exe), "--dry-run"]) == 2
    assert "unknown skill" in capsys.readouterr().err
    # a case that needs a plugin that is not loaded is skipped, not failed
    assert et.main(["--cases", str(cases), "--claude", str(exe), "--dry-run", "--plugins", "powershell"]) == 0
    assert "skipped" in capsys.readouterr().err
    assert et.main(["--cases", str(cases), "--claude", str(tmp / "missing-claude")]) == 2
