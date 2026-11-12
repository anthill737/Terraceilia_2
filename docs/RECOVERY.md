# Empty shops: how a town replaces a shop owner (2026-11-12)

One mechanic for every trade. It replaced the farm-only rules of 2026-11-11 after Anthony
asked for it: "Every job now and in the future, it should work in the way that the farmer
works. Make a mechanic for replacement of a business owner." The code is in
scripts/village/recovery.gd.

## The mechanic

A shop does not vanish with its owner. When an owner dies, leaves town, closes or changes
trade, the shop stands empty: the fields, the oven, the saws are still there.

**When an empty shop is taken over:**

- The next morning, when the town has nobody left in that trade.
- A shop that was working when it lost its owner (they died or left town) is taken over once
  the market has been short of what it makes for three days. This is the same signal that
  already lets anyone open a new shop (LaborMarket.OPEN_SHORT_DAYS).
- A shop that closed for want of trade, or whose owner changed trade, is not handed on. It is
  reopened the normal way, by someone with the savings to open a shop, who takes the empty one
  instead of building another. (Handing failed shops on for nothing was tried first: a town of
  46 ended up with 19 bakers and 655 bakery takeovers in 1,500 days.)

**Who takes it.** People who worked in a shop of that trade whose owner is gone come first.
Then people without work. Then anyone else with no shop. Within a group, whoever has the most
coins. Merchants never do.

**What it costs.** No savings are needed, because nothing has to be built, and no purse is
handed out. It is not free (Anthony's rule: whoever picks up a shop pays at least something).
The new owner pays the town the usual fee for opening a shop (50 coins): what they can at
once, and the rest each morning out of what the shop earns. Before paying they keep three
days of bread and firewood, plus the coins the shop needs to work for a day. A job says what
that is with `shop_stock_cost()`: a baker's wheat bin and oven wood. A farm and a lumber yard
need nothing bought in. Without this a poor hand who took the bakery paid the fee, could not
buy wheat, and starved with the rest of the town.

## Going without moves people

When the town has nobody in a trade and nobody without a shop takes the empty one, a shop
owner who has coins and cannot buy what that trade gives the town (bread for a farm or a
bakery, firewood for a lumber yard: none at home, none on the market) takes it. This is the
only time a shop owner changes trade.

- Owners in a trade the town has another of go first.
- The last owner of a trade leaves it only for a shop that ranks above their own (food before
  warmth), and never for a shop tied to their own: the town's only baker does not turn farmer,
  because wheat is no use without a baker.

## Nobody is sent from outside

The old rule "a farmer comes from outside when wheat is dear or the town has had no farmer for
five days, at most one every ten days" is gone. It was a timer, not a mechanic: in towns that
had lost their baker it kept sending a farmer every ten days to starve. Newcomers come the way
they always did (the town's prosperity, a free house, work to be had) and take an empty shop
like anyone else in town.

Merchants still hold back the coins they trade with before buying or improving a house, so
they can carry grain or bread in when a town runs short.

## Adding a trade

One row in `Recovery.TRADES`:

- `list`: the village's list of that trade's owners
- `shop`: what the shop is called in the town news
- `lack`: what people go without when the town has nobody in the trade
- `rank`: food before warmth (see above)
- `uses`: trades the shop cannot work without
- `fields`: idle fields that go with the shop (a farm)

and, if the shop has to buy things in to work, a `shop_stock_cost()` on its job. Nothing else
in the mechanic names a trade.

## Dev-mode switches (F1, Switches)

- `farm_takeover`: an empty shop is taken over.
- `hunger_switch`: owners going without take an empty shop.
- `outside_help`: merchants keep the coins they trade with.

## Choices that were Claude's

The order of who takes a shop, "most coins first", two fields per farm, three days of keep,
food ranking before warmth, and that a shop still pays the fee when it is taken over rather
than built.

## Measured

Eight towns, 1,500 days each (11 hours of play at normal speed), four seed pairs:

- **12 a day (the game as it is):** 8 of 8 towns alive at 24 to 29 people, nobody starved,
  bread 2.88 to 3.19, firewood 0.58 to 1.17 (peak 3.57). Before: 26 to 33 people, nobody
  starved. 57 takeovers in all, every one a bakery whose owner had left town.
- **8 a day (output test, not a setting anyone plays):** every shop that lost its owner was
  taken over (30 farms, 17 bakeries, 12 lumber yards), and starvation deaths fell from 439 to
  69 because no farmer is sent in to starve. 2 of 8 towns were still above 10 people at the
  end (4 of 8 before). Those towns are too poor to live at that output: owners end with no
  coins and starve with bread at 5 or 6. Replacing an owner does not fix that.

`TestRecovery` (docs/TESTS.md) checks the farm, the bakery, the lumber yard, a second shop,
going without, and the merchants.

## Not covered

- A town where everyone is too poor to run the shop that stands empty.
- A town with a shop of each trade that still cannot make enough (the output question). An
  empty shop is only part of that: a new shop still needs someone with 100 coins saved and
  bread in the house.
