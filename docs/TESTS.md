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
- `res://scenes/TestMarket.tscn`: the bread and wheat price rules (docs/BREAD_MARKET.md), a staged
  shortage and overfull shelf in the real game, and that the books balance to the coin.
- `res://scenes/TestLongRun.tscn -- [--days=1500] [--scenario=x] [--set k=v] [--wipe-day=N]
  [--rows=x.jsonl] [--news=x.txt] [--past-full]`: plays the game for a long time and fails when a town empties,
  someone starves holding coins for a loaf, a market purse runs dry, a town goes 30 days without
  a farmer or baker, or the books do not balance. Run with `--fixed-fps 5`: 1,500 days take
  about two minutes.
- `res://scenes/TestRecovery.tscn`: empty shops (docs/RECOVERY.md). Takes shop owners away on purpose
  and checks (29 checks) that the farm, the bakery and the lumber yard each have a new owner the
  next morning, someone who worked there first, who owes the town the shop fee and gets no purse;
  that each shop is selling again within days and nobody starves; that a second farm stays empty
  while there is wheat on the shelf and is taken after three days short, and that a farm that
  closed for want of trade is not handed on; that a woodworker with
  coins and no bread to buy takes the empty farm and the only baker does not; that merchants hold
  back their trading coins and carry bread or wheat in; and that nobody is sent from outside.
- `res://scenes/TestArrivals.tscn`: who comes to town (docs/WHO_ARRIVES.md). Checks (11 checks) that
  with a job waiting and nobody free the newcomer comes looking for work with a newcomer's purse
  and is taken on; that with no job waiting the newcomer brings the coins a shop takes and puts
  them into a shop or a house; and that with the switch off nobody comes while people lack work.
- `res://scenes/TestShops.tscn`: shops that grow (docs/SHOP_LEVELS.md). Checks (12 checks) that each
  extra hand adds less than the one before; that a full bakery whose owner wants another hand is
  extended with logs from the market and a builder paid by the day; that the third hand is then
  taken on and the bakery makes more; that the level stays with the shop when someone takes it
  over; and that with the switch off a full shop is not extended.
- `res://scenes/TestSkill.tscn`: output follows skill (docs/SKILL.md). Checks (11 checks) that a hired
  hand gets better at the employer's trade and not at others; that what a hand adds is their
  place times how good they are, with the most skilled counted first; that an employer takes
  the most skilled person free, and among equals the poorest; that the owner's skill counts at
  the lumber yard; and that with the switch off every hand counts the same.
- `res://scenes/TestWages.tscn`: each owner sets the wage (docs/WAGES.md). Checks (16 checks) the
  floor (a loaf, a log and the rent); that a job is worth its wage less the walk plus how the
  hand gets on with the boss; that only an offer worth 15% more moves a hand; that an unpaid
  hand stays a day and quits on the second; that an owner who finds nobody raises the wage a
  little each day, never above what the hand brings in, and lets it settle back; and that with
  the switch off everyone pays the town's rate.
- `res://scenes/TestMakers.tscn`: buyers pay the makers (docs/BUY_FROM_MAKERS.md). Checks (13 checks)
  that a maker is not paid on putting goods out and the town's purse pays nothing; that a buyer's
  whole payment goes to one maker, for bread, wheat and firewood; that with two stalls both sell
  over many sales; that goods with no maker left pay the town; that seed comes from the farmer's
  own wheat; that no upkeep reaches the town's purse in play; and that with the switch off the
  market pays on delivery.
- `res://scenes/TestSmith.tscn`: the smith and tools (docs/SMITH.md). Checks (13 checks) that a normal
  game starts with no smith and a village of three shops would not keep one; that in a bigger
  town the smith makes tools and shops buy them, paying the smith and not the town; that a shop
  with tools makes a tenth more and a bigger shop wears out more; that a shop's upkeep is the
  tools it wears out; that a tool is bought only when worth its price and never with food
  money; and that with the switch off shops use no tools.
- `res://scenes/TestClothes.tscn`: clothes and the tailor (docs/CLOTHES.md). Checks (16 checks) that a
  game starts with no tailor and everyone in partly worn clothes that wear out daily; that a small
  village could not keep a tailor and a good nobody makes does not climb in price; that a tailor
  makes clothes and the buyers pay the tailor; when a new set is worth buying to a full and a thin
  purse, never with the food money; that rags burn two logs in a frost; that no two sets last the
  same; that someone with no work and no coins sews their own and a hired hand does not; and that
  with the switch off clothes do not wear.
- `res://scenes/TestTradeMigration.tscn`: the older test of farmers and bakers carrying their own
  goods when a price gap is forced. In normal play they stay home and the merchants trade; this
  test switches that on for itself.
