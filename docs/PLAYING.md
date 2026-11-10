# Playing it in Godot

1. Open Godot 4.6.1 and import `project.godot` from this folder.
2. Press F5 (or the play button). The main scene is `scenes/Main.tscn`.

The window opens on village 1. Two villages run at once; trade between them is off until you
press "Trade: OFF".

## What you're looking at

- Market (striped awning): the town shop. The line under it shows its bread, wheat and wood.
- Bakery (stone, smoking chimney), Farmhouse, fields (brown when empty, green when growing,
  gold when ripe), Lumber Yard (trees and a log pile), Shelter (where anyone without a house sleeps).
- Houses south-east of the market. Red roof: the owner lives there. Blue roof: rented.
  Grey roof: empty, marked "for sale" (the town owns it) or "to let" (a person owns it).
  An outline with a yellow bar is a house being built; the bar is wood bought then days worked.
  The name under a house is who lives there.
- People are the small squares with a hunger bar: green farmer, orange baker, brown woodworker,
  pink household. They walk between home, market and work.

The top panel shows the selected village: people by trade, houses, market stock and prices
(bread, wheat, firewood) and the town purse. Click a person to see their money, food,
firewood, home (owns or rents, from whom, days behind on rent), and hands they employ.

## Controls

- Mouse wheel: zoom. Right or middle mouse drag: pan.
- Left click a person: inspect them.
- Page Up / Page Down (or the << >> buttons): game speed, 0.1x to 10x.
- P or the Pause button: pause. Space or "Center": back to the selected village.
- "Village 1" / "Village 2": jump to a village. "World": see both.
- Field / Farmer / Baker / Household buttons: place one by clicking the map (Esc cancels).

## Known gaps

- Houses are drawn in a grid; there is no building animation, only the progress bar.
- Farmer hands work by multiplying the harvest, so you won't see them in the fields.
- Lots of newcomers still go broke and leave (about 30 per village over 120 days of testing):
  there isn't enough paid work yet.
- With one baker, bread can climb past $6 when demand outruns the oven; the baker gets rich
  and poor households can't buy. Nothing caps it, by design: demand sets the price.
- Wheat still aims for a fixed 45 pile, so it sits at its 1.00 floor with a big pile.
