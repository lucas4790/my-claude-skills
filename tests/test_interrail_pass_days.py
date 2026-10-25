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


def test_change_after_midnight_uses_second_day_and_notes_it(pd):
    # Onward connection from the night train's destination (case-insensitive), before 12:00.
    _, rep = make(pd, [leg("2026-12-21", "A", "Milano", night=True),
                       leg("2026-12-22", "milano", "C", dep="08:30")])
    assert len(rep.travel_days) == 2
    msgs = [h for h in rep.hints if "continuing after the night train on 2026-12-21" in h]
    assert msgs and "uses travel day 2" in msgs[0]
    assert "expected unless you meant one direct night journey" in msgs[0]
    assert not any("night train" in w for w in rep.warnings)


@pytest.mark.parametrize("nxt", [
    {"frm": "Roma", "dep": "08:30"},     # different station: not a connection
    {"frm": "Milano", "dep": "15:00"},   # afternoon: intentional travel on
])
def test_night_train_followup_no_note_when_not_a_connection(pd, nxt):
    _, rep = make(pd, [leg("2026-12-21", "A", "Milano", night=True),
                       leg("2026-12-22", nxt["frm"], "C", dep=nxt["dep"])])
    assert len(rep.travel_days) == 2
    assert not any("continuing after the night train" in x for x in rep.hints + rep.warnings)


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


# --- Home country: outbound / inbound / transit ---------------------------------

def test_two_outbound_journeys_is_error(pd):
    legs = [leg("2026-12-19", fc="NL", tc="BE"), leg("2026-12-28", fc="NL", tc="DE")]
    _, rep = make(pd, legs)
    assert any("2 outbound journeys from home country NL" in e for e in rep.errors)


def test_two_inbound_journeys_is_error(pd):
    legs = [leg("2026-12-20", fc="BE", tc="NL"), leg("2027-01-04", fc="DE", tc="NL")]
    _, rep = make(pd, legs)
    assert any("2 inbound journeys into home country NL" in e for e in rep.errors)


def test_domestic_only_day_is_error(pd):
    legs = [leg("2026-12-19", fc="NL", tc="BE"), leg("2027-01-02", fc="NL", tc="NL")]
    _, rep = make(pd, legs)
    assert any("2027-01-02: pass leg inside home country NL" in e
               and "neither the outbound nor the inbound" in e for e in rep.errors)


def test_outbound_day_may_start_with_domestic_trains(pd):
    # First leg starts at home, last ends abroad: one outbound journey with several trains.
    legs = [leg("2026-12-19", "Utrecht", "Breda", fc="NL", tc="NL"),
            leg("2026-12-19", "Breda", "Antwerpen", fc="NL", tc="BE"),
            leg("2027-01-04", fc="BE", tc="NL")]
    _, rep = make(pd, legs)
    assert not rep.errors


def test_transit_counts_as_one_journey(pd):
    # BE -> NL -> DE on one day is transit = one journey; with one inbound that is fine.
    legs = [leg("2026-12-19", fc="BE", tc="NL"), leg("2026-12-19", fc="NL", tc="DE"),
            leg("2027-01-04", fc="DE", tc="NL")]
    _, rep = make(pd, legs)
    assert not rep.errors


def test_transit_plus_outbound_and_inbound_is_error(pd):
    legs = [leg("2026-12-19", fc="NL", tc="BE"),
            leg("2026-12-27", fc="BE", tc="NL"), leg("2026-12-27", fc="NL", tc="DE"),
            leg("2027-01-04", fc="DE", tc="NL")]
    _, rep = make(pd, legs)
    assert any("Transit through home country NL on 2026-12-27" in e for e in rep.errors)


# --- Costs -----------------------------------------------------------------------

def make_opts(pd, legs, top=None, pass_extra=None, today="2026-10-25"):
    p = pd.parse_pass({"days": 10, "start": "2026-12-19", "months": 2, "home": "NL",
                       **(pass_extra or {})})
    opts = pd.parse_options(top or {})
    return p, pd.evaluate(p, [pd.parse_leg(l) for l in legs], opts,
                          today=date.fromisoformat(today))


def test_cost_totals_with_travellers(pd):
    legs = [leg("2026-12-21", reservation="required", fee=25),
            leg("2026-12-23", reservation="booked", fee=10.5),
            leg("2026-12-24")]  # no reservation, no fee
    _, rep = make_opts(pd, legs, {"travellers": 2})
    text = "\n".join(rep.costs)
    assert "Reservation fees: EUR 35.50 per person, EUR 71.00 for 2 travellers" in text
    assert "EUR 4.00 per person, EUR 8.00 total" in text  # 2 trains x EUR 2
    assert "Reservations total: EUR 39.50 per person, EUR 79.00 total" in text


