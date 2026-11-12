# How a town gets a farmer back (2026-11-11)

Before this, a town that lost its farmer was finished. Nobody could open a farm without 100
coins saved and bread in hand, shop owners could not change trade, and the merchants had spent
their coins on houses. In the wipe-out test (every farmer and hired hand removed on day 300)
0 of 4 towns recovered.

Anthony picked three fixes. Each has a switch in dev mode (F1, Switches), all on by default.
The code is in scripts/village/recovery.gd.

## 1. An empty farm is taken over (`farm_takeover`)

The land does not vanish with the farmer. The fields, the seed and the farmhouse are still
there. When a town has no farmer, someone takes the farm over the next morning:

- No savings are needed, because nothing has to be built. No purse is handed out either.
- It is not free. Whoever takes the farm pays the town the usual fee for opening a shop (50
  coins), the way a new tenant paid an entry fine for a holding. They pay what they can at
  once, keeping three days of bread and firewood in the purse, and the rest each morning out
  of what the farm earns. The same goes for a hungry person who turns to farming and for a
  farmer who comes from outside.
- First in line: people who worked for the farmer who is gone. Then people without work. Then
  anyone else with no shop. Within a group, whoever has the most coins.
- The farm's fields (up to two) go with it.
- Only when there is no farmer at all. With a farmer in town, the normal rule for opening a
  second farm still applies (100 saved, 50 fee, wheat short for three days).

## 2. Hunger moves people (`hunger_switch`)

With no farmer, someone who has coins for a loaf and nothing to eat (no bread at home, none on
the shelf) turns to farming. This is the one case where a shop owner changes trade.

- People with no shop first, then a woodworker or baker when the town has another one, then
  the town's last woodworker.
- The town's only baker never switches: wheat is no use without one. Merchants do not either.

## 3. Help from outside (`outside_help`)

- **A farmer comes from outside** when wheat has been dear (a quarter over its floor) three
  days running, or the town has had no farmer for five days. They arrive with an owner's purse
  (150 coins), need a free house and room in town like any newcomer, and take the idle fields
  or plough one. At most one in ten days.
- **Merchants keep their trading coins.** A merchant holds back their purse (150) before buying
  or improving a house, so they can carry grain or bread in when the next town runs short.

## Choices that were Claude's

The order of who takes the farm, "most coins first", two fields per farm, the numbers for
the farmer from outside (a quarter over the floor, three days, five days, ten days), and that
the price of the farm is the shop fee, paid over time with three days of keep held back.
(Anthony's rule: whoever picks up the farm pays at least something.)

## Measured

Wipe-out on day 300, four towns each, 700 days:

- All three on: 4 of 4 had a farmer the next morning. Nobody starved.
- Takeover alone: 4 of 4, next morning.
- Outside help alone: 4 of 4, a farmer came on day 5.
- Hunger alone: 2 of 4. In the other two the switch came only once the bread was gone, and the
  new farmer starved before the first harvest. It works as a backstop, not as the main fix.

`TestRecovery` (docs/TESTS.md) checks each one with the other two switched off.

## Not covered

- A town that loses its only baker. The same idea (the oven is still there) would apply.
- A town whose shops fail because too few people buy anything. That is the garden-plot and
  output question, not this one.
