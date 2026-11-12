# Output follows the workers' skill (2026-11-13)

Anthony asked for this after reading how SAELIG does it: a shop's output comes from the skill
of the people working in it. The code is in `SkillSet`, `Agent.trade_worked` and
`LaborMarket` (hand_skill_factor, hand_mult, _free_hand_for).

## The mechanic

- **Everyone has a skill in each trade**, from 0 to 1, starting at 0.25. Any trade can be
  asked for by name, so a new trade needs no new code here.
- **Skill grows in the trade you work in.** That was already true for a shop's owner. It is now
  true for a hired hand too: a hand at the bakery gets better at baking. Each day worked
  closes 2% of the distance to mastery; skills not used fade by 0.2% a day. Skill stays with
  the person when they change what they do.
- **What a hand adds is the place they fill times how good they are.** The place is the
  falling-off from docs/SHOP_LEVELS.md (0.50, 0.40, 0.32 ...). Someone new to the trade counts
  1.0, so a new hand adds what a hand always added; a master counts about 1.32. The most
  skilled hand is counted in the first place, where a hand adds most.
- **An employer takes the most skilled person free**, and among equals the poorest (it was
  always the poorest). So people who have worked a trade get taken back first.
- **The owner's own skill counts in every trade.** It already did on the farm and in the
  bakery (0.85 of the standard with no skill, 1.25 as a master). It now does at the lumber yard.

Dev mode: the switch `worker_skill` (on).

## Measured

Eight towns, 1,500 days each, four seed pairs, no merchants, kept running past the limit of 50.
"Before" is with who-arrives and shop levels, without skill.

- All eight towns at 49 or 50 people. Two people starved in one town (before: none).
- Hired hands per town after day 400: 16 on average (11 to 18). Before: 11 (7 to 15).
- People on garden plots per town: 10 (7 to 19). Before: 18 (8 to 26).
- Extensions finished in the eight towns: farms 162, bakeries 51, lumber yards 14.

## The problem this makes more visible

With more people earning wages, more bread is sold, and more people open bakeries that fail:
700 bakery openings in eight towns over 1,500 days (438 before), and 528 people leaving town
broke with a cold hearth (276 before).

One cause is the test for "the town is short of bread": the shelf is under its stock target.
The price rules hold stock near the target, so that is true about half the time in a town
that has all the bread it wants.

A stricter test (under the price band below the target) was tried and taken back out. It cut
bakery openings to 150, but:

- wheat arrives in lumps and is rarely under the band three days running, so a town sat on one
  farm with wheat at 2.50 for a hundred days;
- the shops that fail are what keeps the market's purse full. Each newcomer's coins end up
  there. With fewer failures the purse ran dry in 2 of 8 towns, the market could not buy
  bread from the bakers, and 43 people starved holding coins.

So the money loop leaks: coins pile up in the purses of people living off garden plots, who
spend nothing, and the market's purse is only kept up by people arriving with coins and
losing them. That is not fixed here.

## Choices that were Claude's

That a new hand counts 1.0 and a master 1.32, and that the most skilled free person is taken
on first.
