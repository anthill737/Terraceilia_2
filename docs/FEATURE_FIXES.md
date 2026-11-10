# Making the features actually work (2026-11-10)

A 60-day run with every village's event log saved (`TestSurvival --events=`) showed which
parts of the game never happened. This pass fixes them, and adds tests that fail when a
feature stops happening.

## What was broken, and what changed

- **Economy test was hollow.** It stepped the clock by hand, giving people about a quarter of a
  second of walking per game day, so nobody reached the market. Nothing traded, everyone
  starved, and it printed PASS. Rewritten to run the real game at 10x; it checks the books every
  frame and fails unless wheat, bread and firewood are actually bought and sold and wages paid
  (docs/TESTS.md).
- **House building was a number.** Work days just counted up, and a business owner "did the
  work" for free while running the business. Now each house has one worker for the whole job
  who walks to the site and spends the day there. A household with no employer builds its own
  house and is busy with it until done; anyone else hires the poorest person out of work and
  pays a day's wage per work day. A day with nobody free is a day with no progress. Who starts
  a house is decided first thing in the morning, before employers hire.
- **A household building its own house paid like a business owner.** It now pays the logs in
  coin and the 5 days in its own time, so it needs only the wood cost plus the 10-day cushion.
  Buying, or building with hired labour, still takes the whole value plus the cushion.
- **New businesses opened into a full market.** A household opened a second farm while the
  wheat store was full (89 of 90), never sold a sack, spent its savings on bread and starved.
  Now a farm, bakery or wood yard only opens when the market is short of that good (stock below
  its target).
- **A broke owner starved instead of closing.** Closing needed 8 "losing" days, but a business
  with no sales and no costs never has one. An owner who is broke and going hungry (3 days of
  hunger left) now closes shop and looks for work, unless they are the last of their trade.
- **Wheat had a fixed stock target of 45.** Like bread before, it now follows demand: 3 days of
  what bakers buy plus what they wanted when the store was empty, never above what the store
  can hold.
- **Trade timing was in the wrong units.** Written for 100 ticks a day; the game runs 10. A
  trader had to stay abroad 20 days (now 2) and re-checked every 3 days (now 3 times a day).
- **Wrong log text:** the baker's "eased production" line said wheat; it names the right good now.

## Still not happening in normal play

- **Trade between villages.** The test that forces a price gap passes, but in normal play
  nobody ever makes a trip. A baker needs a gap of 1.40 a loaf (about 35%) and 25 loaves on hand,
  and bakers sell every loaf at home as it comes out of the oven; wheat sits at the 1.00 floor in
  both towns. Loosening this means the town's only baker walks off with the bread for days,
  which starves home. The real fix is a decision: a merchant who carries goods, or a rule for
  when a producer may leave.
- **Poverty churn.** People out of work earn nothing, go broke and leave (about 25 per village
  over 120 days). Building jobs help a little.

## Measured results

Two 120-day runs (seeds 12345,66666 and 4242,777, hiring, trade on), plus the other tests:

- Survival: 27 of 28 checks pass. Villages grew 7 to 12, 9, 11 and 12. Nobody starved to death
  (the run before the business fixes had 4 deaths, all owners of new businesses that went broke).
  The one failure: a village lost 3 of 10 people in one day, three households out of work who had
  gone broke together.
- In those runs: builders hired workers 35 times, one household built its own house and moved in,
  3 households opened a business, 1 owner closed shop, 1 opening was refused because the market
  already had enough. Nobody bought a house (nobody homeless had the money). No trade trips.
- TestEconomy: pass. Village 1 in 30 days: farmers sold 514 wheat, bakers bought 503, bakers sold
  231 loaves, people bought 222, $414 paid in wages.
- TestFeatures: 11 of 11 pass.
- TestTradeMigration: all pass.
