---
name: interrail-planner
description: Use when planning a European rail trip with an Interrail Global or One Country Pass - counting travel days, deciding pass day versus separate ticket, night trains, the home-country rule, which trains need (quota-limited) seat reservations, booking deadlines and a trip document. Triggers on "interrail", "rail pass", "pass days", "seat reservation with a pass", "night train to ...". Not for single point-to-point train tickets without a pass, flights, or general trip ideas without rail (use a general travel planner for those).
---

# Interrail planner

Plan a rail-pass trip end to end: route, travel-day count, reservations with
deadlines, and one trip document the traveller can act on. The references hold
rules and fees researched on the official Interrail and operator sites; every
fact there carries its source URL and check date.

## Ground rules

1. **Official sources only.** Pass rules come from interrail.com (interrail.eu
   redirects there), its help centre and the Conditions of Use; train facts
   from the operators (NS, SNCB, SNCF, Renfe, DB, SBB, Trenitalia, Eurostar,
   European Sleeper, OBB). No forums or blogs as evidence.
2. **Re-check what moves.** Fees, timetables, sales openings and which night
   trains run change often. Before giving a number, check the reference's date;
   if it is older than about three months or the trip is in a new timetable
   year (mid-December change), look it up again on the official page.
3. **Say when something is unconfirmed.** The references list open questions
   and places where official pages contradict each other. Pass those on as
   such; never resolve them by guessing. Quota sizes are never published.
4. **Never book or pay.** Surface the action, the channel and the deadline; the
   traveller books.
5. **Count with the script, not in your head.** Travel-day arithmetic around
   night trains, the home country and validity edges is where plans go wrong.

## Workflow

### 1. Discovery (one batch, skip what is known)

Ask only what is missing:

- Pass: Global or One Country, class, number of travel days, validity window,
  mobile or paper, country of residence, activated or not, start date set?
- Dates: fixed anchors (holidays, visits, events) versus flexible days.
- Who travels, pace (things per day), interests, budget for nights.
- Places that must be in, places to skip, people to stay with.
- Night trains welcome? Comfort level (seat, couchette, sleeper).
- What is already booked.

If a separate preference profile or trip document exists, read it first.

### 2. Route skeleton

- Put the fixed anchors on a calendar first, then fit the route around them.
- For each leg, look up the train type and check it against
  `references/reservations-by-country.md`: is the pass valid on it, is a
  reservation mandatory, what does it cost, is it quota-limited?
- Look trains up as in `references/timetable-lookup.md`: Interrail timetable
  for reservation and pass coverage, the operator's journey planner for times,
  type and running days, on the real travel date.
- Never fill in a train type, number or time from memory. If no official page
  can be read, ask the traveller to check in the Rail Planner app and mark the
  leg "unverified" in the plan.
- Check 24/25/31 Dec and 1 Jan legs on their own date; holiday running differs.
- Prefer routes where the pass is valid and reservations are cheap or not
  needed. Flag trains where the pass is not valid (for example Avlo, OUIGO
  España, Italo, Flixtrain) and offer an alternative.
- For overnight legs use `references/night-trains.md`; check that the train
  actually runs on that date and in that season.
- Give two or three positioned route options when there is a real choice, with
  the trade-off stated (time, travel days, cost, comfort).

### 3. Count travel days

Write the legs to an itinerary file and run the counter:

```bash
python3 scripts/pass_days.py itinerary.json
```

Itinerary format (JSON; YAML works if PyYAML is installed). Everything except
`pass.days`, `pass.start` and each leg's `date`, `from` and `to` is optional:

```yaml
travellers: 2
channel: interrail
pass:
  days: 10
  start: "2026-12-19"
  months: 2
  home: NL
  pass_price: 700
legs:
  - date: "2026-12-19"
    dep: "20:15"
    from: Breda
    from_country: NL
    to: Milano
    to_country: IT
    night: true
    reservation: required
    fee: 74
    quota: true
  - date: "2026-12-24"
    dep: "11:00"
    arr: "11:45"
    from: Cordoba
    from_country: ES
    to: Sevilla
    to_country: ES
    own_ticket: true
    ticket_price: 12
```

