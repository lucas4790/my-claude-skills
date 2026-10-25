#!/usr/bin/env python3
"""Count Interrail Global Pass (Flexi) travel days for a planned itinerary.

Rules implemented (Interrail Pass Conditions of Use v19, in force 10 Sep 2026;
see references/pass-rules.md for sources):

- A travel day is one calendar day, 00:00-23:59 local time. Every day on which a
  pass-covered leg departs uses a travel day.
- Time zones: local time applies (CoU 4.10.3). The script does no time-zone
  conversion; it assumes every date and dep/arr time is already the local time
  at that station.
- A direct night train uses only its departure day. Changing to another
  pass-covered train after midnight uses a second travel day; that follows
  naturally because the next leg departs on the next calendar day. A note is
  printed only when the next-day leg looks like an onward connection: it
  departs from the night train's destination station (same name, ignoring
  case) and, if its dep time is given, before 12:00.
  There is no 19:00 departure condition.
- A night train cannot depart on the last day of validity (arrival must be
  within validity).
- In the country of residence the pass covers one outbound and one inbound
  journey (several trains allowed, all on the same travel day). They use normal
  travel days. A day is outbound if a pass leg leaves the home country (or the
  day starts at home and ends abroad), inbound if one enters it. Transit
  through the home country (enter and leave the same day) counts as one of the
  two. Errors: a second outbound or inbound journey, more than two such
  journeys, or a pass leg inside the home country on any other day.
- Legs marked own_ticket are paid separately and use no travel day.
- Costs: reservation fees per leg ("fee", EUR per person) plus the Interrail
  booking fee of EUR 2 per person per reserved train when booking through
  interrail.com (channel "interrail", the default). With pass.pass_price the
  value of one travel day (price / days) is shown and compared with the
  ticket_price of own_ticket legs.
- Reservation tracker: for legs with reservation required or booked, the date
  sales open (leg "sales_open", or date minus "window_days") and a "book by"
  date: as soon as sales open (or today) for quota trains and peak dates
  (15 Dec - 7 Jan, 1 Jul - 31 Aug), otherwise 7 days before travel.

Input: a JSON file, or YAML if PyYAML is installed. Example (YAML):

    travellers: 2          # optional, default 1
    channel: interrail     # optional; booking fee 2.0 for interrail (default), else 0
    booking_fee: 2.0       # optional, overrides the channel rule (EUR per person per train)
    pass:
      days: 10
      start: 2026-12-19
      months: 2            # or end: 2027-02-18
      home: NL
      pass_price: 335      # optional, EUR per person
    legs:
      - {date: 2026-12-19, dep: "20:15", from: Breda, from_country: NL,
         to: Milano, to_country: IT, night: true, reservation: required,
         fee: 25, window_days: 60, quota: true}
      - {date: 2026-12-24, dep: "11:00", arr: "11:45", from: Cordoba,
         from_country: ES, to: Sevilla, to_country: ES,
         own_ticket: true, ticket_price: 12}

Leg fields: date, from, to, from_country, to_country, dep, arr (HH:MM local),
night, own_ticket, reservation (required/booked/none), fee, ticket_price,
window_days, sales_open (YYYY-MM-DD), quota.

Output: a Markdown table per travel day, errors, warnings and notes, a cost
section and a reservation tracker. Exit code 1 if there are errors (too many
days, outside validity, home-country misuse, ...).
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
INTERRAIL_BOOKING_FEE = 2.0  # EUR per person per reserved train on interrail.com
BOOK_AHEAD_DAYS = 7  # normal trains: book at least this long before travel


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
    fee: float = 0.0  # reservation fee, EUR per person
    ticket_price: float | None = None  # own_ticket price, EUR per person
    window_days: int | None = None  # booking window
    sales_open: date | None = None
    quota: bool = False

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

    @property
    def reserved(self) -> bool:
        return self.reservation in ("required", "booked")

    @property
    def sales_open_date(self) -> date | None:
        if self.sales_open is not None:
            return self.sales_open
        if self.window_days is not None:
            return self.day - timedelta(days=self.window_days)
        return None

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
    price: float | None = None  # pass_price, EUR per person


@dataclass
class Options:
    travellers: int = 1
    channel: str = "interrail"
    booking_fee: float = INTERRAIL_BOOKING_FEE


@dataclass
class TrackerRow:
    day: date
    leg: Leg
    sales_open: date | None
    book_by: date
    status: str


@dataclass
class Report:
    travel_days: dict[date, list[Leg]] = field(default_factory=dict)
    own_ticket_legs: list[Leg] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    hints: list[str] = field(default_factory=list)
    costs: list[str] = field(default_factory=list)
    tracker: list[TrackerRow] = field(default_factory=list)
    today: date | None = None


def _as_date(value) -> date:
    if isinstance(value, date):
        return value
    return date.fromisoformat(str(value))


def _opt_float(value) -> float | None:
    if value is None or value == "":
        return None
    return float(value)


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
                    home=str(raw.get("home", "")).upper(),
                    price=_opt_float(raw.get("pass_price")))


def parse_options(raw: dict) -> Options:
    channel = str(raw.get("channel", "") or "interrail").lower()
    if raw.get("booking_fee") not in (None, ""):
        fee = float(raw["booking_fee"])
    else:
        fee = INTERRAIL_BOOKING_FEE if channel == "interrail" else 0.0
    return Options(travellers=int(raw.get("travellers", 1) or 1), channel=channel,
                   booking_fee=fee)


def parse_leg(raw: dict) -> Leg:
    window = raw.get("window_days")
    sales_open = raw.get("sales_open")
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
        fee=_opt_float(raw.get("fee")) or 0.0,
        ticket_price=_opt_float(raw.get("ticket_price")),
        window_days=int(window) if window not in (None, "") else None,
        sales_open=_as_date(sales_open) if sales_open not in (None, "") else None,
        quota=bool(raw.get("quota", False)),
    )


def is_peak(d: date) -> bool:
    """15 Dec - 7 Jan and 1 Jul - 31 Aug: reservations sell out early."""
    md = (d.month, d.day)
    return md >= (12, 15) or md <= (1, 7) or (7, 1) <= md <= (8, 31)


def book_by(leg: Leg, today: date) -> date:
    opens = leg.sales_open_date
    if leg.quota or is_peak(leg.day):
        return max(opens, today) if opens else today
    by = leg.day - timedelta(days=BOOK_AHEAD_DAYS)
    return max(by, opens) if opens else by  # cannot book before sales open


def _eur(x: float) -> str:
    return f"EUR {x:.2f}"


def _home_journeys(home: str, day_legs: list[Leg]) -> tuple[bool, bool, bool, bool]:
    """Return (touches_home, leaves, enters, transit) for one travel day."""
    def abroad(c: str) -> bool:
        return bool(c) and c != home

    touches = any(home in (l.origin_country, l.dest_country) for l in day_legs)
    leaves = any(l.origin_country == home and abroad(l.dest_country) for l in day_legs)
    enters = any(abroad(l.origin_country) and l.dest_country == home for l in day_legs)
    first, last = day_legs[0], day_legs[-1]
    if first.origin_country == home and abroad(last.dest_country):
        leaves = True
    if abroad(first.origin_country) and last.dest_country == home:
        enters = True
    # Enter and leave on the same day, starting and ending abroad: transit, one journey.
    transit = leaves and enters and abroad(first.origin_country) and abroad(last.dest_country)
    return touches, leaves, enters, transit


def check_home(pass_info: PassInfo, rep: Report) -> None:
    home = pass_info.home
    outbound: list[date] = []
    inbound: list[date] = []
    transit: list[date] = []
    domestic: list[date] = []
    home_days: list[date] = []
    for day in sorted(rep.travel_days):
        touches, leaves, enters, is_transit = _home_journeys(home, rep.travel_days[day])
        if not touches:
            continue
        home_days.append(day)
        if is_transit:
            transit.append(day)
            continue
        if leaves:
            outbound.append(day)
        if enters:
            inbound.append(day)
        if not leaves and not enters:
            domestic.append(day)

    def ds(days: list[date]) -> str:
        return ", ".join(map(str, days))

    if len(home_days) > 2:
        kinds = []
        for day in home_days:
            k = ("transit" if day in transit else
                 "outbound + inbound" if day in outbound and day in inbound else
                 "outbound" if day in outbound else
                 "inbound" if day in inbound else "domestic only")
            kinds.append(f"{day} {k}")
        rep.errors.append(
            f"Pass legs in home country {home} on {len(home_days)} days ({', '.join(kinds)}); "
            "only one outbound and one inbound journey are covered, each on one travel day.")
    if len(outbound) > 1:
        rep.errors.append(
            f"{len(outbound)} outbound journeys from home country {home} ({ds(outbound)}); "
            "the pass covers only one.")
    if len(inbound) > 1:
        rep.errors.append(
            f"{len(inbound)} inbound journeys into home country {home} ({ds(inbound)}); "
            "the pass covers only one.")
    if len(outbound) <= 1 and len(inbound) <= 1 and len(outbound) + len(inbound) + len(transit) > 2:
        rep.errors.append(
            f"Transit through home country {home} on {ds(transit)} counts as the outbound or inbound "
            "journey, but both are already used "
            f"(outbound {ds(outbound) or '-'}, inbound {ds(inbound) or '-'}).")
    for day in domestic:
        legs = "; ".join(l.label() for l in rep.travel_days[day]
                         if l.origin_country == home and l.dest_country == home)
        rep.errors.append(
            f"{day}: pass leg inside home country {home} ({legs}) on a day that is neither the "
            "outbound nor the inbound journey; other domestic use is not covered. "
            "Buy it separately (own_ticket).")


def costs(pass_info: PassInfo, opts: Options, rep: Report, legs: list[Leg]) -> list[str]:
    reserved = [l for l in legs if not l.own_ticket and (l.reserved or l.fee)]
    priced_own = [l for l in legs if l.own_ticket and l.ticket_price is not None]
    if not reserved and pass_info.price is None and not priced_own:
        return []
    n = opts.travellers
    out = []
    fees = sum(l.fee for l in reserved)
    booking = opts.booking_fee * len(reserved)
    if reserved:
        out.append(f"Reservation fees: {_eur(fees)} per person, {_eur(fees * n)} for "
                   f"{n} traveller{'s' if n != 1 else ''}.")
        out.append(f"Booking fees ({opts.channel}, {_eur(opts.booking_fee)} per person per train, "
                   f"{len(reserved)} train{'s' if len(reserved) != 1 else ''}): "
                   f"{_eur(booking)} per person, {_eur(booking * n)} total.")
        out.append(f"Reservations total: {_eur(fees + booking)} per person, "
                   f"{_eur((fees + booking) * n)} total.")
    if pass_info.price is not None:
        per_day = pass_info.price / pass_info.days
        out.append(f"Pass value: {_eur(pass_info.price)} / {pass_info.days} days = "
                   f"{_eur(per_day)} per travel day per person.")
        for l in priced_own:
            if l.day in rep.travel_days:
                out.append(f"{l.day} own ticket {l.label()} at {_eur(l.ticket_price)}: saves no "
                           "travel day (the pass is used that day anyway).")
            else:
                saved = per_day - l.ticket_price
                verdict = "worth it" if saved >= 0 else "the travel day is cheaper"
                out.append(f"{l.day} own ticket {l.label()} at {_eur(l.ticket_price)} vs "
                           f"{_eur(per_day)} travel day: saves {_eur(saved)} per person ({verdict}).")
    elif priced_own:
        total = sum(l.ticket_price for l in priced_own)
        out.append(f"Own tickets: {_eur(total)} per person, {_eur(total * n)} total.")
    return out


def tracker(legs: list[Leg], today: date) -> list[TrackerRow]:
    rows = []
    for l in legs:
        if not l.reserved:
            continue
        by = book_by(l, today)
        status = l.reservation
        if status == "required" and by < today:
            status = "required, overdue"
        rows.append(TrackerRow(day=l.day, leg=l, sales_open=l.sales_open_date, book_by=by,
                               status=status))
    return sorted(rows, key=lambda r: (r.book_by, r.day, r.leg.dep))


def evaluate(pass_info: PassInfo, legs: list[Leg], options: Options | None = None,
             today: date | None = None) -> Report:
    opts = options or Options()
    rep = Report(today=today or date.today())
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

    # Night train followed next morning by a leg from its destination: a likely onward
    # connection, which uses the next calendar day as a travel day (CoU 11.1.1).
    day_numbers = {d: i for i, d in enumerate(sorted(rep.travel_days), 1)}
    for day, day_legs in sorted(rep.travel_days.items()):
        nxt = day + timedelta(days=1)
        for night in (l for l in day_legs if l.night):
            onward = [l for l in rep.travel_days.get(nxt, [])
                      if l.origin.strip().casefold() == night.dest.strip().casefold()
                      and (not l.dep or l.dep < "12:00")]
            if onward:
                rep.hints.append(
                    f"{nxt}: continuing after the night train on {day} ({night.label()}) uses "
                    f"travel day {day_numbers[nxt]}; that is expected unless you meant one direct "
                    "night journey.")

    if pass_info.home:
        check_home(pass_info, rep)
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

    rep.costs = costs(pass_info, opts, rep, legs)
    rep.tracker = tracker(legs, rep.today)
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
    for title, items in (("Errors", rep.errors), ("Warnings", rep.warnings), ("Notes", rep.hints),
                         ("Costs", rep.costs)):
        if items:
            out += ["", f"{title}:"] + [f"- {x}" for x in items]
    if rep.tracker:
        today = rep.today or date.today()
        out += ["", f"Reservation tracker (today {today}):", "",
                "| Date | Leg | Fee | Sales open | Book by | Status |", "|---|---|---|---|---|---|"]
        for r in rep.tracker:
            fee = _eur(r.leg.fee) if r.leg.fee else "-"
            if r.sales_open is None:
                opens = "?"
            elif r.sales_open <= today:
                opens = "open"
            else:
                opens = str(r.sales_open)
            out.append(f"| {r.day} | {r.leg.label()} | {fee} | {opens} | {r.book_by} | {r.status} |")
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
    ap = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        epilog="Checks travel days, validity, night trains and the home-country rule, "
               "prints reservation and booking costs and a reservation tracker. "
               "Dates and times are local; see the module docstring for the file format.")
    ap.add_argument("itinerary", type=Path,
                    help="JSON or YAML file with 'pass', 'legs' and optional 'travellers', "
                         "'channel', 'booking_fee'")
    ap.add_argument("--today", type=date.fromisoformat, default=None, metavar="YYYY-MM-DD",
                    help="reference date for the reservation tracker (default: today)")
    args = ap.parse_args(argv)
    data = load(args.itinerary)
    pass_info = parse_pass(data["pass"])
    legs = [parse_leg(l) for l in data.get("legs", [])]
    rep = evaluate(pass_info, legs, parse_options(data), today=args.today)
    print(render(pass_info, rep))
    return 1 if rep.errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
