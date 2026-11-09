# Economy fixes, batch 1, and hired hands

2026-11-09. From the Terraceilia 2 Council Report (7 Sep 2026) and a re-evaluation of this
branch's base (80dd117). Anthony asked for batch 1, plus a run comparing job switching with
"people hire help and wages paid".

## Batch 1 (both modes)

- **Breaking even is not a loss.** A producer's day counted as a strike when its wallet was
  `<=` yesterday's; now only when it is lower (`farmer_job.gd`, `baker_job.gd`). A working
  market drives profit towards zero, so the old rule deleted producers exactly when the market
  worked.
- **Leave only when broke.** Eight losing days alone no longer remove a producer; they must
  also be broke: under 8 days of upkeep or 3 loaves at today's bread price
  (`LaborMarket._is_broke`). A farmer sitting on 500 coins is not culled.
- **Never the last of a trade.** The last farmer or baker of a village is never removed and
  never switches away (`_live_count`).
- **Farmers and bakers can change trade** ("switching" mode only). On the 7-day evaluation the
  same gates as households apply (tenure, 200 savings, improvement margin, the 10% entry quota)
  plus a 21-day cooldown. The conversion now handles producers: they leave the old list, give up
  their fields (a new farmer takes over an unworked field before a new plot is made, so fields
  no longer pile up), and keep what they own instead of the new job's starting kit.
- **Job changes no longer reset hunger or connect a signal twice** (`hunger_need.gd`): the
  "day_changed is already connected" error is gone (30 in the baseline run, 0 in all four new
  runs), and a person changing job no longer gets a free full stomach.
- **A survival test that runs the real game** (`scenes/TestSurvival.tscn`): Main.tscn at 10x
  with 240 physics ticks a second so people walk and trade as in play (TestEconomy's
  fast-forward broke travel and passed while the town died). It fails if, after day 10, a
  village dies out, has no farmer or no baker for 5 days running, or has someone starving on
  more than 5% of days while its market had bread. Money is summed daily and reported.
  `--days=N --labor-mode=... --village-seeds=a,b --trade --result=file.json` (`--trade` turns
  inter-village trade on). The old career log test (TestCareer) was removed: it drove the
  single-village game, had not loaded since PR 7, and this test covers what it was for.
- `test_economy_invariants.gd`: the type-inference parse error under Godot 4.6.

## Hired hands with wages ("wages" mode)

`--labor-mode=wages` (or `"labor": {"mode": "wages"}` in the config). Farmers and bakers keep
their trade. Each day an employer:

- pays each hand 2 loaves' worth at today's bread price, wallet to wallet (no money made);
- lets a hand go if it cannot pay, or after 5 days of its cash falling;
- takes one on (up to 2) if it can keep 10 days of wages in hand and the hand's extra output
  is worth more than 1.1 wages: half of its own recent daily output (wheat for a farmer, bread
  less its wheat for a baker) at today's prices. The poorest unemployed household gets the job.

A hand adds half the employer's output: a farmer's harvest per field, a baker's oven time and
batch size (the same flour still makes the same bread). Households still become farmers or
bakers when a trade is short, as new people choosing a trade.

This follows how Saelig (Anthony's reference) works by its developer's account: NPCs work for
wages at businesses other NPCs own and quit when unpaid. The Doors of Trithius has fixed roles
and no NPC economy.

## Measured

Five runs, Godot 4.6.1 headless, below-normal priority, while another session was compiling an
engine (so the game ran about 6 s per game day and runs stopped at the in-test time limit,
day 78 to 99). Seeds a = 12345/66666, b = 4242/777. The two villages of a run come out almost
the same, so treat each run as one town.

Baseline (this branch's base, no fixes, seeds a, 85 days):
- both towns had **no farmer for 6 days** from day 16; 4 and 5 people deleted;
- 30 "already connected" errors.

Switching (batch 1), seeds a to day 78 and b to day 85: **8 of 8 checks pass** in both.
- Never without a farmer or baker (at least 3 farmers throughout), nobody starved, nobody left.
- Farmers and bakers changed trade 15 (a) and 23 (b) times; population 3 to 29 and 32.
- Bread fell from 2.8 to the 1.00 floor by day 80 (glut: up to 9 bakers for 30 people).
- Poorest person's cash 366 to 419 by day 80.

Wages, seeds a to day 90 and b to day 99: **8 of 8 checks pass** in both.
- Never without a farmer or baker, nobody starved, nobody left, no producer ever switched.
- 3 to 15 households employed as hands (of 8 to 21); population 3 to 33 and 36.
- Bread also at the 1.00 floor by day 60 to 80, so a day's wage fell to 2.00.
- Poorest person's cash 415 to 468 at day 80 to 99 (about 50 more than switching).

Both: total money grew from 101,500 to 114,000 to 118,000, all of it the 500 coins each new
person brings (batch 2: stop printing money, finite market). Neither run reached the ~250-day
point where savings were projected to run out, and with births still bringing money they would
not show it.

## Not done (batch 2 and 3)

Households' only income outside wages mode is still their 500-coin start; money is still made
at every birth; the market still holds 100,000 coins and buys any glut at the price floor, which
is why bread sits at 1.00 in both modes; overshoot between trades is only damped by the existing
quota; the villages are near clones, so trade has no reason to happen (trade was off here).
