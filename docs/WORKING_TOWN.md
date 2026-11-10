# A town that works (2026-11-10)

How the village economy holds together after the 2026-11-10 pass. The full list of what was
broken and what is still open is in docs/AUDIT_2026-11-10.md.

## The clock (`scripts/simulation_clock.gd`)

A tick is 2.67 game seconds, counted on the physics clock. Ten ticks make a day: about 27
seconds at 1x and about 3 seconds at 10x.

Before, ticks came from a wall-clock timer. At 10x on a busy machine each frame ran the most
physics it is allowed and gave one tick, so people got 2.67 game seconds of walking per tick, and
the whole economy was tuned and tested like that. At 1x to 3x, or recording in fixed steps, people
got 1 second per tick, could not finish their rounds, and the town starved. The same build grew to
9 people at 10x and died out at 3x. Now every speed behaves the same.

## People and work

- **Owners** (farmer, baker, woodworker) run a business and may hire up to 2 hands.
- **Hands** are households paid a daily wage. A hand walks to the employer's field, bakery or
  yard and spends the day there.
- **Builders** are households doing the work on a house or an improvement: for themselves, or
  hired by the owner at the daily wage.
- **Merchants** (one per village) carry goods between the two markets with their own coins.
- **Cottagers** are households with no work. They do not sit and go broke. Like medieval
  cottagers they keep a garden plot (enough to eat) and gather deadwood for their own hearth.
  They buy and sell nothing, and no rent is asked while they have no work. A wage is better,
  and anyone hired stops gardening and buys from the market like everyone else. (Victoria 3 does
  this with peasants on subsistence farms, Banished with labourers, SAELIG with a free bunkhouse.)

## Who comes to town

A newcomer arrives when the town is doing well, a house is empty, and at most one person in town
is without work. So the town never fills with people it has nothing for. Before, anyone came
whenever food looked fine, found no work, went broke in about 12 days and left: about 25 leavers
per village in 120 days.

## Where profit goes

- Owners with money to spare improve the home they own, level by level: cottage, house, fine
  house, hall, great hall, manor. Each level takes logs from the woodworker and days from a
  hired builder, and costs more than the last. (Victoria 3: owners put a share of profit into
  new building.)
- Owners build houses to rent out when the town is full.
- Renters with savings buy the town house they live in, or build their own.
- Money put into buildings is not counted as a loss when an employer decides whether to keep a hand.

## Output

A master alone makes: farmer about 10 wheat a day (each hand adds as much again), baker 10 loaves
(15 and 17 with hands), woodworker 10 logs (15 and 17). The baker and woodworker made 15 and 12
alone before, which fed and heated the whole town with no help.

## Trade (`scripts/jobs/merchant_job.gd`)

Each market sets its own prices from its own stock. The merchant checks the home market twice a
day. A deal needs the other market to pay at least 10% (and 0.25 coins) more per unit than the
home price, and the whole load to earn 4 coins. They never strip a market (only stock above half
its target), carry up to 20 units, sell, and look for a load to bring home. With no deal for a few
days they eat from a garden plot. Farmers and bakers stay home. Press M for the merchants panel.

## Troubles (`scripts/village/shocks.gd`)

After day 20, now and then: blight (harvests 40% for 6 days), a bakery fire (oven 30% for 4 days),
a hard frost (hearths burn double for 5 days), rats in the market store (60% of wheat and bread
lost). Nothing repairs the damage; prices, hiring and the merchants do. The HUD shows the trouble.

## Starving

Unchanged: hunger at 0 with no bread is death, for anyone.
