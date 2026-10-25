#!/usr/bin/env python3
"""Count Interrail Global Pass (Flexi) travel days for a planned itinerary.

Rules implemented (Interrail Pass Conditions of Use v19, in force 10 Sep 2026;
see references/pass-rules.md for sources):

- A travel day is one calendar day, 00:00-23:59 local time. Every day on which a
  pass-covered leg departs uses a travel day.
- A direct night train uses only its departure day. Changing to another
  pass-covered train after midnight uses a second travel day; that follows
  naturally because the next leg departs on the next calendar day.
  There is no 19:00 departure condition.
- A night train cannot depart on the last day of validity (arrival must be
  within validity).
- In the country of residence the pass covers one outbound and one inbound
  journey (several trains allowed, all on the same travel day). They use normal
  travel days. Transit through the home country counts as one of them.
- Legs marked own_ticket are paid separately and use no travel day.

Input: a JSON file, or YAML if PyYAML is installed. Example (YAML):

    pass:
      days: 10
      start: 2026-12-19
      months: 2            # or end: 2027-02-18
      home: NL
    legs:
      - {date: 2026-12-19, dep: "20:15", from: Breda, from_country: NL,
         to: Milano, to_country: IT, night: true, reservation: required}
      - {date: 2026-12-24, dep: "11:00", arr: "11:45", from: Cordoba,
         from_country: ES, to: Sevilla, to_country: ES}

Output: a Markdown table per travel day plus errors and warnings.
Exit code 1 if there are errors (too many days, outside validity, ...).
Standard library only (PyYAML optional).
"""

from __future__ import annotations

import argparse
import calendar
import json
import sys
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from pathlib import Path

SHORT_DAY_MINUTES = 90  # a travel day with less pass travel than this is flagged


@dataclass
class Leg:
    day: date
    origin: str
    dest: str
    origin_country: str = ""
    dest_country: str = ""
    dep: str = ""
    arr: str = ""
    night: bool = False
    own_ticket: bool = False
    reservation: str = ""  # "", "required", "booked", "none"

    @property
    def minutes(self) -> int | None:
        if not self.dep or not self.arr:
            return None
        d = datetime.strptime(self.dep, "%H:%M")
        a = datetime.strptime(self.arr, "%H:%M")
        diff = (a - d).total_seconds() / 60
        if diff < 0:  # arrives after midnight
            diff += 24 * 60
        return int(diff)

    def label(self) -> str:
        t = f" {self.dep}" if self.dep else ""
        n = " (night)" if self.night else ""
        return f"{self.origin} -> {self.dest}{t}{n}"


@dataclass
class PassInfo:
    days: int
    start: date
    end: date
    home: str = ""


@dataclass
class Report:
    travel_days: dict[date, list[Leg]] = field(default_factory=dict)
    own_ticket_legs: list[Leg] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    hints: list[str] = field(default_factory=list)


def _as_date(value) -> date:
    if isinstance(value, date):
        return value
    return date.fromisoformat(str(value))


def add_months(d: date, months: int) -> date:
    month = d.month - 1 + months
    year = d.year + month // 12
    month = month % 12 + 1
    day = min(d.day, calendar.monthrange(year, month)[1])
    return date(year, month, day)


def parse_pass(raw: dict) -> PassInfo:
    start = _as_date(raw["start"])
    if "end" in raw:
        end = _as_date(raw["end"])
    else:
        # Interrail's example: 1 month from 10 Jan is valid up to and including 9 Feb.
        end = add_months(start, int(raw.get("months", 2))) - timedelta(days=1)
    return PassInfo(days=int(raw["days"]), start=start, end=end,
                    home=str(raw.get("home", "")).upper())


def parse_leg(raw: dict) -> Leg:
    return Leg(
        day=_as_date(raw["date"]),
        origin=str(raw.get("from", "?")),
        dest=str(raw.get("to", "?")),
        origin_country=str(raw.get("from_country", "")).upper(),
        dest_country=str(raw.get("to_country", "")).upper(),
        dep=str(raw.get("dep", "")),
        arr=str(raw.get("arr", "")),
        night=bool(raw.get("night", False)),
        own_ticket=bool(raw.get("own_ticket", False)),
        reservation=str(raw.get("reservation", "")).lower(),
    )


