# interrail-planner

Repo-owned skill for planning European rail trips with an Interrail pass.

- `skills/interrail-planner/SKILL.md`: workflow (discovery, route, travel-day
  count, pass day vs separate ticket, reservation tracker, trip document).
- `skills/interrail-planner/scripts/pass_days.py`: counts travel days (night
  trains, home-country rule, validity edges); standard library only, tests in
  `tests/test_interrail_pass_days.py`.
- `skills/interrail-planner/references/`: pass rules, reservations per country,
  night trains and practical rules, researched on official Interrail and
  operator sites only (checked 25 Oct 2026; `sources.md` lists every page).

Refresh the references when a new Conditions of Use version or timetable year
(mid-December) comes out; fees and night-train days change most often.

The reservation tracker with computed "book by" dates and the push-back table
were inspired by the workflow of
[apljacob/travel-agent](https://github.com/apljacob/travel-agent)
(CC BY-NC 4.0); no text from it is included.
