# Dev mode

Dev mode starts a town at any size, with any amount of money and stock, and lets every main
number the town runs on be changed, without editing code. It is for testing: getting to the
situation you want to look at in seconds instead of playing for hours.

Nothing changes in a normal game. Every place in the code asks for its number and falls back
to the built-in one when nothing is set (scripts/dev/tuning.gd).

## In the game

Press F1 (or the Dev button, bottom right). The panel shows:

- A readout for each town: day, people by trade, how many are hired or on garden plots, the
  market's coins, stock and prices, coins in people's pockets, prosperity.
- Starting town: people (or the four counts), coins per person, the market's coins and
  stock, prices, prosperity. These apply to both towns and need Restart town.
- Inputs: the length of a day, what a baker, woodworker and farmer make, wages, costs, upkeep,
  the price limits, the newcomer rules, house costs, and switches for garden plots, servants,
  home improvements, merchants and troubles.

Buttons:

- Apply now: the inputs take effect in the running town. Starting-town values are ignored.
- Restart town: a new town with everything on the panel.
- Back to normal: every row back to its built-in value (then Restart town for the normal game).
- Load / Save: scenarios. Shipped ones are in `scenarios/`; saved ones go to the game's user
  folder (`user://scenarios`).

While the panel is open the game's own keys (P, M, L, Space) are ignored, so typing a
scenario name does not pause the game. Esc or F1 closes it.

## From the command line

After `--`:

- `--scenario=town_of_30` loads `scenarios/town_of_30.json` (or a full path).
- `--set key=value` sets one thing; repeat it as often as needed. `--set=key=value` also works.
- `--set v2.people=12` sets a starting-town value for one village only.

Example: a 30-person town with bakers at 8 loaves a day and no garden plots, for 300 days:

    godot --headless --fixed-fps 30 --path . res://scenes/TestSurvival.tscn -- --days=300 --trade --set people=30 --set baker_loaves_per_day=8 --set gardens=false

An unknown name is reported (a warning in the log, and in the panel) instead of being ignored.

## Scenario files

    {
      "name": "Town of 30",
      "inputs": { "baker_loaves_per_day": 10 },
      "start": { "people": 30, "coins_others": 80 },
      "village_2": { "people": 12 }
    }

`start` applies to every village; `village_1` / `village_2` override it for one.

## Starting town

- `people`: town size, merchant included. The trades are split as one baker and one
  woodworker for every 12 people and one farmer for every 14 (my choice, from what each makes
  today). Give `farmers`, `bakers`, `woodworkers`, `others` yourself to set them exactly.
- `others`: people with no shop. The merchant comes on top, unless merchants are switched off.
- The land holds 9 farmers at most. A town holds `town_size_limit` people (50 unless changed).
- `coins_others`, `coins_owners`, `market_coins`, `market_wheat`, `market_bread`,
  `market_firewood`, `bread_price`, `wheat_price`, `firewood_price`, `prosperity`.
- The market's shelves hold 90 wheat, 100 loaves and 80 logs. More than that can be set, but
  the market buys nothing more until it is back under.

People are brought in and given their trade through the same code the game uses for a
newcomer and for someone opening a shop. The clock waits until the town is built. Houses are
handed out on the first morning: one each, plus `houses_spare_at_start`.

Not set up at the start: hired hands and servants (employers take them on from day 1 or 2 as
usual), home levels, and half-built houses.

## Inputs

The full list, with the built-in values, is the `INPUTS` table in scripts/dev/tuning.gd.
Adding one is a row in that table and a `Tuning.f("name", BUILT_IN)` where the number is used.

Two things to know:

- `day_seconds` only stretches or shrinks the day. People walk at the same speed, so a day
  much under about 20 seconds leaves the farmer too little time for the fields.
- The newcomer bar and wait in the table (0.70 and 3 days) are the values from
  config/economy_config.json, which the game has always used.

## What is tested

`res://scenes/TestDevMode.tscn` (see docs/TESTS.md): every built-in value in the table against
the code, one check per input that it reaches the code using it, a starting town built and
compared number by number, houses for everyone on the first morning, each switch, the menu's
rows, readout, reset and restart, and scenario files saving and loading.
