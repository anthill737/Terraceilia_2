# Houses

Batch 3 towns stalled at 3 to 9 people: newcomers arrived whenever food looked fine, found no
work, went broke in about 12 days and left. Houses now limit arrivals, the way SAELIG does it.

## How it works (`scripts/village/housing.gd`)

- Every person lives in a house. Each village starts with one house per person plus 2 empty.
- A newcomer only arrives when an empty house is free, on top of the old food and prosperity rules.
- A newcomer, or anyone without a home, takes an empty house. They buy it from the town if they
  can pay the price and keep 60 coins; otherwise they rent it.
- Rent is 0.5 coins a day, paid to the owner, or to the town purse for houses the town owns.
  A household that can't pay rent for 4 days leaves town.
- Anyone who can afford the wood builds a house and works on it themselves: 20 logs bought from
  the market's firewood pile, then 5 days of work. Builders only buy wood above half the pile's
  target, so heating comes first.
- Who builds: first a renter who can pay for the wood and keep 60 coins (they move into their own
  house when it is done); otherwise, when no house is empty and the town is doing well, the
  richest person with the wood cost plus 150 coins builds one to rent out. At most 2 houses go
  up at once in a village, and one starts per day.
- The town sells its houses at the wood cost times 1.5.
- When someone leaves, their house stays. If they owned it, it passes to the town. A half-built
  house is given up.

## Shortcuts

- Houses are numbers only. They have no place on the map; everyone still walks to the one House spot.
- There are no families yet, so the builder works alone. In SAELIG the whole household helps.
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
