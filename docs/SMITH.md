# The smith and tools (2026-11-13)

A fourth trade. Anthony asked for more wants so that more people have something to make, and
for shop upkeep to be paid to a real person. Upkeep was a daily charge paid to nobody; it is
now tools, bought from a smith.

The code is in `SmithJob`, `LaborMarket` (the Tools section), `Market` (More goods) and one
row in `Recovery.TRADES`.

## How it works

- **Tools make a shop a tenth more productive.** A farm, a bakery or a lumber yard with tools
  in hand makes 10% more. Without tools it makes what it always did.
- **Tools wear out.** One tool lasts one person eight days of work, so a shop of three wears
  out three times as many as a shop of one. That is the shop's upkeep: it grows with the shop,
  it is counted in the shop's costs, and it is paid to the smith.
- **A shop buys a tool only when it is worth its price**: when the extra it lets one person
  make over eight days is worth more than the tool costs. It keeps five days of food and
  firewood money before buying tools.
- **The smith** works at the smithy, burns one log from the market for every three tools, and
  puts tools out at the market like any maker. Buyers pay the smith (docs/BUY_FROM_MAKERS.md).
  The price the smith asks covers the firewood and the smith's own keep over a normal day's
  work, the way the baker and the woodworker reckon it, plus the same 25% the other trades
  ask. (Until 2026-11-13 it was spread over the tools made so far: a new smith who had made
  none asked about 20 coins a tool and never sold one.)
- **The price of tools** moves like firewood's: up when the shelf is low and somebody with
  coins wanted one, down when the shelf is over its target. It also comes down on a day when
  tools sit on the shelf and nobody buys.

## A town gets a smith when it can keep one

A normal game starts with no smith and no tools, and the town works as it always did.

Someone opens a smithy the normal way (savings, the opening fee) when what the town's shops
would spend on tools in a day, shared with any smiths already there, is more than the forge's
firewood and a smith's own keep. A village of three shops would use half a tool a day; that is
not a living, so nobody opens. In the test towns the first smith set up around day 75.

A smithy is not a trade the town cannot live without:

- when the last smith goes, the smithy is not filled the next morning, as a farm or a bakery
  would be. It waits until the trade would pay again;
- the last smith may close a failing smithy like any shop. (The rule that the last shop of a
  trade never closes starved the last smith.)

## Adding a trade after this one

- `Market.add_good(name, price, floor, target, shelf)` for what it makes; makers use
  `put_out`, buyers `buy_good`.
- A job script (SmithJob is the model).
- A row in `Recovery.TRADES` (with `"basic": false` if the town can live without it) and a
  list of its owners in the village and the population manager.
- A branch in `Village._perform_role_conversion`, and its line in `LaborMarket`'s
  `_owner_groups`, `_market_wants`, `_overstocked`, `_hand_value` and the career check.

## Dev mode

Switch `tools` (on). Inputs: tools one smith makes a day (6), days one tool lasts one person
(8). Starting town: smiths (0).

## Measured

Eight towns, 1,500 days each (11 hours of play), four seed pairs, kept running past the limit
of 50. "Before" is buyers paying makers with no upkeep at all.

- All eight towns at 50 people, nobody starved (before: the same).
- A smith in town on 99% of days after day 400; 1.3 smiths per town on average.
- Tools cost 4.50 to 6.70 on average.
- Bread 3.28 to 4.18 on average. Before: 3.35 to 5.61.
- Hired hands per town: 15 (12 to 18). Before: 17. Shops: 13, the same, one of them a smithy.
- People with no work per town: 15 (10 to 21). Before: 14.

So the smith is one more job per town and upkeep now goes to a person, but it has not put more
people to work: shops with tools need slightly fewer hands for the same bread.

## Not fixed

- 102 smithies opened and most closed again in eight towns: people still open shops on thin
  expectations (the shop-opening rule).
- Hiring does not yet count the tools a new hand will wear out.
- The town's purse still only takes in (docs/BUY_FROM_MAKERS.md).

## Choices that were Claude's

A tenth more output, eight days per tool, three tools per log, five days of keep before buying
tools, and that a game starts without a smith.

## Tried first

- Starting every town with a smith, and shops making 30% less without tools. A village of five
  cannot keep a smith: he starved by day 52, was replaced the next morning, and the next one
  starved.
