# Shops that grow (2026-11-13)

Anthony asked for this after reading how SAELIG does it: less gain from each extra worker, and
shops that are upgraded through six levels to hold more staff. The code is in
`LaborMarket` (hand_gain, hand_mult, shop_level, staff_room) and `Housing` (shop extensions).

## Less gain from each extra worker

The first hired hand adds half of what the owner makes alone. Each hand after that adds four
fifths of what the one before added: 0.50, 0.40, 0.32, 0.26, 0.20, 0.16, 0.13. So a baker who
makes 12 loaves alone makes 18 with one hand, 23 with two, 27 with three, and 36 with seven.

A farm hand works a field of their own, so the first one brings in a whole farmer's worth, and
the same falling-off applies from there: 1.00, 0.80, 0.64 and so on. (Before, every farm hand
added a whole share.)

The two dev-mode numbers still set the curve: output with one hand (1.5) and with two (1.9).
Every later hand falls off by the same share as the second did. The second number was 1.75,
which halves each time: a third hand was then worth an eighth of the owner and no shop would
ever have wanted one.

## Six levels

A shop as built (level 1) holds two hired hands. Each level above holds one more, up to level 6
with seven.

An owner has the shop extended when it is full and one more hand would still pay: the same test
as hiring (the extra output is worth more than the wage, the goods are not piling up at the
market, the owner can carry the wages), plus the money for the work on top of what the
business runs on.

The work is real, done the way a home is improved: the logs are bought from the market's
woodpile (10 to 16, more at each level, and only from what heating leaves), then a builder is
paid by the day for 4 to 7 days. If no wood can be had for 20 days the owner gives up. One
extension per shop at a time.

The level belongs to the shop. Whoever takes over an empty shop (docs/RECOVERY.md) gets the
biggest one standing empty.

Dev mode: the switch `shop_extensions` (on), and "Hired hands a shop holds before it is
extended" (2).

## Changed in the empty-shop mechanic at the same time

A shop whose owner was broke when they died or left is no longer treated as a going concern
and handed on. Bakers who went broke and left town cold were being replaced for nothing again
and again (577 takeovers in eight towns over 1,500 days). Such a shop now waits for someone
with the savings to reopen it, like any shop that closed.

## Measured

Eight towns, 1,500 days each, four seed pairs, no merchants, kept running past the limit of 50.
"Before" is with who-arrives (docs/WHO_ARRIVES.md) and without shop levels.

- All eight towns at 50 people, nobody starved (before: one death).
- Hired hands per town after day 400: 11 on average (7 to 15). Before: 7 (6 to 9).
- People on garden plots per town: 18 (8 to 26). Before: 20 (8 to 24).
- Extensions finished in the eight towns: farms 115 (six reached level 6), bakeries 19 (two
  reached level 3), lumber yards 13.

## What it does not fix

- Farms grow far more than bakeries, because a farm hand is worth about twice the wage and a
  baker's hand often is not, at ordinary bread prices.
- Bakeries still open and fail too often: about 55 openings per town in 1,500 days, and about
  35 people per town leaving broke with a cold hearth. People open a shop for a tiny expected
  gain. That is the shop-opening rule, not this mechanic.
- Most people still buy little: garden plots.

## Choices that were Claude's

Four fifths as the falling-off, two hands at level 1, one more per level, and reusing the home
improvement costs for an extension.