Per leg, `window_days` (booking window) or `sales_open` (date) feeds the
reservation tracker; `--today YYYY-MM-DD` sets the reference date.

The script prints one row per travel day and lists errors (too many days,
outside validity, night train on the last day, more than one outbound or
inbound home-country journey, a domestic pass leg at home), warnings (unbooked
mandatory reservations, night train home), notes (onward connection after a
night train, short travel days), a cost section (reservation and booking fees
for all travellers, value per travel day versus own tickets) and a reservation
tracker with sales-open and book-by dates. Rules and their sources:
`references/pass-rules.md`.

### 4. Pass day or separate ticket

For every travel day the script flags as short, and whenever the count is
tight, compare: the price of a separate ticket (look it up) against the value
of the travel day (pass price divided by travel days) plus the reservation fee
it would need anyway. Recommend one, with the numbers. Put `pass_price` and
each candidate's `ticket_price` in the itinerary and the script does the
comparison.

### 5. Reservation tracker

Start from the script's tracker (give each reserved leg its `fee`, `quota` and
`window_days` or `sales_open` from the references) and add train, channel and
class. One row per reservation, sorted by the date it must be booked:

| Leg | Train | Mandatory | Fee (class) | Quota | Sales open | Book by | Channel | Status |
|---|---|---|---|---|---|---|---|---|

- **Sales open**: travel date minus the booking window for that operator
  (reference), or the operator's published sales calendar if there is one.
- **Book by**: for quota-limited trains and holiday periods, the day sales open
  (or now, if already open); otherwise a week before travel at the latest.
- **Channel**: where pass-holder fares can actually be bought (Interrail
  website, operator phone line, station desk). Reservations cannot be booked
  in the Rail Planner app.
- Status codes: not booked, booked (with reference), sold out (fallback booked),
  watch (opens on date).

### 6. Trip document

Build the document from `references/trip-doc-template.md`: overview, day-by-day
plan with travel days marked, reservation tracker, pass and app checklist
(`references/practical.md`), open questions. Write it where the traveller keeps
trip material (their document tool or a file).

### 7. Check before handing over

- Re-run the counter on the final itinerary.
- Spot-check every fee and opening date older than three months on the
  official page.
- List what is still unconfirmed and who can answer it (Interrail customer
  service, operator).

## Push back on these

| Traveller says | Better alternative |
|---|---|
| "We'll book seats when we get there" | High-speed and night trains need reservations and pass-holder seats are limited; around holidays they go first. Book the mandatory ones now. |
| "The night train leaves after 7pm so it's one day" | There is no 19:00 rule. One travel day only if it is a direct night train and you do not change after midnight; never on the last valid day. |
| "We'll use the pass for the short hop too" | A 40-minute regional trip can burn a whole travel day. Price a separate ticket. |
| "I'll screenshot the ticket" | Screenshots are not accepted. Add each leg in the app before boarding and open the app online once every 24 hours. |
| "We'll just take the cheap Avlo/OUIGO" | The pass is not valid on several low-cost operators. Check the operator first. |
| "We'll go home and back on the pass" | The pass covers only one outbound and one inbound journey in the home country. |

## References

- `references/pass-rules.md` - travel days, night-train rule, home country,
  activation, mobile pass, classes, refunds, delays
- `references/reservations-by-country.md` - mandatory reservations, fees,
  quotas, booking windows and channels for NL, BE, FR, ES, DE, CH, IT, Eurostar
- `references/night-trains.md` - night trains from the Benelux and in France,
  fares for pass holders, booking
- `references/timetable-lookup.md` - which timetable to trust, lookup steps
  per leg, blocked or unpublished timetables, holiday dates, recording
- `references/italy.md` - Italy and the Riviera crossing: train types,
  reservations, fees
- `references/practical.md` - Rail Planner app, ticket checks, delays and
  missed connections, sold-out alternatives, luggage
- `references/trip-doc-template.md` - structure of the trip document
- `references/sources.md` - every official source used, with check date
