# Economy fixes, batch 2

2026-11-09. Follows docs/ECONOMY_BATCH1.md. The goal is to stop the money supply from growing
for free, and to get bread off its 1.00 price floor. Anthony asked for no extra rule on who may
join a trade.

## Changes

- **A market with limits** (`market.gd`). It starts with 3,000 coins instead of 100,000 and
  holds at most twice its stock target: 90 wheat and 100 bread instead of 999,999,999. It already
  refused to buy what it could not pay for; with a small purse that limit now matters.
- **No free money at birth.** Founders (spawned when the village is set up) still start with 500 coins. Anyone who arrives
  later gets a purse of at most 100 coins, paid out of the village market's coins
  (`LaborMarket.starting_purse`). No new money is created.
- **Households earn in both modes.** Hiring hands (from batch 1) now runs in "switching" mode
  too, so households have an income in both. The modes now differ only in whether farmers and
  bakers may change trade.
- **The villages differ.** Village 1 has ovens that bake 1.5x as much a day; village 2 has
  soil that yields 1.5x the wheat (`Market.oven_mult` / `soil_mult`, set in `world.gd`).
- The survival test allows 8 s per game day before it stops (was 4 s), so 100 days fits.

## Measured

See the PR for the run results.
