# Economy fixes, batch 2

2026-11-09. Follows docs/ECONOMY_BATCH1.md. The goal is to get bread off its 1.00 price floor.

## Changes

- **Hiring is the default labor mode** (`LaborMarket.labor_mode = "wages"`). Anthony's call: the
  switching model is retired for normal use. Farmers and bakers keep their trade and hire up to
  2 hands; households still choose to become farmers or bakers when a trade pays. The old mode
  is still there behind `--labor-mode=switching` (or `"labor": {"mode": "switching"}`). Hiring
  also runs in switching mode now.
- **A market with limits** (`market.gd`). It starts with 3,000 coins instead of 100,000 and
  holds at most twice its stock target: 90 wheat and 100 bread instead of 999,999,999. It already
  refused to buy what it could not pay for; with a small purse that limit now matters.
- **The villages differ.** Village 1 has ovens that bake 1.5x as much a day; village 2 has
  soil that yields 1.5x the wheat (`Market.oven_mult` / `soil_mult`, set in `world.gd`).
- **Households leave after days without bread, not failed trips** (`household_job.gd`).
  The old rule moved a household away after 4 failed bread trips, counted per trip, so when a
  market ran dry every household in town left in the same moment (seen on day 35 of a test run:
  11 of 14 people gone at once). Several failed trips on one day now count as one day.
- **Survival test** fails when a village loses more than a quarter of its people (3 or more)
  in one day, by death or leaving. It allows 8 s per game day before it stops (was 4 s).

Unchanged on purpose: newcomers bring their own new money (500 coins), and people who leave town
take their coins with them.

Tried and dropped: paying newcomers' starting money out of the market (no new money at birth).
It kept the money supply flat but drained the markets and left everyone poor.

## Measured

Godot 4.6.1 headless, hiring mode, trade on, 80 days, seeds a = 12345/66666 and b = 4242/777.

- All 10 checks pass on both seed pairs, including the new one: nobody left town, nobody
  starved, every village always had a farmer and a baker. Towns grew from 3 to 30 people with
  9 to 13 hands employed; the poorest person ended with 402 to 465 coins.
- The trade migration test (6 scenarios) and the economy test (3 seeds) pass.
- **Bread still drifts to the 1.00 floor.** From day 40 it averaged 1.16 to 1.47 and sat at the
  floor on 1 to 17 of the last 40 days; by day 79 all four towns were at 1.00 to 1.02. The market
  limits do not stop it while new money keeps arriving: by day 79 up to 7 bakers serve 30 people.
- Nobody traded between villages, even though they now differ.
- An earlier try that paid newcomers out of the market kept bread at 1.9 to 3.6 because people
  were poor (median 55 to 85 coins), and is not kept.
