# Each owner sets the wage (2026-11-13)

Anthony asked for this after reading how SAELIG does it: each owner sets the wage; workers
weigh wage, distance to work and how they get on with the boss; and they quit if unpaid. The
code is in `LaborMarket` (_update_hands, wage_floor, wage_of, job_worth, _better_offers).

Before, everyone in town was paid the same number: a loaf plus a log at today's prices, times
1.25.

## The mechanic

- **Every shop has its own wage**, paid to all its hands. A new shop starts at the old
  town rate.
- **The floor.** Nobody works for less than a loaf, a log and a day's rent. Someone with no
  work lives off a garden plot, so a job has to pay at least what it
  costs to stop gardening.
- **An owner who wants a hand and finds nobody free offers more**, by up to 5% a day (the
  same limit a price has), and never more than the hand would bring in.
- **When people in town lack work and the owner is not looking**, the wage settles back
  toward the floor by up to 5% a day.
- **An owner who is losing money cuts the wage first** and lets someone go only when it is
  already at the floor.
- **What a job is worth to a hand** is the wage, less the share of the day spent walking
  there and back, plus how they get on with the boss. That last part grows with every day
  paid on time, up to a fifth of the wage after 30 days.
- **A hand changes employer** when an owner who can find nobody free offers a job worth 15%
  more to them than the one they have. So a long-serving hand near home is hard to tempt
  away, and a new one far from home is easy.
- **A hand who is not paid** stays that day and loses half their goodwill toward the boss.
  Not paid a second day running, they quit. (Before, an owner who could not pay let them go
  on the spot.)

Each shop's own wage goes into its costs, so the baker's margin over costs follows what that
baker really pays. Builders and servants are still paid the town rate.

Dev mode: the switch `owner_wages` (on).

## Measured

Eight towns, 1,500 days each, four seed pairs, no merchants, kept running past the limit of 50.
"Before" is with the other three mechanics and the fixed wage.

- All eight towns at 50 people, nobody starved (before: two deaths).
- Hired hands per town after day 400: 18 on average (14 to 21). Before: 16 (11 to 18).
- The wage actually paid: 5.74 in the middle, 4.28 to 8.53 for most. Before: 6.75, 5.07 to 8.64.
- In the eight towns: 323 moves to a better-paying employer, 918 wage cuts, 1,149 hands who
  quit unpaid.

## Tried and changed

At first the walk was taken off the wage before anyone with no work would accept a job. The
farms are a long walk from every house, could hardly hire, and hired hands per town fell from
16 to 11. Now anyone free takes a job that pays the floor, and the walk and the boss are
weighed only when choosing between two employers.

## What it does not fix

- Bakeries still open and fail too often (762 openings in eight towns), and 541 people left
  broke. See docs/SKILL.md.
- Owners fail to pay often: about one hand per town quits unpaid every ten days.
- Builders and servants do not have wages of their own yet.

## Choices that were Claude's

The floor (a loaf, a log and the rent), 5% a day, two unpaid days, 30 days and a fifth of the
wage for getting on with the boss, 15% to move, and valuing the walk as the share of the day
it takes.
