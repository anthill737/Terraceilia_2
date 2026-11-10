# Starving is death

Before: when anyone's hunger reached 0 they became "starving" for good. Hunger stopped
counting and eating was refused. A household on that day died. A farmer or baker never did:
it froze in place forever, holding its wheat and coins. The last farmer is never allowed to
leave town, so a village could keep one frozen farmer and never get wheat again.

Now (`hunger_need.gd`, `agent.gd`, `village.gd`):

- Hunger counts down 1 a day from 5. A loaf puts back 1. People eat once a day from hunger 3.
- At 0, anyone holding bread eats it on the spot. With no bread they die, whatever their trade.
- A dead person is removed like a leaver. Their coins go to the town purse, a house they owned
  passes to the town the next morning, and anyone they employed is out of work.
- Each death counts against the town's prosperity, as before.

Survival test: the old daily "starving with coins and bread in the market" count stays, and a
new check fails a village if anyone starved to death holding coins for a loaf while the market
had bread. Rows now show deaths so far, the house value and the rent.

## Measured results (with the house price change, docs/HOUSING.md)

Two 120-day runs, hiring mode, trade on, seeds 12345,66666 and 4242,777. All 14 checks pass in
both. Nobody starved to death in any of the four villages. Villages grew 7 to 12, 7 to 11,
7 to 12 and 7 to 9. 6 to 9 houses built per village; nobody bought one, all newcomers rented.

(Fixed in the next change, see docs/TESTS.md.) The economy test (TestEconomy) now ends each seed on day 13 with everyone dead. That test was
already hollow: nothing in it ever trades (the market's stock never moves), its households
starved by day 12, and before this change the farmer and baker "survived" to day 60 only because
they were frozen. It still reports PASS because it has no survival minimum. It needs fixing on
its own.

An earlier version let builders take firewood down to half the pile's target. With houses now
cheaper for the rich to start, that emptied one village's pile twice and 4 to 5 people left in a
day. Builders now only take wood above the full target.
