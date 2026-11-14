# The poorhouse (2026-11-14)

Anthony asked for this after the SAELIG research ("5 - Saelig players vs code - newcomers and
jobs.md" in SAELIG RESEARCH). SAELIG does not give a newcomer a job either. Its towns hold
together because someone with no job costs almost nothing to keep and never leaves: a free
bunkhouse, food that grows wild, a big purse. Here, someone with no job paid rent, bread and
firewood every day and left town broke: in the long runs before this change, 2,618 people in 16
towns left with no money for bread, against 3,467 newcomers. The code is in
`scripts/village/poorhouse.gd`.

## The mechanic

The town's shelter is now a poorhouse, kept by the town's purse. The purse is the town's taxes:
rent and sales of town houses, shop fees and upkeep, and the coins of people who left or died.
Until now it only took coins in and never paid anything out.

- **Who goes in.** Someone with no shop and no work who would otherwise leave town broke: no
  bread in the house and not the price of a loaf left (or four days behind on rent). They give
  up the house they rented and move into the poorhouse instead, as long as the town's purse can
  pay for a day's bread and firewood. If it can't, they leave, as before. Someone who owns the
  house they live in pays no rent there, so they stay in it and are kept the same way.
- **Living there.** No rent. Each day the town buys a resident with no work what they can't buy
  themselves: a loaf when there is none in the house, a log when the hearth is empty. It pays
  the market price, to the baker or woodworker whose stall it buys from, like any other buyer.
  A resident who has coins buys their own. A resident the town can no longer pay for leaves, and
  so does one the town could not get a loaf for because the shelf was empty, as anyone with no
  bread and no coins would.
- **Places.** The poorhouse keeps at most 6 people (dev mode: `poorhouse_places`). When every
  place is taken, the next person with nothing left leaves town, as before. SAELIG players count
  5 to 10 people without work in a town of 45.
- **Getting out.** Residents have no work, and employers, house builders and masters looking
  for a servant all take the poorest free person, so residents are first in line for any job.
  Someone with work takes the next empty house the usual way (rent or buy) and leaves the
  poorhouse. Someone with no work does not take a house, since they would only fall behind on
  the rent, so they don't hold one back from a newcomer either.
- **It brings nobody to town.** Newcomers still come only when a house stands empty, as in
  SAELIG ("People won't immigrate if the only home is a bunkhouse").

On the map the shelter is labelled Poorhouse. The HUD shows how many people the town keeps
there, after the town purse. The person inspector says when someone lives in the poorhouse.
Dev mode: the switch `poorhouse` (on). Off, people with nothing left leave town as before.

## Measured

16 towns, 1,500 days each (11 hours of play at normal speed), the same eight seed pairs as the
runs on main before it (909ecb5), no merchants, kept running after a town reached 50.

- The poorhouse works as a mechanic. It held about 5 people in a town at any time (at most 10;
  6 places, and owners kept in their own houses count too). 1,072 people were taken in and 772
  of them later found work and a house.
- Hiring rose: 3,601 hires before, 4,176 after. Residents are first in line.
- Leaving did not fall: 2,996 people left town before, 3,098 after (no money for bread: 2,618
  and 2,669). Once the places are full, the next person with nothing left leaves as before, and
  newcomers keep arriving for empty houses with no work waiting.
- People at the end: 535 before, 521 after. Newcomers 3,467 and 3,555.
- Starved: 2 before, 14 after. 10 of the 14 were in one town whose last farmer died on day
  1,086: the wheat ran out, the bread shelf stood empty for five days and people holding coins
  starved, among them a woodworker with 11,675. Runs are not repeatable day for day, so one town's
  famine cannot be pinned on the change, but the town kept buying bread for its residents there.
- Prices (median from day 200): bread 5.66 and 3.25 before (two sets), 5.72 and 5.77 after;
  firewood 1.36 and 0.58 before, 1.19 and 1.17 after. Cold home-days 3,580 before, 4,601 after.
- The town paid 308,000 coins in 16 towns, 91 to 94 in 100 of it on days bread cost more than
  10 coins, which is in the towns already short of food. Most purses ended lower than before;
  four of 16 ended under 700 coins.
- One run failed the books check by 16 coins on day 1,449, in the famine town with bread at 200
  coins (main had a 25-coin failure of the same check in an earlier run).

## What it does not change

- How newcomers arrive, what they bring (60 or 150 coins), and the house rules.
- Prices, wages, hiring, shops. The town buys at the market price like anyone.
- The town purse still takes in what it did. The poorhouse is the first thing it pays for.

## Choices that were Claude's

- The poorhouse catches people at the moment they would have left, not earlier, so it adds no
  new threshold.
- The town keeps them with one loaf and one log a day, only when they can't pay for it
  themselves.
- 6 places. A first try with no limit (eight towns, 1,500 days) let the poorhouse grow to 20 of
  35 people in one town: everyone who moved in freed a house, and the empty house brought in a
  newcomer with no job. The town paid 386,000 coins in eight towns and most purses ended near
  zero. 14 people starved, most of them residents kept on through days of an empty bread shelf
  who would earlier have left. The places and the empty-shelf rule above came out of that run.
- Someone who owns their house is kept in it rather than moved out.
- A day the town keeps someone fed resets their count of hungry days, as the old garden plot
  did, so a trip to market with no coins for a second loaf is not a reason to leave.
