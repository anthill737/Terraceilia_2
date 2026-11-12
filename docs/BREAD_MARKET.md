# Bread market fixes (2026-11-11)

Small fixes on top of the existing price engine. The engine itself is unchanged: clearing
tracker, inventory bands, bid curve, the 5% daily limit, the 1.00 floor, hold versus decrease,
and the bakers' 25% margin over their true costs (wheat, oven firewood, hands' wages, upkeep)
from batch 3.

A first attempt replaced the engine and the bakers' margin with a simpler rule. Anthony pointed
out that the 25% margin and the price engine were decided work (batch 3, and Notion: "the price
engine converges"), so that attempt was dropped and only the changes below were kept.

## Changes

- **Coins no longer vanish.** Farm, bakery and lumber yard upkeep is paid into the town market's
  purse. It used to be deleted, 2,200 to 3,600 coins per town over the long run, which is
  what drained every market purse to zero and closed every shop by day 1,560 to 3,130.
- **An empty shelf raises the price.** When a shelf is under its lower band and people tried to
  buy and could not, the price goes up (by up to the 5% daily limit). It used to hold still,
  because nothing had been bought from producers that day to set a clearing price.
- **No ceiling on bread or wheat** (Anthony's rule: no price caps). The 1.00 floors stay.
  Firewood keeps its 0.50 to 5.00 range for now.
- **The town's books.** Each village records coins that came from outside (a newcomer's or new
  owner's purse) and coins carried off by people who left. People's coins plus the markets'
  purses must change by exactly that, across both towns.
- **Servants:** a servant whose master died or left is let go instead of crashing the game.

## Tests

- `TestMarket`: the engine's rules with the two changes, a live shortage and an overfull shelf,
  bread and wheat flowing, and the books balancing to the coin.
- `TestLongRun`: plays the real game for a long time (works with dev mode scenarios and
  `--set`). Fails when a town empties, someone starves holding coins for a loaf, a market purse
  runs dry, a town goes 30 days without a farmer or a baker, or the books do not balance.
  `--wipe-day=N` removes every farmer and hired hand of one village to test recovery.

## Measured

See the PR description for the runs. In short: the normal game kept a farmer and a baker in
every town for 1,500 days and the market purses stayed level; a town that loses its farmer and
all hired hands still does not recover, because nobody can meet the rule for opening a farm
(100 coins saved plus bread in hand) and owners do not change trade in hiring mode. That is a
decision for Anthony, not changed here.