def evaluate(pass_info: PassInfo, legs: list[Leg]) -> Report:
    rep = Report()
    for leg in sorted(legs, key=lambda l: (l.day, l.dep)):
        if leg.own_ticket:
            rep.own_ticket_legs.append(leg)
            continue
        rep.travel_days.setdefault(leg.day, []).append(leg)

    used = len(rep.travel_days)
    if used > pass_info.days:
        rep.errors.append(
            f"{used} travel days needed, the pass has {pass_info.days}. "
            "Buy short legs separately (own_ticket) or merge travel days.")

    for day, day_legs in rep.travel_days.items():
        if day < pass_info.start or day > pass_info.end:
            rep.errors.append(
                f"{day}: outside validity {pass_info.start} - {pass_info.end}.")
        for leg in day_legs:
            if leg.night and day == pass_info.end:
                rep.errors.append(
                    f"{day}: night train {leg.label()} departs on the last day of "
                    "validity; not allowed (arrival must be within validity).")
            if leg.reservation == "required":
                rep.warnings.append(f"{day}: reservation required, not booked yet: {leg.label()}.")

    # Night train followed by a pass leg after midnight = extra travel day.
    for day, day_legs in rep.travel_days.items():
        if any(l.night for l in day_legs):
            nxt = day + timedelta(days=1)
            if nxt in rep.travel_days:
                rep.warnings.append(
                    f"{nxt}: a pass leg after the night train of {day} uses a second travel day. "
                    "Consider an own ticket for that leg or a direct connection.")

    # Home country: at most one outbound and one inbound day.
    if pass_info.home:
        home_days = sorted(
            day for day, day_legs in rep.travel_days.items()
            if any(pass_info.home in (l.origin_country, l.dest_country) for l in day_legs))
        if len(home_days) > 2:
            rep.errors.append(
                f"Pass legs in home country {pass_info.home} on {len(home_days)} days "
                f"({', '.join(map(str, home_days))}); only one outbound and one inbound journey are covered.")
        for day, day_legs in rep.travel_days.items():
            for leg in day_legs:
                if leg.night and leg.dest_country == pass_info.home and leg.origin_country != pass_info.home:
                    rep.warnings.append(
                        f"{day}: night train home ({leg.label()}). Interrail counts the inbound journey on "
                        "the arrival day: add it as two legs (to the last border station on day 1, border "
                        "to destination on day 2), which uses two travel days.")
        for leg in rep.own_ticket_legs:
            if pass_info.home in (leg.origin_country, leg.dest_country):
                rep.hints.append(
                    f"{leg.day}: home-country leg on own ticket ({leg.label()}). The outbound/inbound "
                    "journeys are optional, so this one stays unused (no explicit official statement); "
                    "it does not save a travel day if you continue on the pass that same day.")

    for day, day_legs in rep.travel_days.items():
        mins = [l.minutes for l in day_legs]
        if all(m is not None for m in mins) and sum(mins) < SHORT_DAY_MINUTES:
            rep.hints.append(
                f"{day}: only {sum(mins)} min of pass travel. Compare the price of a separate ticket "
                "(own_ticket) with the value of a travel day.")

    remaining = pass_info.days - used
    if 0 <= remaining and used:
        rep.hints.insert(0, f"{used} of {pass_info.days} travel days used, {remaining} left.")
    return rep


def render(pass_info: PassInfo, rep: Report) -> str:
    out = [f"Pass: {pass_info.days} travel days, valid {pass_info.start} - {pass_info.end}"
           + (f", home country {pass_info.home}" if pass_info.home else ""), ""]
    out += ["| # | Date | Legs on pass |", "|---|---|---|"]
    for i, (day, day_legs) in enumerate(sorted(rep.travel_days.items()), 1):
        out.append(f"| {i} | {day:%a %d %b %Y} | {'; '.join(l.label() for l in day_legs)} |")
    if rep.own_ticket_legs:
        out += ["", "Own tickets (no travel day): "
                + "; ".join(f"{l.day} {l.label()}" for l in rep.own_ticket_legs)]
    for title, items in (("Errors", rep.errors), ("Warnings", rep.warnings), ("Notes", rep.hints)):
        if items:
            out += ["", f"{title}:"] + [f"- {x}" for x in items]
    return "\n".join(out)


def load(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    if path.suffix.lower() in (".yaml", ".yml"):
        try:
            import yaml  # type: ignore
        except ImportError:
            sys.exit("PyYAML is not installed; use a .json file or pip install pyyaml")
        return yaml.safe_load(text)
    return json.loads(text)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("itinerary", type=Path, help="JSON or YAML file with 'pass' and 'legs'")
    args = ap.parse_args(argv)
    data = load(args.itinerary)
    pass_info = parse_pass(data["pass"])
    legs = [parse_leg(l) for l in data.get("legs", [])]
    rep = evaluate(pass_info, legs)
    print(render(pass_info, rep))
    return 1 if rep.errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
