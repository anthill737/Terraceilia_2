# A town that works (2026-11-10)

How the village economy holds together after the 2026-11-10 pass. The full list of what was
broken and what is still open is in docs/AUDIT_2026-11-10.md. Measured results are in
docs/FEATURE_FIXES.md.

## The clock (`scripts/simulation_clock.gd`)

A tick is 2.67 game seconds, counted on the physics clock. Ten ticks make a day: about 27
seconds at 1x and about 3 seconds at 10x.

Before, ticks came from a wall-clock timer. At 10x on a busy machine each frame ran the most
physics it is allowed and gave one tick, so people got 2.67 game seconds of walking per tick, and
the whole economy was tuned and tested like that. At 1x to 3x, or recording in fixed steps, people
got 1 second per tick, could not finish their rounds, and the town starved. The same build grew to
9 people at 10x and died out at 3x. Now every speed behaves the same.

## People and work

- **Owners** (farmer, baker, woodworker, and since 2026-11-13 a smith and a tailor, docs/SMITH.md and docs/CLOTHES.md) run a business and may hire up to 2 hands, more once
  the shop is extended (six levels, docs/SHOP_LEVELS.md).
- **Hands** are households paid a daily wage, from the day they are hired. Each owner sets
  their own wage (docs/WAGES.md, 2026-11-13). A hand walks to the
  employer's field, bakery or yard and spends the day there.
- **Builders** are households doing the work on a house or an improvement: for themselves, or
  hired by the owner at the daily wage.
- **Servants** work in the house of someone who owns a proper house and can afford one.
- **Merchants** (one per village) carry goods between the two markets with their own coins.
- **Cottagers** are households with no work. Since 2026-11-13 they are handed nothing: they
  buy their bread and firewood at the market out of what they have saved, and pay rent like
  anyone else. Someone with no work, no bread in the house and not the price of a loaf left goes
  to look for work somewhere else. (Until then they kept a garden plot that handed them bread and
  firewood every day, whatever was in their purse; Anthony: a plot is a place to live, not food.
  The old plot is behind the dev switch "gardens", off.)

## Who comes to town

A newcomer arrives when the town is doing well and a house is empty. Who comes depends on the
town (docs/WHO_ARRIVES.md, 2026-11-13): when a job is waiting and nobody is free, someone comes
looking for work; otherwise the person who comes brings the coins to open a shop. (Until then
nobody came while more than one person lacked work, and towns stopped at about 25 people.)

A household opens a farm, bakery or wood yard only when it has the savings and the market has
been short of that good three days running.

## Where profit goes

- **Improving their home.** Someone who owns the house they live in and has money to spare
  improves it, level by level: cottage, house, fine house, hall, great hall, manor, and after
  that a manor keeps getting rooms. Each step takes 10 to 16 logs from the woodworker and 4 to 7
  days from a builder. (Victoria 3: owners put a share of profit into new building.)
- **Servants.** Once the home is more than a cottage, its owner keeps a servant when they have
  15 days of wages to spare beyond their reserve (two servants in a hall or bigger), and lets
  them go if they slip under the reserve.
- **Houses to rent out**, when the town is full.
- Renters with savings buy the town house they live in, or build their own.
- Money put into buildings is not counted as a loss when an employer decides whether to keep a hand.

Without the last two streams the towns sat at about 10 people with half of them on garden plots;
with them they reach 13 to 22.

## Output

A master alone makes: farmer about 10 wheat a day, baker 12 loaves, woodworker 12 logs. Each hired
hand adds less than the one before, and a full shop can be extended to hold more
(docs/SHOP_LEVELS.md, 2026-11-13): 18 and 23 loaves or logs with one and two hands. The baker made 15 alone before, which fed
the whole town with no help.

## Eating

One loaf a day. Someone still hungry after the day's meal eats a second loaf if they have one, so
a missed meal is made up (before, hunger could never recover, and over a few hundred days people
ratcheted down and died). Hunger at 0 with no bread is still death, for anyone, but someone
holding the price of a loaf while the market has bread buys one and eats it on the spot.

## Trade (`scripts/jobs/merchant_job.gd`)

Each market sets its own prices from its own stock. The merchant checks the home market twice a
day. A deal needs the other market to pay at least 10% (and 0.25 coins) more per unit than the
home price, and the whole load to earn 4 coins. They never strip a market (only stock above half
its target), carry up to 20 units, sell, and look for a load to bring home. Farmers and bakers
stay home. Press M for the merchants panel.

## Troubles (`scripts/village/shocks.gd`)

After day 20, now and then: blight (harvests 40% for 6 days), a bakery fire (oven 30% for 4 days),
a hard frost (hearths burn double for 5 days), rats in the market store (60% of wheat and bread
lost). Nothing repairs the damage; prices, hiring and the merchants do. The HUD shows the trouble.

An empty shelf counts as demand once per buyer per day, however often they come back (repeat
visits once drove the bread target to 158 loaves and the price kept climbing after supply was
back). An empty woodpile bids up 12% a day. People leave over a cold hearth only after 10 days.
