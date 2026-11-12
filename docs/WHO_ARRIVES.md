# Who comes to town (2026-11-13)

Anthony asked for this after reading how SAELIG does it: open jobs bring poor families, few
jobs bring rich ones, who then make jobs. The code is in `Village._welcome_newcomer`.

## The mechanic

The gates on whether anyone comes are unchanged: the town is doing well (prosperity), a house
stands empty, and bread and firewood are not scarce.

What changed is who comes. The old rule was a limit: nobody came while more than one person in
town lacked work, so a town with two idle people stopped growing for good. Now the town's own
state decides:

- **A job is waiting**: an employer wanted a hand in the last three days, found nobody, and
  nobody in town is free. Someone comes looking for work, with a newcomer's purse (60 coins).
  Whether one employer wants a hand flickers from day to day, which is why a job counts as
  waiting for three days after it was last seen (the same three days a market must be short
  before a shop opens).
- **No job is waiting**: the person who comes has the means to open a shop of their own, 150
  coins, which is the savings a shop takes (100) plus its fee (50). They rent or build a house,
  hire builders, and open a shop the normal way when a trade looks worth entering.

Dev mode: the switch `arrivals_follow_jobs` (on). Off is the old limit.

## A bug this exposed, fixed in the same change

A person weighing up a trade expected to earn the whole trade's daily takings for themselves,
however many shops were already sharing it (`CareerEvaluator._expected_income` read the trade's
total). While few people had the 100 coins a shop takes, that mistake was hidden. With
newcomers arriving with coins, they opened bakery after bakery and went broke: 779 bakery
openings in one 1,500 day run. Now they expect an equal share with the shops already there
(the total divided by the number of shops plus their own).

## Measured

Eight towns, 1,500 days each (11 hours of play at normal speed), four seed pairs, no merchants,
kept running after a town reached its limit of 50.

- **Before:** 8 of 8 towns alive at 19 to 29 people, nobody starved. 20 people on day 734
  (median), which is 5.4 hours of play. No town reached 40.
- **After:** 8 of 8 towns at 50 people. 20 people on day 92 (41 minutes of play), 50 people
  on day 255 (median, just under two hours). One person starved in eight towns.
- Per town over the 1,500 days: about 70 people came with means and about 6 came for a job;
  about 70 shops opened and 33 closed; about 30 people left.

## What it does not fix

- Most newcomers come with means, because a job is rarely waiting: a shop takes two hands at
  most.
- Coins come in with every newcomer and pile up in the market's purse.
- Many people still live off a garden plot and buy nothing.
- The one death: a town of 27 still had one baker and one woodworker. The woodpile ran out
  after a bakery fire, the bakery could not bake, and the woodworker starved holding 333
  coins. Shops are too small for a town this size.

## Choices that were Claude's

That a job counts as waiting for three days, and that someone with means brings exactly the
savings plus the fee.
