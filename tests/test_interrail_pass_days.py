"""Tests for plugins/interrail-planner/skills/interrail-planner/scripts/pass_days.py.

Each test encodes one rule from the Interrail Pass Conditions of Use v19
(references/pass-rules.md). No network, no files outside tmp_path.
"""

import importlib.util
import json
import sys
from datetime import date
from pathlib import Path

import pytest

SCRIPT = (Path(__file__).resolve().parents[1] / "plugins" / "interrail-planner" / "skills"
          / "interrail-planner" / "scripts" / "pass_days.py")


@pytest.fixture(scope="module")
def pd():
    spec = importlib.util.spec_from_file_location("pass_days", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["pass_days"] = mod  # dataclasses look the module up while executing
    try:
        spec.loader.exec_module(mod)
    finally:
        sys.modules.pop("pass_days", None)
    return mod


def make(pd, legs, days=10, start="2026-12-19", months=2, home="NL"):
    p = pd.parse_pass({"days": days, "start": start, "months": months, "home": home})
    return p, pd.evaluate(p, [pd.parse_leg(l) for l in legs])


def leg(d, frm="A", to="B", fc="FR", tc="FR", **kw):
    return {"date": d, "from": frm, "to": to, "from_country": fc, "to_country": tc, **kw}


def test_validity_two_months_ends_day_before(pd):
    # Interrail example: 1 month from 10 Jan is valid up to and including 9 Feb.
    p = pd.parse_pass({"days": 7, "start": "2027-01-10", "months": 1})
    assert p.end == date(2027, 2, 9)
    p2 = pd.parse_pass({"days": 10, "start": "2026-12-21", "months": 2})
    assert p2.end == date(2027, 2, 20)


def test_each_calendar_day_with_pass_leg_counts_once(pd):
    _, rep = make(pd, [leg("2026-12-21"), leg("2026-12-21", "B", "C"), leg("2026-12-22")])
    assert len(rep.travel_days) == 2
    assert not rep.errors


def test_direct_night_train_uses_departure_day_only(pd):
    # No 19:00 rule: an 18:10 departure is still one travel day.
    _, rep = make(pd, [leg("2026-12-21", dep="18:10", arr="02:15", night=True), leg("2026-12-23")])
    assert sorted(rep.travel_days) == [date(2026, 12, 21), date(2026, 12, 23)]


def test_change_after_midnight_uses_second_day_and_warns(pd):
    _, rep = make(pd, [leg("2026-12-21", night=True), leg("2026-12-22", "B", "C")])
    assert len(rep.travel_days) == 2
    assert any("second travel day" in w for w in rep.warnings)


def test_night_train_on_last_valid_day_is_error(pd):
    _, rep = make(pd, [leg("2027-02-18", night=True)], start="2026-12-19")
    assert any("last day of validity" in e for e in rep.errors)


def test_too_many_days_is_error(pd):
    legs = [leg(f"2026-12-{d:02d}") for d in range(19, 30)]  # 11 days
    _, rep = make(pd, legs, days=10)
    assert any("11 travel days needed" in e for e in rep.errors)


def test_leg_outside_validity_is_error(pd):
    _, rep = make(pd, [leg("2026-12-18")], start="2026-12-19")
    assert any("outside validity" in e for e in rep.errors)


def test_own_ticket_uses_no_travel_day(pd):
    _, rep = make(pd, [leg("2026-12-24", own_ticket=True), leg("2026-12-25")])
    assert list(rep.travel_days) == [date(2026, 12, 25)]
    assert len(rep.own_ticket_legs) == 1


def test_home_country_max_two_days(pd):
    legs = [leg("2026-12-19", fc="NL", tc="BE"), leg("2026-12-20", fc="NL", tc="NL"),
            leg("2027-01-04", fc="BE", tc="NL")]
    _, rep = make(pd, legs)
    assert any("home country NL on 3 days" in e for e in rep.errors)


def test_home_country_out_and_in_ok(pd):
    legs = [leg("2026-12-19", fc="NL", tc="BE"), leg("2026-12-19", fc="BE", tc="FR"),
            leg("2027-01-04", fc="BE", tc="NL")]
    _, rep = make(pd, legs)
    assert not rep.errors


def test_night_train_home_warns_about_split(pd):
    _, rep = make(pd, [leg("2027-01-03", fc="IT", tc="NL", night=True)])
    assert any("night train home" in w for w in rep.warnings)


def test_short_day_hint(pd):
    _, rep = make(pd, [leg("2026-12-24", dep="11:00", arr="11:45")])
    assert any("only 45 min" in h for h in rep.hints)


def test_unbooked_reservation_warning(pd):
    _, rep = make(pd, [leg("2026-12-21", reservation="required")])
    assert any("reservation required" in w for w in rep.warnings)


def test_cli_exit_codes(pd, tmp_path, capsys):
    ok = tmp_path / "ok.json"
    ok.write_text(json.dumps({"pass": {"days": 10, "start": "2026-12-19", "home": "NL"},
                              "legs": [leg("2026-12-21")]}))
    assert pd.main([str(ok)]) == 0
    assert "1 of 10 travel days used" in capsys.readouterr().out
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps({"pass": {"days": 1, "start": "2026-12-19"},
                               "legs": [leg("2026-12-21"), leg("2026-12-22")]}))
    assert pd.main([str(bad)]) == 1
