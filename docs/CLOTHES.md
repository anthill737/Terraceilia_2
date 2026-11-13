# Clothes and the tailor (2026-11-13)

A fifth trade, and the first want that people buy for themselves rather than to eat or keep
warm. Anthony's rule: "Everyone always should have to buy what they eat and burn and wear unless
they make it or grow it or cut it themselves, which they should be able to choose based on
utility functions."

The code is in `Clothing` (scripts/village/clothing.gd), `TailorJob`, and the trade's lines in
`LaborMarket`, `Recovery.TRADES` and the village.

## How it works

- **Everyone wears clothes, and they wear out.** A set lasts about 30 days, give or take 30%
  (no two sets alike). Then it is rags. A game starts with everyone in partly worn clothes.
- **Rags are cold.** In a hard frost a hearth burns twice the wood. Someone decently dressed
  gets by on one log; someone in rags still needs two.
- **Buying is a choice.** A new set is worth about three days of living costs to someone in
  rags with a comfortable purse. What its price feels like depends on the purse: a coin is
  worth more the thinner it is. So:
  - someone with coins to spare buys once their clothes are half worn, and never sooner;
  - someone with few coins waits until they are in rags, and may not buy even then;
  - nobody spends the coins for ten days of food, firewood and rent on clothes.
- **Making your own is the other choice.** Someone with no work, in rags, who will not pay
  today's price, buys the flax for a set at the market (three flax), then breaks, spins, weaves
  and sews it. It takes five days of their time. With no coins for the flax, or none for sale,
  they stay in rags. A hired hand has no time to sew.
- **The tailor** makes clothes at the tailor's shop (four sets a day alone; hands, skill and
  tools add more) and puts them out at the market. Buyers pay the tailor whose stall they pick
  (docs/BUY_FROM_MAKERS.md). Clothes are linen: the tailor buys flax at the market, three for
  a set, and the day's work turns it into clothes.
- **Flax is grown by the farmers.** A field can be sown with wheat or with flax. When a farmer
  comes to an empty field, they sow flax if a field of flax (six flax) is worth more than a
  field of wheat (ten wheat) at today's prices, they have the flaxseed, and the market is not
  already full of flax; otherwise wheat. A field of flax gives back seven flaxseed for the five
  it took, so a farmer keeps growing it from their own seed. Farmers start with ten flaxseed, as
  they start with wheat seed. Flax goes on the market and the buyer pays the farmer.
- **A town gets a tailor when it can keep one.** A game starts with none. Someone opens a
  tailor's shop the normal way when what the town would spend on clothes, shared with any
  tailors already there, is more than a tailor's own keep. A tailor's shop is not refilled at
  once when its tailor goes, and the last tailor may close, like a smithy.
- **The living wage now includes clothes.** The least anyone works for is a loaf, a log, a
  day's rent, and a set of clothes spread over the days it lasts (`LaborMarket.wage_floor`).

## Changes to other trades made along the way

- **A maker's own keep is their real cost of living.** The woodworker, the smith and the
  tailor price their goods to cover their own keep. That used to be a loaf and a log only;
  it is now the living wage (food, firewood, rent, clothes). With clothes to buy, woodworkers
  were selling wood for less than they needed to live, went broke, the wood stopped, the
  bakeries could not bake, and in two test runs a town had a famine.
- **How a smith or tailor reckons its costs.** It spreads its costs over what it really makes
  in a day, but never over less than a quarter of a day's work (`LaborMarket.costing_volume`).
  Before, a new smith had made nothing yet and asked about 20 coins a tool; with no floor a
  tailor that sold few asked more, sold fewer and asked more again (up to 38 a set); spread
  over 60% of a day's work, as the baker reckons, tools fell to 2 coins and a smith could live
  in only 60% of towns.
- **A good nobody in town makes has no price to bid up.** The price of tools or clothes rises
  when people want them and the shelf is short, but only while someone in town makes them.
  With no tailor, clothes climbed 12% a day to 439 coins.
- **An empty shelf still counts who wanted to buy.** Without that, a bare shelf kept its price
  and no tailor ever made more.
- **TestLogPanel** waits for the panel's next rewrite in real time instead of 0.35 s of game
  time, which a fast machine got through before any rewrite.

## Dev mode

Switch `clothes` (on). Inputs: sets one tailor makes a day (4), days a set lasts (30).
Starting town: tailors (0).

## Measured

Eight towns, 1,500 days each (11 hours of play), four seed pairs, kept running past the limit
of 50. "Off" is the same code with the clothes switch off.

- Nobody more starved: 3 in eight towns with clothes, 3 without.
- A tailor in town on 77% of days after day 400; the first opened around day 64 (about half an
  hour of play). Clothes cost 4.80 to 7.60 a set on average.
- About 7 people in 50 in rags at any time. 20,900 sets bought and 3,500 sewn at home in the
  eight towns.
- People hold less: the middle purse is 75 coins (100 off).
- Hired hands per town: 15 (16 off). People with no work: 20 (17 off). So clothes did not put
  more people to work in these runs. The differences are within what one set of runs varies
  by.
- Towns reach 50 people a little later: day 262 (247 off).
- The bread shelf was empty on 37 town-days after day 400 (21 off), and the firewood pile on
  about 530 (467 off).

## With flax, and no free food for people with no work

Measured the same way, with flax grown by the farmers and the garden plot no longer handing out
bread and firewood (both 2026-11-13):

- Nobody more starved: 8 in eight towns (8 with flax and the old plot).
- Towns are smaller: 13 to 46 people at the end, and none reached 50 for long. People arrive,
  find no work, spend what they brought and go: 1,890 left with no money in the eight towns.
- Almost everyone left in town works: about 3 people per town have no work (19 with the plot).
- A tailor in town on 74% of days; flax about 1.40. Clothes cost 6 to 95 a set from town to
  town; about 13 people in 50 in rags.
- The town's purse grows faster (rent from people who arrive and leave).

## Not fixed

- **Firewood runs out about one day in twenty in every version**, with or without clothes. The
  price falls slowly while the pile is full and rises slowly when it is empty, and a
  woodworker will not sell below their costs. When firewood runs out the bakeries cannot bake.
  This is the next thing to look at.
- More wants have not yet meant more jobs. Shops still open and fail too often.
- The town's purse still only takes in.

## Choices that were Claude's

Thirty days a set, give or take 30%; three days of keep as what a new set is worth; half worn
before anyone replaces; ten days of keep held back; five days to sew your own; four sets a day;
six flax and seven flaxseed to a field, three flax to a set; that rags only matter in a frost; a quarter of a day's work as the
least a smith or tailor reckons on.
