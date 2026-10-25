# Timetable lookup: train type, times, running days

Checked 25 Oct 2026. Use this whenever a leg needs a train type, times or
running days. **Never fill these in from memory or from an older plan.** A leg
without a checked source is marked `unverified`.

## Which source for what

| Need | Source | Notes |
|---|---|---|
| Does the train need a reservation; is it in the pass network | Interrail timetable https://www.interrail.com/en/plan-your-trip/interrail-timetable, or the Rail Planner app | Filters "Pass network only", "No reservation needed", "Train type" (https://help.interrail.com/hc/en-001/articles/10850370568861-Timetable-Information-and-how-to-use). Not real-time, "not 100% accurate", gaps in Spain and Italy among others; Interrail says to check the operator for the latest times (timetable page). Data refresh: help article says 4 times a week, timetable page every four days. |
| Pass-holder seats left | Interrail reservation booking tool, logged in with the pass | Availability shows only during booking, not in the timetable (https://www.interrail.com/en/support/reservations/number-of-seats-left-in-a-train). |
| Authoritative times, train type and number, holiday running | The operator's own journey planner: renfe.com, sncf-connect.com, trenitalia.com, bahn.de / int.bahn.de, ns.nl / nsinternational.com, sbb.ch, europeansleeper.eu/timetable, nightjet.com | Always the final word for a leg run by that operator. |
| Times across borders when the operator planner fails | DB planner https://int.bahn.de/en | Official DB site; DB books other European operators through the normal connection search (https://int.bahn.de/en/offers/international-rail-companies) but publishes no statement of its timetable coverage. Use for times only, label "DB planner", confirm type and reservation rules elsewhere. |
| When the new timetable and its sales open | DB: change 13 Dec 2026, sales from 14 Oct (https://int.bahn.de/en/booking-information/new-timetable). SNCF sales calendar (https://www.sncf-connect.com/aide/l-ouverture-des-ventes). NS International sale status per country (https://www.nsinternational.com/en/schedule) | The European timetable changes mid-December; dates after it may not be searchable yet. |

## Procedure per leg

1. Search the leg in the Interrail timetable or Rail Planner for the real date.
   Note train type, number, whether a reservation is required and whether the
   train is in the pass network. If no train shows, the country may be a data
   gap, not a missing train: go on to step 2.
2. Search the same leg and date in the operator's journey planner. Take
   departure, arrival, train type and number from there. If the two sources
   disagree, the operator wins; note the difference.
3. Check running days: search the day before and after, and a weekend day if
   the trip spans one. Record "daily" only if you saw it.
4. Check the operator against `reservations-by-country.md` (pass valid?
   reservation fee, quota). Low-cost brands on the same line are not covered.
5. Record the source URL (or "Rail Planner app") and the check date.

## When a page cannot be fetched or is not published yet

Some operator pages refuse automated fetches (on 25 Oct 2026 several sncf-connect
timetable pages, sbb.ch and eurostar.com returned 403). In order:

1. Try another page type from the same operator: the journey planner instead of
   a route page, the English or local-language version, the operator's press
   room for new timetables and holiday operations. Renfe route pages
   (renfe.com/es/es/inspirate/rutas/...) give only the first departure, not a
   timetable (https://www.renfe.com/es/es/inspirate/rutas/cordoba-granada).
2. If the operator documents a journey-planner URL with parameters, use it;
   do not guess parameters.
3. Use a browser if the environment has one; journey planners need JavaScript.
4. If the date is beyond the published timetable, search a sample date in the
   same timetable period (same weekday, after the mid-December change if the
   trip is) and write "sample date dd mmm, re-check when published".
5. Otherwise ask the traveller to look the leg up in the Rail Planner app or
   the operator site and paste the result, and mark the leg `unverified` with
   what is missing. Do not invent a plausible train.

## Holiday dates (24, 25, 31 Dec and 1 Jan)

- Holiday running is not announced far ahead (see `practical.md`). Search the
  exact date in the operator planner, plus an ordinary weekday the same week,
  and compare: fewer trains, earlier last departures and no night trains are
  common.
- If the exact date is not yet searchable, write "holiday running not yet
  published" and set a re-check date; do not copy the weekday pattern.
- Look for the operator's Christmas press release: Renfe and SNCF announce
  holiday sales and extra trains in their press rooms (e.g.
  https://www.renfe.com/es/es/grupo-renfe/comunicacion/renfe-al-dia/sala-de-prensa/renfe-abre-venta-billetes-para-viajar-ave-francia-navidad,
  https://www.sncf-voyageurs.com/fr/presse/tgv-inoui-ouigo-et-intercites-ouvrent-leurs-ventes-pour-les-conges-de-fin-dannee-avec-de-nouvelles-destinations-et-des-offres-renforcees/).
  Check the year in the release.
- Night trains: check the operator's own timetable for each date
  (https://www.europeansleeper.eu/timetable, `night-trains.md`).

## Record in the plan

| Date | Leg | Train (type + no.) | Dep - Arr | Runs | Reservation | Pass valid | Source, checked | Status |
|---|---|---|---|---|---|---|---|---|
| 22 Dec | A - B | TGV INOUI nnnn | hh:mm - hh:mm | daily (seen Mon-Sun) | mandatory, quota | yes | operator planner URL, 25 Oct | verified |
| 24 Dec | C - D | ? | ? | ? | ? | ? | not yet published | unverified, re-check dd mmm |

Status values: `verified` (operator source, real date), `sample date`,
`DB planner only`, `unverified`.
