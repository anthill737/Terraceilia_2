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
- Money needed, always with 10 days of bread and firewood kept back: buying, or building with a
  hired worker, takes the house's whole value. A household with no employer that builds its own
  house pays the logs in coin and the 5 days in its own time, so it needs only the wood cost.
- A newcomer, or anyone without a home, takes an empty house. They buy it from the town if they
  can afford it; otherwise they rent it. A household that can't pay rent for 4 days leaves town.
- Building: the builder buys the 20 logs a bit at a time from the market's firewood pile (only
  what is above its full target, so heating comes first), then 5 days of work.
- The work is real. Each house has one worker for the whole job, who walks to the site and
  spends the day there (trips to market go back to the site, not home). A household with no
  employer builds its own house and is busy with it until it is done (nobody takes it on as a
  hand meanwhile). Anyone else, a business owner or someone with a job, hires the poorest person
  out of work and pays them a day's wage per work day. A day with no worker free is a day with
  no progress. A worker hired to build can't be taken on as a hand until the house is done.
- Who builds: first a renter who can afford it (they move in when it is done, freeing their
  rental for a newcomer). Otherwise, when no house is empty and the town is doing well, the
  richest person who can afford one builds a house to rent out. At most 2 houses go up at once
  in a village, and one starts per day. This is decided first thing in the morning, before
  employers hire.
- When someone leaves, their house stays. If they owned it, it passes to the town. A half-built
  house is given up.

## Home improvements

Someone who owns the house they live in, and can pay for the next step while keeping their
reserve, improves it one step at a time: cottage, house, fine house, hall, great hall, manor.
Each step takes 10 to 16 logs from the market and 4 to 7 days from a builder (the owner, if they
have no employer, or the poorest person out of work, paid a day's wage). At most two homes in a
village are improved at once, and the richest owner who can afford a step goes first.

The manor is the last step (2026-11-14). Before that a manor kept getting rooms added up to level
99, so the richest owner never stopped building: over 1,500 days in 16 towns, 3,902 improvements
were started and 2,187 of the finished ones were rooms past a manor. In Saelig every home has a
short list of upgrades and each is bought once. Dev mode row `home_top_level` (6 = manor) sets
the top step; above 6 the old rooms come back.

Left out: Saelig's owners only buy an upgrade with twice its cost in hand. Ours already keep
back ten days of bread and firewood (and a business owner ten days of wages per hand) on top of
the cost, which is more than a step costs, so that rule would almost never change anything.

Measured (16 towns, 1,500 days, the same seeds, against main with the poorhouse):
- Improvements started 3,902 to 1,953. Rooms past a manor 2,187 to 0. Homes that became manors
  197 to 300: with the richest owners no longer building without end, other owners get their
  turn at the two building slots.
- People out of work hired as builders 4,443 times to 2,304. This was paid work for the jobless.
- Towns are smaller: about 36 people on average from day 300 became about 31. Eight of the 16
  towns settled at 18 to 25 people (three did on main). Newcomers 3,555 to 2,810, people leaving
  3,098 to 2,435 (87 in 100 newcomers leave either way). Shop hands hired 4,176 to 3,204. A town
  had an empty house on 37 in 100 days (49 on main), and empty houses are what bring newcomers.
- Prices stay low and steady. Bread's median from day 200 was 5.7 and rose to 11 in the middle
  of the runs; now it is 3.0 to 3.4. Firewood sits at its 0.50 floor on 47 in 100 days (26).
- Starved 14 to 8. Cold home-days 4,601 to 3,833. Books balance in every run. One run failed one
  check: someone starved holding 65 coins when the bread shelf was empty at 20 a loaf
  (a famine in one town, as on main, where seven did in one town).

So the endless rooms were a money sink that kept the jobless in work and prices climbing. Capping
it stops the spiral and the endless building, but the jobs it gave have to come from somewhere
real. In Saelig they come from owners adding job places and new workplaces when people are idle.

## Shortcuts

- There are no families yet, so one worker does the work. In SAELIG the whole household helps.
- Farm, bakery and lumber-yard hands are still not on the map: being hired raises the owner's
  output, but the hand doesn't walk to the field or oven. House builders do walk to the site.
- Logs for houses come from the firewood pile; there is no separate lumber good.
- Everyone who does not own the house they live in pays rent, whatever they do for a living
  (2026-11-13). Four days unpaid and they leave town, shop owners included. The one exception
  (2026-11-14): someone with no shop and no work goes to the poorhouse instead, where there is no
  rent, and does not take an empty house again until they have work (docs/POORHOUSE.md).

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
