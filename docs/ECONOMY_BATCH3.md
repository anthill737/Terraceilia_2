# Economy batch 3: poorer people, real costs, firewood

Batch 2 left bread sitting on its 1.00 price floor with too many bakers. The cause was three
things together: the cost checks only counted wheat, wallets were huge next to daily costs, and
a business that failed left town instead of looking for work. Batch 3 changes all three and adds
the first second-good chain (firewood).

## What changed

Recipe and money
- Two wheat make one loaf (was one wheat for two loaves).
- Households start with 60 coins. Business owners (farmer, baker, woodworker) start with 150.
  Newcomers bring their own new money; nobody is paid from the market to arrive.
- Opening a business costs 50 coins, paid to the town market. A household needs 100 saved
  before it will try.
- Bread starts at 3.20. The 1.00 price floor for bread and wheat is unchanged.

Wages and hands
- A hand's daily wage is one loaf plus one firewood at today's prices, times 1.25, paid in
  coins from the employer's wallet to the hand's.
- Baker: the first hand adds 50% to what the oven gets through in a day, the second adds 25%
  more. That figure is a firm daily maximum.
- Woodworker: same steps as the baker.
- Farmer: each hand is one more farmer's worth of wheat. See "Shortcuts" below.
- An owner only hires when the extra output is worth more than the wage with 10% to spare, and
  not while their goods are piling up unsold.

True cost checks
- Required profit margin is 25% (was 10%). The margin squeeze threshold is 75% (was 90%).
- The profit, squeeze and throttle checks now count wheat, oven firewood, hands' wages and
  upkeep. Before, a baker counted wheat only.
- Bakers burn one firewood per five loaves. No firewood, no bread.

Firewood
- Each village has a lumber yard a short walk from the market. Its wood never runs out.
- New role: woodworker. Walks to the yard, cuts up to 12 firewood a day (more with hands) and
  sells it at the market. Each village starts with one.
- Everyone burns one firewood a day. Four days without it and they leave town (the last farmer,
  baker or woodworker stays).
- The market holds firewood with its own price (floor 0.50, starts at 1.50; the 5.00 ceiling was removed on 2026-11-12). The
  price rises when buyers go short and falls when the pile grows past its target.
- Firewood does not take up pack space.

Failure
- A business that fails (broke after a losing streak, same rule as before) closes and its owner
  becomes a household looking for work. They keep their coins, bread and firewood. There is no
  waiting period before they may open another business.
- The last farmer, baker or woodworker in a village never closes, only while they are the last.

## Left alone on purpose

- The 1.00 floor for bread and wheat.
- Sole-provider protection.
- The broke plus losing-streak closing rule.
- Hiring (wages) as the labor mode. The old switching mode still exists but is not used.

## Shortcuts worth knowing about

- Farmer hands: a hand multiplies the farmer's harvest (one hand doubles it, two triple it). No
  extra field tiles are created or walked. It stands in for "the farmer works more fields".
- The woodworker's wood is free, so its selling price counts the woodworker's own keep (a loaf
  and a firewood a day) as a cost, plus wages and upkeep, plus the 25% margin. Without that,
  firewood would fall straight to its floor.
- A household that opens a bakery keeps what it owns and no longer gets a free starter kit. It
  buys its first oven firewood on its first market trip.
- An owner whose business closes leaves the old trade's stock behind (seeds, wheat, flour).
- (Later: starving is now death for everyone; see docs/STARVATION.md.)
- The survival test now counts "starving with bread in the market" only for people who could
  pay for a loaf. Being broke and hungry is recorded separately. It also counts businesses
  opened and closed apart from trade switches.

## Measured results

Two 120-day runs in hiring mode with trade on, village seeds 12345,66666 and 4242,777, plus the
trade-migration and economy tests.

What passed
- All 10 survival checks on both seed pairs. Trade-migration and economy tests pass. No errors
  in any log.
- Bread never touched the 1.00 floor. It ranged from 2.86 to 4.93 across the four villages, and
  averaged 3.10 to 4.16 over the second half of the runs.
- Wheat stayed between 1.00 and 1.13.
- Firewood drifted down from 1.50 to between 0.58 and 0.95.
- Nobody was starving in any daily sample. Someone had a cold hearth on 3 to 6 of 120 days per
  village.
- Each village kept one baker and one woodworker for the whole run.

What did not work: the towns do not grow
- Population stayed between 3 and 9 in every village for all 120 days. Final sizes were 6, 8, 6
  and 3. Between 4 and 11 people left each village over the run.
- Only one business opened across the four villages. None closed. Nobody changed trade.
- Newcomers arrive with 60 coins, spend about 5 a day on bread and firewood, find no steady
  work, run out in about 12 days and leave.

Why
- There is not enough paid work. One farmer feeds about 7 people, one baker bakes for 15 to 22,
  one woodworker heats 12. Three owners cover a town of ten, so nobody else is needed.
- A farmer hires a hand when wheat is selling, the harvest doubles, wheat piles up at the
  market (69 to 90 against a target of 45), the farmer's cash falls for five days and the hand
  is let go. Hands never hold a job long enough to save the 100 coins a business needs.
- Owners keep their profit. They buy one loaf and one firewood a day like everyone else, so
  coins collect in three wallets and stop moving.

This is a design gap, not a bug in the rules above. Ways to close it, none built yet: more
trades that people need (the planned iron and flax chains), lower output per worker so each
good needs more workers, or owners spending their profit in town.
