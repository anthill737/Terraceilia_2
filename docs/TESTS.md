# Tests

All of them run the real game (Main.tscn) at 10x speed, so people walk and trade as in play.
Add `--fixed-fps 30 --disable-vsync` before the scene to run about five times faster with the
same result (ticks follow the physics clock). Run with Godot 4.6.1, headless, from the project folder.

- `res://scenes/TestSurvival.tscn -- --days=120 --trade [--village-seeds=a,b] [--result=x.json]
  [--events=x.txt]`: both villages for N days; checks that no village dies out, loses a quarter
  of its people in a day, goes 5 days without a farmer or baker, lets someone starve while
  holding coins and bread is on sale, or fails to grow over 60+ days. `--events` writes every
  village's event log to a file (capped at 40 MB), to see which parts of the game happen.
- `res://scenes/TestEconomy.tscn -- [--days=30]`: checks the books every frame in every village
  (no negative or NaN money or stock, prices in their bands, stock within capacity, hunger in
  range, nobody in two trades) and at the end that the economy really ran: wheat sold and
  bought, bread sold and bought, firewood sold and bought, wages paid, village alive.
  The old version stepped the clock by hand with a quarter of a second of walking per game day,
  so nobody reached the market, everyone starved, and it still printed PASS.
- `res://scenes/TestFeatures.tscn`: sets up each feature on purpose in village 1 and checks it
  happens on its own (17 checks): a renter builds their own house working on site and moves in;
  a homeless person with money buys a house; a business owner's house gets a hired worker who
  walks to the site, is paid daily and finishes it; the merchant carries bread to the other
  village and sells it at a profit; a hired hand walks to the workplace; an owner with money to
  spare improves their home; an owner with a proper house keeps a paid servant who works there;
  people with no work eat from a garden plot and keep their home; someone holding bread at
  hunger 0 eats and lives; a farmer with no bread at hunger 0 dies and their coins go to the
  town purse.
- `res://scenes/TestShocks.tscn`: sets off a bakery fire and rats in village 1 and blight in
  village 2 on day 15, and checks (9 checks) that the price of the hit good rose or its stock
  fell hard, the trouble ended, the price settled back within 25%, nobody starved, the village
  held, and a merchant carried goods between the villages.
- `res://scenes/TestDevMode.tscn`: dev mode (docs/DEV_MODE.md). Checks every built-in value in the
  settings table against the code; one check per input that, once set, it reaches the code that
  uses it (clock, oven, yard, farm, wages, upkeep, fees, savings, price limits, newcomer rules,
  house costs, switches); then starts a town through the dev menu's restart and compares the
  people, coins, market stock, prices and prosperity number by number, that everyone has a
  house on the first morning, that each switch holds for 12 days, the menu's rows, readout and
  reset, and that scenario files save and load. Any game test also takes `--scenario=name` and
  `--set key=value` after `--`.
- `res://scenes/TestLogPanel.tscn`: runs the game at 10x and checks that the Event Log is hidden
  and never drawn while the game keeps recording it, and that L shows town news, then everything
  (rewritten at most 4 times a second, newest line shown), then hides it again.
- `res://scenes/TestTradeMigration.tscn`: the older test of farmers and bakers carrying their own
  goods when a price gap is forced. In normal play they stay home and the merchants trade; this
  test switches that on for itself.
