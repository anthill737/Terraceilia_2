# Tests

All of them run the real game (Main.tscn) at 10x speed with 240 physics steps a second, so
people walk and trade as in play. Run with Godot 4.6.1, headless, from the project folder.

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
  happens on its own: a renter builds their own house working on site and moves in; a homeless
  person with money buys a house; a business owner's house gets a hired worker who walks to the
  site, is paid daily and finishes it; someone holding bread at hunger 0 eats and lives; a
  farmer with no bread at hunger 0 dies and their coins go to the town purse.
- `res://scenes/TestTradeMigration.tscn`: forces a price gap and checks farmers and bakers carry
  goods to the other village and come back.
