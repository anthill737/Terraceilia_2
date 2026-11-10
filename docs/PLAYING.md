# Playing it in Godot

1. Open Godot 4.6.1 and import `project.godot` from this folder.
2. Press F5 (or the play button). The main scene is `scenes/Main.tscn`.

The window opens on village 1. Two villages run at once and their merchants trade between
them from the start (the Trade button turns that off).

The game behaves the same at every speed. A day is about 27 seconds at 1x and about 3 seconds
at 10x. How the town works is in docs/WORKING_TOWN.md.

## What you're looking at

- Market (striped awning): the town shop. The line under it shows its bread, wheat and wood.
- Bakery (stone, smoking chimney), Farmhouse, fields (brown when empty, green when growing,
  gold when ripe), Lumber Yard (trees and a log pile), Shelter (where anyone without a house sleeps).
- Houses south-east of the market. Red roof: the owner lives there. Blue roof: rented.
  Grey roof: empty, marked "for sale" (the town owns it) or "to let" (a person owns it).
  An outline with a yellow bar is a house being built; the bar is wood bought then days worked.
  The name under a house is who lives there.
- People are the small squares with a hunger bar: green farmer, orange baker, brown woodworker,
  pink household, light blue merchant. They walk between home, market and work. A hired hand
  walks to the field, bakery or yard; a builder to the building site; a servant to the
  master's house; a merchant to the other village and back.
- Homes grow as their owners improve them: a wing for a house, a second for a fine house, a
  tower for a hall. A yellow bar under a home means it is being improved.

The top panel shows the selected village: people by trade, houses, market stock and prices
(bread, wheat, firewood: the prices people pay), the town purse, how many people are idle, and
any trouble under way (blight, a bakery fire, a hard frost, rats in the store). Click a person
to see their money, food, firewood, home (owns or rents, from whom, days behind on rent), what
they do for a living and who for, and hands or servants they employ.

## Controls

- Mouse wheel: zoom. Right or middle mouse drag: pan.
- Left click a person: inspect them.
- Page Up / Page Down (or the << >> buttons): game speed, 0.1x to 10x.
- P or the Pause button: pause. Space or "Center": back to the selected village.
- M: the merchants panel (trips, profit, last deal).
- L: switch the Event Log between town news (the default: who was hired, what was built, who
  arrived, what the merchants sold, what trouble struck) and everything (the full debug log).
- F1 or the Dev button: dev mode. Start a town at any size with any money and stock, and change
  the numbers the town runs on (docs/DEV_MODE.md).
- "Village 1" / "Village 2": jump to a village. "World": see both.
- Field / Farmer / Baker / Household buttons: place one by clicking the map (Esc cancels).

## Known gaps

- With only bread and firewood to buy, about a quarter of the people are on garden plots at any
  time. More trades (ale, iron and tools, cloth) are the way to more work.
- Wheat sits at its 1.00 floor with a full store: it costs about 0.60 to grow.
- Houses are drawn in a grid; building shows as a progress bar.
- Nothing caps the bread price, by design: demand sets it. After a bakery fire it can pass $5
  for a week or two before it settles.
- Farmers and bakers live at the farmhouse and bakery, not in the house with their name on it.
