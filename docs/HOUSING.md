# Houses

Batch 3 towns stalled at 3 to 9 people: newcomers arrived whenever food looked fine, found no
work, went broke in about 12 days and left. Houses now limit arrivals, the way SAELIG does it.

## How it works (`scripts/village/housing.gd`)

- Every person lives in a house. Each village starts with one house per person plus 2 empty.
- A newcomer only arrives when an empty house is free, on top of the old food and prosperity rules.
- One price runs everything. A house is worth what it costs to build one today: 20 logs at
  the market's firewood price plus 5 days of a worker's wage. Buying an empty house from the
  town costs exactly that. Rent is that value spread over 120 days (about 0.5 coins a day at
  current prices), so rent, sale price and build cost all move together with prices.
- Whoever buys or builds needs the same money: the house's value plus 10 days of bread and
  firewood kept back. There is no separate, bigger reserve for the rich.
- A newcomer, or anyone without a home, takes an empty house. They buy it from the town if they
  can afford it; otherwise they rent it. A household that can't pay rent for 4 days leaves town.
- Building: the builder buys the 20 logs a bit at a time from the market's firewood pile (only
  what is above its full target, so heating comes first), then 5 days of work. Each work day the builder
  pays a day's wage to someone in town who is out of work. If nobody is free, the builder does
  it and keeps the wage.
- Who builds: first a renter who can afford a house (they move in when it is done, freeing their
  rental for a newcomer). Otherwise, when no house is empty and the town is doing well, the
  richest person who can afford one builds a house to rent out. At most 2 houses go up at once
  in a village, and one starts per day.
- When someone leaves, their house stays. If they owned it, it passes to the town. A half-built
  house is given up.

## Shortcuts

- Houses are numbers only. They have no place on the map; everyone still walks to the one House spot.
- There are no families yet, so a hired worker or the builder alone does the work. In SAELIG
  the whole household helps. Builders and hired workers don't leave their usual work to build.
- Logs for houses come from the firewood pile; there is no separate lumber good.
- Business owners who can't pay rent are not put out; their rent just goes unpaid.

## Survival test

New check: a run of 60 days or more fails if a village ends with no more people than it had
after the 10 grace days. Shorter runs report the numbers but don't judge them.

## Measured results

Two 120-day runs, hiring mode, trade on, seeds 12345,66666 and 4242,777.

- Three of four villages grew: 4 to 7, 4 to 8 and 4 to 7 people. The fourth shrank from 4 to 3
  and fails the new growth check. It had 3 empty houses for its last 20 days and nobody came,
  so something other than houses held it back there.
- Between 0 and 4 houses were built per village. Nobody bought a house; everyone who moved in rented.
- Leavers fell to 4 to 6 per village over 120 days (batch 3: 4 to 11). 3 households left over
  unpaid rent across all four villages.
- Bread 3.20 to 5.17, never at the floor. Firewood 0.69 to 1.50. Nobody starving in any sample.
- No business opened or closed. Each village still has one farmer, one baker, one woodworker.
- Trade-migration and economy tests pass. No errors.

Growth is real but small. Three owners still supply the whole town, so most newcomers live as
renters with on-and-off work as hands.
