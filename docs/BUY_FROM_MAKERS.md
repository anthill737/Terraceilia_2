# Buyers pay the makers (2026-11-13)

Anthony's rule: people buy goods from the people producing them. The market is the place goods
are sold and where their price is set. It is not a buyer and it pays for nothing.

The code is in `Market` (shelf, _shelve, _take_payment). Dev switch `buy_from_makers` (on); off
is the old way, where the market bought everything with a purse of its own.

## How it works

- **A maker puts goods on the shelf and is not paid yet.** The shelf, how much it holds, and
  the price rules (docs/BREAD_MARKET.md) are unchanged. A maker still only brings goods when
  the price on offer covers their costs.
- **A buyer picks one maker's stall by chance and buys there.** That maker gets the whole
  payment, coin for coin, at the price the buyer paid. ("If I'm walking down an open market
  and I see 12 vendors, I pick one and I buy their stuff.") If that stall has less than the
  buyer wants, the rest comes from another stall picked the same way.
- **One market price.** Makers do not set prices of their own.
- This holds for wheat (a baker pays a farmer), bread (anyone pays a baker) and firewood
  (anyone pays a woodworker).
- **Goods lost from the shelf** (spoiling, rats) are lost by every maker with goods there, in
  the share each has.
- **Goods with no maker left to pay** (the maker died or left town) are one more stall. What
  they sell for goes to the town's purse.
- What the shelf starts a game with counts as made by the town's first farmer, baker and
  woodworker.

## The town's purse

The town still has a purse (`Market.money`). It buys nothing. It takes in:

- the 50 coin fee for opening a shop, and for taking over an empty one;
- rent and the sale price of houses nobody owns;
- the coins of someone who dies (there are no families yet to leave them to);
- what the goods of a departed maker sell for.

It no longer takes in:

- **Shop upkeep.** It was a daily charge paid to nobody: two thirds of what drained out of a
  full town. It is not charged while buyers pay makers. It comes back as tools bought from a
  smith (the next change).
- **Seed.** A farmer keeps seed back from their own wheat before selling the rest. It used to
  be bought from a bottomless stock at the market.

## Why

With a purse of its own, the market could run out of coins. When owners piled up their takings
that purse ran dry, the market could buy nothing, the shelves emptied and people starved
holding coins: one town in eight in a 1,500 day run of the game as it was.

## Measured

Eight towns, 1,500 days each (11 hours of play), four seed pairs, kept running past the limit
of 50. "Before" is the game with rent for everyone (PR 32).

- All eight towns at 50 people, nobody starved. Before: 13 starved, one town down to 23.
- Hired hands per town: 17 (11 to 23). Before: 19. Shops: 13, the same.
- People with no work per town: 14 (5 to 29). Before: 11.
- Bread 3.35 to 5.61 on average. Before: 3.79 to 8.24.
- Coins held by the people of a town at the end: about 6,000. The town's purse: about 10,800.

## Not fixed

- **The town's purse still only takes in.** With upkeep and seed out it takes about half what
  it did, but a full town still loses coins to it every day, and it spends nothing. It needs
  a use (Anthony: taxes, later).
- **Bakeries still open and fail too often** (680 openings in eight towns), which is also
  what brings most new coins in: people arrive with 150 and lose it.
- Merchants (switched off) are paid as their load sells, like any maker; their trip profit is
  booked at the shelf price on the day they deliver.

## Tried first

- Splitting every sale among all makers by their share of the shelf. Anthony: that is not how
  a market works. One buyer, one stall.
- Keeping upkeep as a coin charge that grows with the shop, paid to the town: 5 of 8 towns
  died. A full town lost about 5.7 coins a day to a purse that never spent them.