@pytest.mark.parametrize("top,expected", [
    ({}, 2.0),
    ({"channel": "interrail"}, 2.0),
    ({"channel": "sncf"}, 0.0),
    ({"channel": "sncf", "booking_fee": 1.5}, 1.5),
])
def test_booking_fee_channel_rule(pd, top, expected):
    assert pd.parse_options(top).booking_fee == expected


def test_booking_fee_zero_for_other_channel_in_costs(pd):
    _, rep = make_opts(pd, [leg("2026-12-21", reservation="required", fee=10)],
                       {"channel": "renfe"})
    assert any("Booking fees (renfe, EUR 0.00" in c for c in rep.costs)


def test_pass_value_per_day_and_own_ticket_saving(pd):
    legs = [leg("2026-12-21"),
            leg("2026-12-22", own_ticket=True, ticket_price=12),
            leg("2026-12-21", "B", "C", own_ticket=True, ticket_price=5)]
    _, rep = make_opts(pd, legs, pass_extra={"pass_price": 335})
    text = "\n".join(rep.costs)
    assert "EUR 335.00 / 10 days = EUR 33.50 per travel day" in text
    assert "saves EUR 21.50 per person (worth it)" in text
    assert "saves no travel day" in text  # same day as a pass leg


# --- Reservation tracker ---------------------------------------------------------

def test_sales_open_computed_from_window_days(pd):
    l = pd.parse_leg(leg("2027-02-10", window_days=60))
    assert l.sales_open_date == date(2026, 12, 12)
    l2 = pd.parse_leg(leg("2027-02-10", window_days=60, sales_open="2026-12-01"))
    assert l2.sales_open_date == date(2026, 12, 1)  # explicit date wins


def test_book_by_quota_and_peak_vs_normal(pd):
    today = date(2026, 10, 25)
    quota = pd.parse_leg(leg("2027-02-10", window_days=60, quota=True))
    peak = pd.parse_leg(leg("2026-12-24", window_days=30))
    peak_open = pd.parse_leg(leg("2026-12-24", window_days=90))
    normal = pd.parse_leg(leg("2027-02-10", window_days=60))
    assert pd.book_by(quota, today) == date(2026, 12, 12)       # as soon as sales open
    assert pd.book_by(peak, today) == date(2026, 11, 24)
    assert pd.book_by(peak_open, today) == today                # already open: now
    assert pd.book_by(normal, today) == date(2027, 2, 3)        # 7 days before
    assert pd.is_peak(date(2027, 1, 7)) and pd.is_peak(date(2027, 7, 1))
    assert not pd.is_peak(date(2027, 1, 8)) and not pd.is_peak(date(2027, 6, 30))


def test_tracker_only_reserved_legs_sorted_by_book_by(pd):
    legs = [leg("2027-02-10", "X", "Y", reservation="required", fee=8, window_days=60),
            leg("2026-12-24", "P", "Q", reservation="booked", fee=20, window_days=90),
            leg("2026-12-26", "R", "S", reservation="none"),
            leg("2026-12-27", "T", "U")]
    _, rep = make_opts(pd, legs)
    assert [r.leg.origin for r in rep.tracker] == ["P", "X"]
    assert [r.status for r in rep.tracker] == ["booked", "required"]


def test_cli_today_flag_and_tracker_table(pd, tmp_path, capsys):
    f = tmp_path / "trip.json"
    f.write_text(json.dumps({
        "travellers": 2,
        "pass": {"days": 10, "start": "2026-12-19", "home": "NL", "pass_price": 335},
        "legs": [leg("2026-12-21", "Paris", "Barcelona", dep="10:00", reservation="required",
                     fee=35, window_days=90, quota=True),
                 leg("2027-02-10", "Madrid", "Granada", reservation="required", fee=10,
                     sales_open="2026-12-12")]}))
    assert pd.main([str(f), "--today", "2026-11-01"]) == 0
    out = capsys.readouterr().out
    assert "Reservation tracker (today 2026-11-01):" in out
    assert "| Date | Leg | Fee | Sales open | Book by | Status |" in out
    assert "| 2026-12-21 | Paris -> Barcelona 10:00 | EUR 35.00 | open | 2026-11-01 | required |" in out
    assert "| 2027-02-10 | Madrid -> Granada | EUR 10.00 | 2026-12-12 | 2027-02-03 | required |" in out
    assert out.index("Paris -> Barcelona 10:00 |") < out.index("Madrid -> Granada |")
    assert "Costs:" in out and "EUR 33.50 per travel day" in out
    # Without --today the script uses today's date and still runs.
    assert pd.main([str(f)]) == 0
    assert "Reservation tracker (today " in capsys.readouterr().out
